import Foundation

// Claude Desktop lists Code-tab sessions per account and org, from index files under
// claude-code-sessions/<account>/<org>/. The transcripts themselves live in the account-agnostic
// ~/.claude/projects, so copying the index files is enough to show the same sessions in every
// account. The app refuses symlinked storage folders, so plain files are mirrored:
//
// * a deleted_<id> tombstone spreads everywhere and removes local_<id>.json copies, unless
//   Desktop itself removed it (it does when it imports a CLI session under that id);
// * for every local_<id>.json the newest settled copy (by mtime) wins;
// * archiving spreads like deleting: the latest archive or un-archive anywhere wins everywhere.
//
// Copies keep the source mtime to the nanosecond, so a copy never looks newer than its source
// and other mirroring tools using the same rule converge instead of ping-ponging. Cowork
// sessions are left alone: their transcript paths embed the owning account id.
//
// Desktop reads its session folder only when it starts or changes account, and later saves its
// in-memory copies over whatever was written there. So the folders of the signed-in account are
// only read while Desktop runs, and written once it is closed, by a switch or otherwise. That
// is also what tells an archive action from a stale save: Desktop never has an older isArchived
// in memory than its own folder holds. Desktop keeps no archive time, so an action is dated by
// the mtime of the write that carries it; the ledger remembers the latest one per session and
// what each folder held.

final class ClaudeSessionSharing {
    static let enabledKey = "shareClaudeCodeSessions"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    struct Result: Equatable {
        var added = 0
        var updated = 0
        var removed = 0
        var folders = 0
        /// Copies that could not be written; the next pass tries them again.
        var failed = 0
    }

    /// What GrandeBar remembers between passes, in Application Support/GrandeBar.
    struct Ledger: Codable, Equatable {
        struct Archive: Codable, Equatable {
            var archived: Bool
            /// mtime of the write that carried the latest archive or un-archive.
            var at: Int64
        }

        struct Copy: Codable, Equatable {
            var mtime: Int64
            var archived: Bool
        }

        /// Session id -> latest archive state.
        var archive: [String: Archive] = [:]
        /// Folder (relative to home) -> session id -> the copy last seen or written there.
        var copies: [String: [String: Copy]] = [:]
        /// Session id -> folders (relative to home) that held its tombstone.
        var tombstones: [String: [String]] = [:]
    }

    private static let tmpName = ".claude-session-sync-tmp"
    /// Files touched this recently may still be being written by the app.
    private static let settleNanoseconds: Int64 = 2_000_000_000
    private static let interval: TimeInterval = 10

    private let home: URL
    /// Whether the Claude Desktop process is up; unknown counts as running.
    private let isDesktopRunning: () -> Bool
    private let fm = FileManager.default
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(home: String, isDesktopRunning: @escaping () -> Bool = { true }) {
        self.home = URL(fileURLWithPath: home)
        self.isDesktopRunning = isDesktopRunning
    }

    private var defaultDataDir: URL { home.appendingPathComponent("Library/Application Support/Claude") }
    /// Claude Desktop keeps a separate data dir while third-party inference (CLIProxy) is on.
    private var thirdPartyDataDir: URL { home.appendingPathComponent("Library/Application Support/Claude-3p") }
    private var ledgerURL: URL { home.appendingPathComponent("Library/Application Support/GrandeBar/ClaudeSessionArchive.json") }

    /// Syncs every few seconds while sharing is on.
    func startBackgroundSync() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: Self.interval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard Self.isEnabled else { return }
            _ = self?.sync()
        }
        timer.resume()
        self.timer = timer
    }

    /// One pass over every account and org folder. Safe while Desktop runs; serialized.
    /// `desktopClosed` is only for callers that saw Desktop exit, including its helpers: nothing
    /// can be mid-write then, so even the files Desktop flushed as it quit are copied, and the
    /// signed-in account's folders are brought up to date before Desktop loads one of them. A
    /// pass that finds the Desktop process gone does the same.
    @discardableResult
    func sync(desktopClosed: Bool = false) -> Result {
        lock.lock()
        defer { lock.unlock() }
        var result = Result()
        let all = storageDirs()
        result.folders = all.count
        var listing: [URL: [String: Int64]] = [:]
        for dir in all { listing[dir] = scan(dir) }
        // A folder that cannot be listed is unknown, not empty: it is neither read nor written
        // this pass, and what is on record for it stays.
        let dirs = all.filter { listing[$0] != nil }
        let unknown = Set(all.filter { listing[$0] == nil }.map(folderKey))
        guard dirs.count >= 2 else { return result }
        let now = Self.nowNanoseconds()
        // Desktop not running counts as closed, whoever quit it; it is asked again before writing.
        let closed = desktopClosed || !isDesktopRunning()
        let settle = closed ? 0 : Self.settleNanoseconds
        func settled(_ mtime: Int64) -> Bool { now - mtime >= settle }
        var loaded = closed ? [] : signedInFolders(dirs)
        var ledger = loadLedger()
        var saved = ledger
        func persist() {
            guard ledger != saved else { return }
            saveLedger(ledger)
            saved = ledger
        }

        // 1) Tombstones: spread them and drop the deleted sessions everywhere. Desktop removes a
        //    tombstone itself only when it imports a CLI session under that id, so one gone from a
        //    folder that held it is removed everywhere instead of being spread back.
        let folderKeys = Set(dirs.map(folderKey))
        var tombSource: [String: URL] = [:]
        var holders: [String: Set<String>] = [:]
        for dir in dirs {
            for name in listing[dir, default: [:]].keys.sorted() {
                guard let id = Self.tombstoneID(name) else { continue }
                holders[id, default: []].insert(folderKey(dir))
                if tombSource[id] == nil { tombSource[id] = dir.appendingPathComponent(name) }
            }
        }
        for (id, source) in tombSource {
            let tomb = "deleted_" + id
            let lost = Set(ledger.tombstones[id] ?? []).intersection(folderKeys).subtracting(holders[id] ?? [])
            if !lost.isEmpty {
                let left = dirs.filter { listing[$0]?[tomb] != nil && (try? fm.removeItem(at: $0.appendingPathComponent(tomb))) == nil }
                if left.isEmpty { ledger.tombstones[id] = nil }
                tombSource[id] = nil
                continue
            }
            var held = (ledger.tombstones[id] ?? []).filter(unknown.contains)
            for dir in dirs {
                if listing[dir]?[tomb] != nil || (try? atomicCopy(source, to: dir.appendingPathComponent(tomb))) != nil {
                    held.append(folderKey(dir))
                }
                let session = "local_\(id).json"
                if listing[dir]?[session] != nil, (try? fm.removeItem(at: dir.appendingPathComponent(session))) != nil {
                    result.removed += 1
                }
            }
            ledger.tombstones[id] = held
        }
        ledger.tombstones = ledger.tombstones.filter { holders[$0.key] != nil }

        // 2) Archive actions. A copy whose isArchived differs from what its own folder held is an
        //    action, dated by its mtime; the latest one wins. Saving the value the folder already
        //    held, even after an action elsewhere, is a stale save and changes nothing. A copy in a
        //    folder with no record of it (a new account, or a session seen for the first time)
        //    shows the state at its mtime, so it counts too, agreeing or not.
        let names = Set(dirs.flatMap { listing[$0, default: [:]].keys }.filter { Self.sessionID($0).map { tombSource[$0] == nil } ?? false })
        var observed: [String: [(mtime: Int64, archived: Bool)]] = [:]
        for dir in dirs {
            let held = ledger.copies[folderKey(dir)] ?? [:]
            var copies: [String: Ledger.Copy] = [:]
            for (name, mtime) in listing[dir, default: [:]] {
                guard let id = Self.sessionID(name), tombSource[id] == nil else { continue }
                let old = held[id]
                guard old?.mtime != mtime, settled(mtime), let session = Self.readObject(dir.appendingPathComponent(name)) else {
                    if let old { copies[id] = old }
                    continue
                }
                let archived = session["isArchived"] as? Bool ?? false
                copies[id] = Ledger.Copy(mtime: mtime, archived: archived)
                // Scratch sessions are not shared with Claude-3p (see 3), so its copies take no part.
                if isThirdParty(dir), Self.isScratch(session) { continue }
                if old?.archived != archived { observed[id, default: []].append((mtime, archived)) }
            }
            ledger.copies[folderKey(dir)] = copies
        }
        // The newest observation decides and moves the action time; folder order breaks ties.
        for (id, changes) in observed {
            for change in changes where change.mtime > ledger.archive[id]?.at ?? .min {
                ledger.archive[id] = Ledger.Archive(archived: change.archived, at: change.mtime)
            }
        }
        let ids = Set(names.compactMap(Self.sessionID))
        ledger.archive = ledger.archive.filter { ids.contains($0.key) }
        ledger.copies = ledger.copies.filter { folderKeys.contains($0.key) || unknown.contains($0.key) }
        // Saved before anything is written, so an interrupted pass replays the same decisions.
        persist()

        // 3) Sessions: the newest settled copy wins and carries the latest archive state; JSON is
        //    read only before writing. Desktop saves its in-memory copies over whatever lands in a
        //    folder it has loaded, so the signed-in account's folders wait until it is closed.
        // Read again in case Desktop signed in elsewhere or started since the pass began.
        if !desktopClosed, !closed || isDesktopRunning() { loaded.formUnion(signedInFolders(dirs)) }
        func newest(_ name: String, in candidates: [URL]) -> (mtime: Int64, url: URL)? {
            var best: (mtime: Int64, url: URL)?
            for dir in candidates {
                guard let mtime = listing[dir]?[name], settled(mtime), mtime > (best?.mtime ?? -1) else { continue }
                best = (mtime, dir.appendingPathComponent(name))
            }
            return best
        }
        for name in names.sorted() {
            guard let id = Self.sessionID(name), var source = newest(name, in: dirs) else { continue }
            let archive = ledger.archive[id]
            // Older copies get the source; copies as new as it get it when their archive state is off.
            func outdated(_ dir: URL) -> Bool {
                guard !loaded.contains(dir) else { return false }
                guard let mtime = listing[dir]?[name] else { return true }
                guard settled(mtime), mtime <= source.mtime else { return false }
                return mtime < source.mtime || archive.map { ledger.copies[folderKey(dir)]?[id]?.archived != $0.archived } ?? false
            }
            var targets = dirs.filter(outdated)
            guard !targets.isEmpty, var data = try? Data(contentsOf: source.url), let session = Self.parse(data) else { continue }
            // Folderless sessions run in hidden scratch dirs; third-party mode would list each one as a
            // project. So they are not shared with it either way, and a stale copy there never wins.
            if Self.isScratch(session) {
                let shared = dirs.filter { !isThirdParty($0) }
                guard let own = newest(name, in: shared) else { continue }
                if own.url != source.url {
                    guard let ownData = try? Data(contentsOf: own.url) else { continue }
                    source = own
                    data = ownData
                }
                targets = shared.filter(outdated)
            }
            let archived = archive?.archived ?? (Self.parse(data)?["isArchived"] as? Bool ?? false)
            guard let contents = Self.settingArchived(archived, in: data) else {
                result.failed += targets.count
                continue
            }
            for dir in targets {
                let isNew = listing[dir]?[name] == nil
                do {
                    try atomicCopy(source.url, to: dir.appendingPathComponent(name), contents: contents)
                    ledger.copies[folderKey(dir), default: [:]][id] = Ledger.Copy(mtime: source.mtime, archived: archived)
                    if isNew { result.added += 1 } else { result.updated += 1 }
                } catch {
                    // Left as it was, so the next pass tries again.
                    result.failed += 1
                }
            }
        }
        persist()
        return result
    }

    // MARK: Folders

    private func sessionRoots() -> [URL] {
        var roots = [defaultDataDir, thirdPartyDataDir].map { $0.appendingPathComponent("claude-code-sessions") }
        // Environments of the Claude Desktop Switcher (~/.context-switcher-claude) are covered too.
        let profiles = switcherProfilesDir()
        if let names = try? fm.contentsOfDirectory(atPath: profiles.path) {
            for name in names.sorted() {
                let dataDir = profiles.appendingPathComponent(name).appendingPathComponent("desktop-data")
                guard dataDir.resolvingSymlinksInPath().path != defaultDataDir.resolvingSymlinksInPath().path else { continue }
                roots.append(dataDir.appendingPathComponent("claude-code-sessions"))
            }
        }
        return roots.filter { isRealDirectory($0) }
    }

    private func switcherProfilesDir() -> URL {
        let switcher = home.appendingPathComponent(".context-switcher-claude")
        for name in ["config.toml", "app.toml"] {
            guard let text = try? String(contentsOf: switcher.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("profiles_dir"), let start = trimmed.firstIndex(of: "\""),
                      let end = trimmed.lastIndex(of: "\""), start < end else { continue }
                let path = String(trimmed[trimmed.index(after: start)..<end])
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
        }
        return switcher.appendingPathComponent("profiles")
    }

    private func storageDirs() -> [URL] {
        var out: [URL] = []
        for root in sessionRoots() {
            for account in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted() {
                let accountDir = root.appendingPathComponent(account)
                guard isRealDirectory(accountDir) else { continue }
                for org in ((try? fm.contentsOfDirectory(atPath: accountDir.path)) ?? []).sorted() where !org.contains(".pre-share") {
                    // Symlinked folders break saving in Claude Desktop, so they are never written to.
                    let orgDir = accountDir.appendingPathComponent(org)
                    if isRealDirectory(orgDir) { out.append(orgDir) }
                }
            }
        }
        return out
    }

    /// The org folders of the account Desktop is signed into, any of which it may have loaded.
    private func signedInFolders(_ dirs: [URL]) -> Set<URL> {
        let thirdParty = (Self.readObject(defaultDataDir.appendingPathComponent("claude_desktop_config.json"))?["deploymentMode"] as? String) == "3p"
        let dataDir = thirdParty ? thirdPartyDataDir : defaultDataDir
        guard let account = Self.readObject(dataDir.appendingPathComponent("config.json"))?["lastKnownAccountUuid"] as? String,
              !account.isEmpty else { return [] }
        let prefix = dataDir.appendingPathComponent("claude-code-sessions").appendingPathComponent(account).path + "/"
        return Set(dirs.filter { $0.path.hasPrefix(prefix) })
    }

    private func isThirdParty(_ dir: URL) -> Bool {
        dir.path.hasPrefix(thirdPartyDataDir.path + "/")
    }

    private func folderKey(_ dir: URL) -> String {
        let base = home.path + "/"
        return dir.path.hasPrefix(base) ? String(dir.path.dropFirst(base.count)) : dir.path
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// name -> mtime in nanoseconds for local_*/deleted_* entries, stat only; nil when the folder
    /// cannot be listed.
    private func scan(_ dir: URL) -> [String: Int64]? {
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        var out: [String: Int64] = [:]
        for name in names where Self.sessionID(name) != nil || Self.tombstoneID(name) != nil {
            var info = stat()
            if lstat(dir.appendingPathComponent(name).path, &info) == 0 {
                out[name] = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            }
        }
        return out
    }

    // MARK: Ledger

    private func loadLedger() -> Ledger {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return ledger
    }

    private func saveLedger(_ ledger: Ledger) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ledger) else { return }
        try? fm.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: ledgerURL, options: .atomic)
    }

    // MARK: Copying

    /// Clone (or write `contents`) into a temp file on the same volume, copy the source's exact
    /// timestamps, then rename over. The destination may be the source itself.
    private func atomicCopy(_ source: URL, to destination: URL, contents: Data? = nil) throws {
        var root = destination
        while root.lastPathComponent != "claude-code-sessions" && root.path != "/" {
            root.deleteLastPathComponent()
        }
        let tmpDir = root.deletingLastPathComponent().appendingPathComponent(Self.tmpName)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmp = tmpDir.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        if let contents {
            try contents.write(to: tmp)
        } else {
            try fm.copyItem(at: source, to: tmp)
        }

        var info = stat()
        guard lstat(source.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        var times = [info.st_atimespec, info.st_mtimespec]
        guard utimensat(AT_FDCWD, tmp.path, &times, 0) == 0, chmod(tmp.path, 0o600) == 0,
              rename(tmp.path, destination.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: Sessions

    private static func readObject(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap(parse)
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func isScratch(_ session: [String: Any]) -> Bool {
        ((session["cwd"] as? String) ?? "").contains("/scratch-workspaces/")
    }

    /// The session file with its top-level isArchived set, and autoArchiveExempt too on an
    /// un-archive, as Desktop's own un-archive does. Only those values change, byte for byte;
    /// nil when the result would not read back as exactly that.
    static func settingArchived(_ archived: Bool, in data: Data) -> Data? {
        guard let session = parse(data) else { return nil }
        if session["isArchived"] as? Bool == archived { return data }
        var bytes = [UInt8](data)
        guard setTopLevel("isArchived", to: archived, in: &bytes),
              archived || setTopLevel("autoArchiveExempt", to: true, in: &bytes) else { return nil }
        let patched = Data(bytes)
        let changed: Set<String> = archived ? ["isArchived"] : ["isArchived", "autoArchiveExempt"]
        guard let check = parse(patched), check["isArchived"] as? Bool == archived,
              archived || check["autoArchiveExempt"] as? Bool == true,
              NSDictionary(dictionary: check.filter { !changed.contains($0.key) })
                .isEqual(to: session.filter { !changed.contains($0.key) }) else { return nil }
        return patched
    }

    /// Replaces a top-level true/false/null value, or adds the key first in the object.
    private static func setTopLevel(_ key: String, to value: Bool, in bytes: inout [UInt8]) -> Bool {
        let literal = Array((value ? "true" : "false").utf8)
        if let range = topLevelValue(of: key, in: bytes) {
            guard ["true", "false", "null"].contains(String(decoding: bytes[range], as: UTF8.self)) else { return false }
            bytes.replaceSubrange(range, with: literal)
            return true
        }
        guard let open = bytes.firstIndex(where: { !isSpace($0) }), bytes[open] == UInt8(ascii: "{") else { return false }
        let isEmpty = bytes[(open + 1)...].first(where: { !isSpace($0) }) == UInt8(ascii: "}")
        bytes.insert(contentsOf: Array("\"\(key)\":".utf8) + literal + (isEmpty ? [] : [UInt8(ascii: ",")]), at: open + 1)
        return true
    }

    /// Byte range of the value of a key of the outermost object. Strings are skipped whole, so a
    /// nested key, or the key's name inside a string, never matches.
    private static func topLevelValue(of key: String, in bytes: [UInt8]) -> Range<Int>? {
        let quoted = Array("\"\(key)\"".utf8)
        var depth = 0
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: "\""):
                let start = i
                i += 1
                while i < bytes.count, bytes[i] != UInt8(ascii: "\"") { i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1 }
                i += 1
                guard depth == 1, i <= bytes.count, Array(bytes[start..<i]) == quoted else { continue }
                var value = i
                while value < bytes.count, isSpace(bytes[value]) { value += 1 }
                guard value < bytes.count, bytes[value] == UInt8(ascii: ":") else { continue }
                value += 1
                while value < bytes.count, isSpace(bytes[value]) { value += 1 }
                var end = value
                while end < bytes.count, !isSpace(bytes[end]), bytes[end] != UInt8(ascii: ","), bytes[end] != UInt8(ascii: "}") { end += 1 }
                return value..<end
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                i += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                i += 1
            default:
                i += 1
            }
        }
        return nil
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    // MARK: Names

    private static func sessionID(_ name: String) -> String? {
        guard name.hasPrefix("local_"), name.hasSuffix(".json") else { return nil }
        let id = String(name.dropFirst(6).dropLast(5))
        return isID(id) ? id : nil
    }

    private static func tombstoneID(_ name: String) -> String? {
        guard name.hasPrefix("deleted_") else { return nil }
        let id = String(name.dropFirst(8))
        return isID(id) ? id : nil
    }

    private static func isID(_ value: String) -> Bool {
        value.count == 36 && value.allSatisfy { $0 == "-" || ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func nowNanoseconds() -> Int64 {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        return Int64(now.tv_sec) * 1_000_000_000 + Int64(now.tv_nsec)
    }
}
