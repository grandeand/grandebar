import CoreServices
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

    /// When background passes run. Nothing runs on a beat: a pass follows a change in the session
    /// folders, and a slow safety pass covers a missed event or a folder that appeared since.
    struct Pace {
        /// From a change to its pass, so Desktop is done writing.
        var debounce: TimeInterval = 10
        /// Between passes while changes keep coming. Desktop saves the session it is working in
        /// every few seconds, and the other accounts' folders are only read when Desktop starts or
        /// changes account, so they do not have to follow every save.
        var gap: TimeInterval = 60
        var safety: TimeInterval = 300
        /// From launch to the first pass.
        var start: TimeInterval = 3
    }

    private let home: URL
    /// Whether the Claude Desktop process is up; unknown counts as running.
    private let isDesktopRunning: () -> Bool
    private let isEnabled: () -> Bool
    private let pace: Pace
    private let fm = FileManager.default
    private let lock = NSLock()
    /// Background passes and everything that schedules them; the properties below are only
    /// touched on it.
    private let queue = DispatchQueue(label: "co.grande.grandebar.session-sharing", qos: .utility)
    private var safetyTimer: DispatchSourceTimer?
    private var stream: FSEventStreamRef?
    private var watched: [String] = []
    private var pendingPass: (due: DispatchTime, work: DispatchWorkItem)?
    private var lastPass: DispatchTime?
    /// The last pass wrote, failed or put something off (guarded by `lock`).
    private var needsFollowUp = false
    /// The ledger as the last pass left it, and the stamp of the file it agrees with. Archive
    /// decisions are always on disk; refreshed copy mtimes may live only here (see `persist`).
    private var cachedLedger: (file: Stamp?, ledger: Ledger)?
    /// What the last pass that changed nothing saw. A pass that would see the same is skipped:
    /// with the same files, the same ledger and the same Desktop state it would change nothing again.
    private var quietInputs: PassInputs?

    private struct PassInputs: Equatable {
        let folders: [URL]
        let stamps: [URL: [String: Stamp]]
        let desktopClosed: Bool
        let closed: Bool
        let loaded: Set<URL>
    }

    init(home: String, isDesktopRunning: @escaping () -> Bool = { true },
         isEnabled: @escaping () -> Bool = { ClaudeSessionSharing.isEnabled }, pace: Pace = Pace()) {
        self.home = URL(fileURLWithPath: home)
        self.isDesktopRunning = isDesktopRunning
        self.isEnabled = isEnabled
        self.pace = pace
    }

    deinit { stopWatching() }

    private var defaultDataDir: URL { home.appendingPathComponent("Library/Application Support/Claude") }
    /// Claude Desktop keeps a separate data dir while third-party inference (CLIProxy) is on.
    private var thirdPartyDataDir: URL { home.appendingPathComponent("Library/Application Support/Claude-3p") }
    private var ledgerURL: URL { home.appendingPathComponent("Library/Application Support/GrandeBar/ClaudeSessionArchive.json") }

    /// Syncs after the session folders change while sharing is on, plus a slow safety pass.
    func startBackgroundSync() {
        queue.async { [self] in
            guard safetyTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pace.start, repeating: pace.safety, leeway: .milliseconds(Int(min(pace.start, 30) * 1000)))
            timer.setEventHandler { [weak self] in self?.backgroundPass() }
            timer.resume()
            safetyTimer = timer
        }
    }

    /// Something no folder shows has changed (Desktop quit, so its folders can catch up).
    func syncSoon() {
        queue.async { [weak self] in self?.schedulePass(after: 2, spaced: false) }
    }

    /// The earliest request wins; `spaced` passes also keep `pace.gap` from the last one.
    private func schedulePass(after delay: TimeInterval, spaced: Bool) {
        guard safetyTimer != nil, isEnabled() else { return }
        var delay = delay
        if spaced, let lastPass {
            let since = Double(DispatchTime.now().uptimeNanoseconds &- lastPass.uptimeNanoseconds) / 1_000_000_000
            delay = max(delay, pace.gap - since)
        }
        let due = DispatchTime.now() + delay
        if let pendingPass, pendingPass.due <= due { return }
        pendingPass?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingPass = nil
            self?.backgroundPass()
        }
        pendingPass = (due, work)
        queue.asyncAfter(deadline: due, execute: work)
    }

    private func backgroundPass() {
        // Watched even while sharing is off, so turning it on needs no restart.
        watch(sessionRoots().map(\.path))
        guard isEnabled() else { return }
        sync()
        lastPass = .now()
        lock.lock()
        let again = needsFollowUp
        lock.unlock()
        // Its own writes come back as events too; either way the next pass is `pace.gap` away.
        if again { schedulePass(after: pace.debounce, spaced: true) }
    }

    /// One FSEvents stream over the claude-code-sessions folders, replaced when the set changes.
    private func watch(_ roots: [String]) {
        guard roots != watched || (stream == nil && !roots.isEmpty) else { return }
        stopWatching()
        watched = roots
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let changed: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let sharing = Unmanaged<ClaudeSessionSharing>.fromOpaque(info).takeUnretainedValue()
            sharing.schedulePass(after: sharing.pace.debounce, spaced: true)
        }
        // Folder-level events are enough: a pass lists every folder anyway.
        guard let stream = FSEventStreamCreate(nil, changed, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, 0) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
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
        needsFollowUp = false
        var result = Result()
        let all = storageDirs()
        result.folders = all.count
        var stamps: [URL: [String: Stamp]] = [:]
        for dir in all { stamps[dir] = scan(dir) }
        let listing = stamps.mapValues { $0.mapValues(\.mtime) }
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
        let inputs = PassInputs(folders: all, stamps: stamps, desktopClosed: desktopClosed, closed: closed, loaded: loaded)
        // Nothing moved since a pass that changed nothing: this one would change nothing either.
        if inputs == quietInputs, cachedLedger.map({ $0.file == stamp(ledgerURL) }) ?? false { return result }
        quietInputs = nil
        var ledger = loadLedger()
        let started = ledger
        var saved = ledger
        /// Files written or removed, copies held back or failed, or files too fresh to read.
        var unsettled = listing.values.contains { $0.values.contains { !settled($0) } }
        func persist() {
            guard ledger != saved else { return }
            // A copy's mtime only spares re-reading an unchanged file, so a change of mtimes
            // alone stays in memory; anything else is written before the pass acts on it.
            if Self.durable(ledger) != Self.durable(saved) {
                saveLedger(ledger)
            } else if let cached = cachedLedger {
                cachedLedger = (cached.file, ledger)
            }
            saved = ledger
        }
        defer {
            if !unsettled, result.added + result.updated + result.removed + result.failed == 0, ledger == started {
                quietInputs = inputs
            }
            needsFollowUp = quietInputs == nil
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
                unsettled = true
                let left = dirs.filter { listing[$0]?[tomb] != nil && (try? fm.removeItem(at: $0.appendingPathComponent(tomb))) == nil }
                if left.isEmpty { ledger.tombstones[id] = nil }
                tombSource[id] = nil
                continue
            }
            var held = (ledger.tombstones[id] ?? []).filter(unknown.contains)
            for dir in dirs {
                if listing[dir]?[tomb] != nil {
                    held.append(folderKey(dir))
                } else {
                    unsettled = true
                    if (try? atomicCopy(source, to: dir.appendingPathComponent(tomb))) != nil { held.append(folderKey(dir)) }
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
        // A pass that found Desktop stopped asks again right before each write into the
        // signed-in account's folders; once Desktop runs, they wait for the next time it is closed.
        let recheck = closed && !desktopClosed ? signedInFolders(dirs) : []
        func mayWrite(_ dir: URL) -> Bool {
            guard !loaded.contains(dir) else { return false }
            guard recheck.contains(dir), isDesktopRunning() else { return true }
            loaded.formUnion(recheck)
            return false
        }
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
                    // A copy held back (Desktop saved it or started meanwhile) keeps its old record.
                    guard try replace(dir.appendingPathComponent(name), listed: stamps[dir]?[name], with: contents,
                                      mtime: source.mtime, mayWrite: { mayWrite(dir) }) else {
                        unsettled = true
                        continue
                    }
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

    /// Which version of a file was listed.
    private struct Stamp: Equatable {
        /// Nanoseconds.
        let mtime: Int64
        let inode: UInt64
    }

    /// name -> stamp for local_*/deleted_* entries, stat only; nil when the folder cannot be listed.
    private func scan(_ dir: URL) -> [String: Stamp]? {
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        var out: [String: Stamp] = [:]
        for name in names where Self.sessionID(name) != nil || Self.tombstoneID(name) != nil {
            out[name] = stamp(dir.appendingPathComponent(name))
        }
        return out
    }

    private func stamp(_ url: URL) -> Stamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Stamp(mtime: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec), inode: UInt64(info.st_ino))
    }

    // MARK: Ledger

    /// Decoded again only when the file is not the one the cached copy agrees with.
    private func loadLedger() -> Ledger {
        let file = stamp(ledgerURL)
        if let cachedLedger, cachedLedger.file == file { return cachedLedger.ledger }
        let ledger = (try? Data(contentsOf: ledgerURL)).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) } ?? Ledger()
        cachedLedger = (file, ledger)
        return ledger
    }

    private func saveLedger(_ ledger: Ledger) {
        cachedLedger = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ledger) else { return }
        try? fm.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: ledgerURL, options: .atomic)) != nil else { return }
        cachedLedger = (stamp(ledgerURL), ledger)
    }

    /// The ledger without the copy mtimes: what has to survive a restart.
    private static func durable(_ ledger: Ledger) -> Ledger {
        var ledger = ledger
        ledger.copies = ledger.copies.mapValues { $0.mapValues { Ledger.Copy(mtime: 0, archived: $0.archived) } }
        return ledger
    }

    // MARK: Copying

    /// Tombstones never change: clone into a temp file on the same volume, copy the source's
    /// exact timestamps, then rename over.
    private func atomicCopy(_ source: URL, to destination: URL) throws {
        var info = stat()
        guard lstat(source.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let tmp = try staged(for: destination, times: [info.st_atimespec, info.st_mtimespec]) { try fm.copyItem(at: source, to: $0) }
        defer { try? fm.removeItem(at: tmp) }
        guard rename(tmp.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Writes a session copy with the source's mtime, but only while the destination is still the
    /// version that was listed (or still missing) and `mayWrite` agrees, both checked right before
    /// the rename. False when the copy is left for the next pass.
    private func replace(_ destination: URL, listed: Stamp?, with contents: Data, mtime: Int64,
                         mayWrite: () -> Bool) throws -> Bool {
        let time = timespec(tv_sec: Int(mtime / 1_000_000_000), tv_nsec: Int(mtime % 1_000_000_000))
        let tmp = try staged(for: destination, times: [time, time]) { try contents.write(to: $0) }
        defer { try? fm.removeItem(at: tmp) }
        guard mayWrite(), stamp(destination) == listed else { return false }
        if listed == nil {
            // Never replaces a file that appeared since the check.
            guard renamex_np(tmp.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { return false }
                throw CocoaError(.fileWriteUnknown)
            }
        } else {
            // The check above and this rename are not atomic, and that gap is accepted: Desktop
            // writes only the folders of the account it has loaded; those are written here only
            // after a fresh isDesktopRunning() reported it stopped; and Desktop loads its session
            // folder about 15 s after launch, so it cannot save within microseconds of appearing.
            // No other folder is ever written by Desktop.
            guard rename(tmp.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        return true
    }

    /// A temp file next to the session folders, filled by `fill`, with the given timestamps.
    private func staged(for destination: URL, times: [timespec], fill: (URL) throws -> Void) throws -> URL {
        var root = destination
        while root.lastPathComponent != "claude-code-sessions" && root.path != "/" {
            root.deleteLastPathComponent()
        }
        let tmpDir = root.deletingLastPathComponent().appendingPathComponent(Self.tmpName)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmp = tmpDir.appendingPathComponent(UUID().uuidString)
        do {
            try fill(tmp)
            var times = times
            guard utimensat(AT_FDCWD, tmp.path, &times, 0) == 0, chmod(tmp.path, 0o600) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            return tmp
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
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
        value.utf8.count == 36 && value.utf8.allSatisfy { $0 == 0x2D || (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func nowNanoseconds() -> Int64 {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        return Int64(now.tv_sec) * 1_000_000_000 + Int64(now.tv_nsec)
    }
}
