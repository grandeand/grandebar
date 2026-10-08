import Foundation

// Claude Desktop lists Code-tab sessions per account and org, from index files under
// claude-code-sessions/<account>/<org>/. The transcripts themselves live in the account-agnostic
// ~/.claude/projects, so copying the index files is enough to show the same sessions in every
// account. The app refuses symlinked storage folders, so plain files are mirrored:
//
// * a deleted_<id> tombstone spreads everywhere and removes local_<id>.json copies;
// * for every local_<id>.json the newest settled copy (by mtime) wins.
//
// Copies keep the source mtime to the nanosecond, so a copy never looks newer than its source
// and other mirroring tools using the same rule converge instead of ping-ponging. Cowork
// sessions are left alone: their transcript paths embed the owning account id.

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
    }

    private static let tmpName = ".claude-session-sync-tmp"
    /// Files touched this recently may still be being written by the app.
    private static let settleNanoseconds: Int64 = 2_000_000_000
    private static let interval: TimeInterval = 10

    private let home: URL
    private let fm = FileManager.default
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(home: String) {
        self.home = URL(fileURLWithPath: home)
    }

    private var defaultDataDir: URL { home.appendingPathComponent("Library/Application Support/Claude") }
    /// Claude Desktop keeps a separate data dir while third-party inference (CLIProxy) is on.
    private var thirdPartyDataDir: URL { home.appendingPathComponent("Library/Application Support/Claude-3p") }

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
    @discardableResult
    func sync() -> Result {
        lock.lock()
        defer { lock.unlock() }
        var result = Result()
        let dirs = storageDirs()
        result.folders = dirs.count
        guard dirs.count >= 2 else { return result }
        var listing: [URL: [String: Int64]] = [:]
        for dir in dirs { listing[dir] = scan(dir) }

        // 1) Tombstones: spread them and drop the deleted sessions everywhere.
        var tombSource: [String: URL] = [:]
        for dir in dirs {
            for name in listing[dir, default: [:]].keys.sorted() {
                if let id = Self.tombstoneID(name), tombSource[id] == nil {
                    tombSource[id] = dir.appendingPathComponent(name)
                }
            }
        }
        for (id, source) in tombSource {
            for dir in dirs {
                let tomb = "deleted_" + id
                if listing[dir]?[tomb] == nil {
                    try? atomicCopy(source, to: dir.appendingPathComponent(tomb))
                }
                let session = "local_\(id).json"
                if listing[dir]?[session] != nil, (try? fm.removeItem(at: dir.appendingPathComponent(session))) != nil {
                    result.removed += 1
                }
            }
        }

        // 2) Sessions: the newest settled copy wins; JSON is checked only before copying.
        let now = Self.nowNanoseconds()
        var best: [String: (mtime: Int64, url: URL)] = [:]
        for dir in dirs {
            for (name, mtime) in listing[dir, default: [:]] {
                guard let id = Self.sessionID(name), tombSource[id] == nil, now - mtime >= Self.settleNanoseconds else { continue }
                if let current = best[name], current.mtime >= mtime { continue }
                best[name] = (mtime, dir.appendingPathComponent(name))
            }
        }
        for (name, source) in best {
            var targets = dirs.filter { dir in
                dir.appendingPathComponent(name) != source.url && (listing[dir]?[name] ?? -1) < source.mtime
            }
            guard !targets.isEmpty,
                  let data = try? Data(contentsOf: source.url),
                  let session = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            // Folderless sessions run in hidden scratch dirs; third-party mode would list each one as a project.
            if ((session["cwd"] as? String) ?? "").contains("/scratch-workspaces/") {
                targets = targets.filter { !isThirdParty($0) }
            }
            for dir in targets {
                let isNew = listing[dir]?[name] == nil
                if (try? atomicCopy(source.url, to: dir.appendingPathComponent(name))) != nil {
                    if isNew { result.added += 1 } else { result.updated += 1 }
                }
            }
        }
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

    private func isThirdParty(_ dir: URL) -> Bool {
        dir.path.hasPrefix(thirdPartyDataDir.path + "/")
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// name -> mtime in nanoseconds for local_*/deleted_* entries, stat only.
    private func scan(_ dir: URL) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where Self.sessionID(name) != nil || Self.tombstoneID(name) != nil {
            var info = stat()
            if lstat(dir.appendingPathComponent(name).path, &info) == 0 {
                out[name] = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            }
        }
        return out
    }

    // MARK: Copying

    /// Clone into a temp file on the same volume, copy the exact timestamps, then rename over.
    private func atomicCopy(_ source: URL, to destination: URL) throws {
        var root = destination
        while root.lastPathComponent != "claude-code-sessions" && root.path != "/" {
            root.deleteLastPathComponent()
        }
        let tmpDir = root.deletingLastPathComponent().appendingPathComponent(Self.tmpName)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmp = tmpDir.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.copyItem(at: source, to: tmp)

        var info = stat()
        guard lstat(source.path, &info) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        var times = [info.st_atimespec, info.st_mtimespec]
        guard utimensat(AT_FDCWD, tmp.path, &times, 0) == 0, chmod(tmp.path, 0o600) == 0,
              rename(tmp.path, destination.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
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
