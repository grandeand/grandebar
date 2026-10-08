import AppKit
import Foundation

// Claude Desktop keeps a single signed-in account. Like codex-keyring does for
// ~/.codex/auth.json, GrandeBar keeps an opaque copy of each account's Desktop session and
// swaps it in: the still-encrypted OAuth caches in config.json plus the Chromium cookie jar
// and LevelDB stores the renderer treats as its "who am I". Tokens are never decrypted.
// The store layout and the set of files follow claude-acc
// (github.com/ohmaseclaro/claude-acc), which reverse-engineered these internals.

enum DesktopAccountError: Error, Equatable {
    case invalidAlias(String)
    case aliasTaken(String)
    case unknownAlias(String)
    /// The live Desktop account is already saved under this alias.
    case alreadySaved(String)
    case notSignedIn
    case missingSnapshot(String)
    case desktopDidNotQuit
    case unreadableConfig
    case loginCancelled
    case loginTimedOut
}

struct DesktopAccount: Equatable {
    let alias: String
    let accountUUID: String
    let email: String?
    let savedAt: Date
    /// False until the account has been switched away from once (cookies and LevelDB can
    /// only be copied while Desktop is closed).
    let hasSnapshot: Bool
}

/// A copy of one Desktop session that can be put back, for rollbacks.
struct DesktopSessionCopy: Equatable {
    let dir: URL
    let accountUUID: String
}

enum DesktopLoginResult: Equatable {
    case added(String)
    case alreadySaved(String)
}

protocol DesktopAppControl {
    var isRunning: Bool { get }
    /// Returns once the app has fully exited, or false if it is still running after `timeout`.
    func quitAndWait(timeout: TimeInterval) -> Bool
    func launch()
}

final class ClaudeDesktopApp: DesktopAppControl {
    static let bundleID = "com.anthropic.claudefordesktop"
    private let codeBinariesPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code").path + "/"

    private var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }

    var isRunning: Bool { running != nil }

    /// A mode or account change only takes effect on a full restart: Code sessions inherit their
    /// env at spawn, so leftover session processes would keep the previous mode.
    func quitAndWait(timeout: TimeInterval) -> Bool {
        if let app = running {
            app.terminate()
            let deadline = Date().addingTimeInterval(timeout)
            while !app.isTerminated && running != nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard running == nil else { return false }
        }
        if waitForLeftovers(seconds: 10) { return true }
        for signal in [SIGTERM, SIGKILL] {
            leftoverProcessIDs().forEach { kill($0, signal) }
            if waitForLeftovers(seconds: 5) { return true }
        }
        return false
    }

    /// `open` hands its own environment to the app, and Desktop passes that on to every Code
    /// session, so Desktop gets a Dock-like environment instead of GrandeBar's.
    func launch() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", Self.bundleID]
        open.environment = ClaudeSessionEnvironment.cleanLaunchEnvironment()
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        if (try? open.run()) != nil {
            open.waitUntilExit()
            if open.terminationStatus == 0 { return }
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Helpers waiting on LevelDB locks also count.
    private func waitForLeftovers(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if leftoverProcessIDs().isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return leftoverProcessIDs().isEmpty
    }

    /// Processes from the app bundle (minus the Chrome native-messaging host, which Chrome owns)
    /// and the Code session binaries Desktop installs under its data directory.
    private func leftoverProcessIDs() -> [pid_t] {
        guard let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID)?.path else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let own = getpid()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = pid_t(parts[0]), pid != own else { return nil }
            let path = String(parts[1])
            let fromBundle = path.hasPrefix(bundle + "/Contents/") && !path.hasSuffix("/chrome-native-host")
            return fromBundle || path.hasPrefix(codeBinariesPath) ? pid : nil
        }
    }
}

/// Variables a Claude Code session exports to its shell. GrandeBar started from such a shell
/// (or relaunched by its updater from one) would otherwise pass them to Claude Desktop, which
/// hands them to every Code session: a 1p session then runs with the 3p proxy, entrypoint and
/// `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`.
enum ClaudeSessionEnvironment {
    private static let prefixes = ["CLAUDE_", "ANTHROPIC_", "DISABLE_"]
    private static let names: Set<String> = ["CLAUDECODE", "ENABLE_TOOL_SEARCH"]
    /// A user setting rather than session state; GrandeBar reads it to find Claude Code's transcripts.
    private static let kept: Set<String> = ["CLAUDE_CONFIG_DIR"]
    /// What launchd gives an app opened from the Dock.
    private static let launchKeys = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "SSH_AUTH_SOCK"]

    static func isSessionKey(_ key: String) -> Bool {
        guard !kept.contains(key) else { return false }
        return names.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }

    /// Run first in main.swift, so every child process starts without them too.
    static func scrubCurrentProcess() {
        for key in ProcessInfo.processInfo.environment.keys where isSessionKey(key) {
            unsetenv(key)
        }
    }

    static func cleanLaunchEnvironment(from current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = current.filter { launchKeys.contains($0.key) }
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["USER"] = environment["USER"] ?? NSUserName()
        environment["LOGNAME"] = environment["LOGNAME"] ?? NSUserName()
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }
}

/// Code sessions Claude Desktop is running, from Claude Code's own `sessions/<pid>.json`
/// records. Quitting Desktop stops all of them, so the restart dialogs list them first.
struct DesktopCodeActivity: Equatable {
    var working: [String] = []
    var waiting: [String] = []
    var idle = 0

    var needsAttention: Bool { !working.isEmpty || !waiting.isEmpty }

    static func current(configDir: URL) -> DesktopCodeActivity {
        var activity = DesktopCodeActivity()
        let dir = configDir.appendingPathComponent("sessions")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (record["pid"] as? NSNumber)?.int32Value, pid > 0,
                  ((record["entrypoint"] as? String) ?? "").hasPrefix("claude-desktop"),
                  kill(pid, 0) == 0 || errno == EPERM else { continue }
            let named = (record["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let title = named ?? (record["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? "Code"
            switch record["status"] as? String {
            case "busy", "shell": activity.working.append(title)
            case "waiting": activity.waiting.append(title)
            default: activity.idle += 1
            }
        }
        return activity
    }
}

/// Used for sandboxed dry runs, so they never quit or launch the real app.
struct DetachedDesktopApp: DesktopAppControl {
    var isRunning: Bool { false }
    func quitAndWait(timeout: TimeInterval) -> Bool { true }
    func launch() {}
}

final class ClaudeDesktopAccounts {
    static let tokenKeys = ["oauth:tokenCache", "oauth:tokenCacheV2"]
    static let accountKey = "lastKnownAccountUuid"
    static let cookieFiles = ["Cookies", "Cookies-journal"]
    static let levelDBDirs = ["Local Storage", "Session Storage", "IndexedDB"]
    /// Remote-control bridge with a short-lived session id: deleted on every swap and never
    /// saved, since restoring a stale id breaks /remote-control.
    static let bridgeFile = "bridge-state.json"
    private static let backupsToKeep = 5
    private static let quitTimeout: TimeInterval = 25
    static let loginTimeout: TimeInterval = 300

    let dataDir: URL
    let storeDir: URL
    /// Claude Code's own account record (`oauthAccount`), one more source for emails.
    private let claudeCodeConfig: URL
    private let app: DesktopAppControl
    private let fm = FileManager.default
    private let cancelLock = NSLock()
    private var cancelRequested = false

    init(home: String, app: DesktopAppControl) {
        let support = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support")
        dataDir = support.appendingPathComponent("Claude")
        storeDir = support.appendingPathComponent("GrandeBar/ClaudeDesktop")
        claudeCodeConfig = URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        self.app = app
    }

    private var accountsDir: URL { storeDir.appendingPathComponent("accounts") }
    private var backupsDir: URL { storeDir.appendingPathComponent("backups") }
    private var configURL: URL { dataDir.appendingPathComponent("config.json") }
    private var knownEmailsURL: URL { storeDir.appendingPathComponent("known-emails.json") }

    private func profileDir(_ alias: String) -> URL { accountsDir.appendingPathComponent(alias) }

    private static func tokenFileName(_ key: String) -> String {
        "config-" + (key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key)
    }

    // MARK: Reading

    func accounts() -> [DesktopAccount] {
        guard let names = try? fm.contentsOfDirectory(atPath: accountsDir.path) else { return [] }
        return names.sorted().filter { !$0.hasPrefix(".") }.compactMap { name in
            let dir = profileDir(name)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let uuid = meta["accountUuid"] as? String, !uuid.isEmpty else { return nil }
            let savedAt = (meta["savedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .distantPast
            let email = (meta["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return DesktopAccount(alias: name, accountUUID: uuid, email: email, savedAt: savedAt, hasSnapshot: hasSnapshot(dir))
        }
    }

    func liveAccountUUID() -> String? {
        guard let config = try? readConfig(),
              let uuid = config[Self.accountKey] as? String, !uuid.isEmpty else { return nil }
        return uuid
    }

    /// Desktop can keep `lastKnownAccountUuid` after signing out, so a login also needs a token cache.
    func liveIsSignedIn() -> Bool {
        guard let config = try? readConfig() else { return false }
        return liveAccountUUID() != nil && Self.tokenKeys.contains { !((config[$0] as? String) ?? "").isEmpty }
    }

    func activeAlias() -> String? {
        guard let uuid = liveAccountUUID() else { return nil }
        return accounts().first { $0.accountUUID == uuid }?.alias
    }

    // MARK: Saving and removing

    /// Saves the live account under `alias`, or under its email when no alias is given. Only
    /// the token caches are copied now; the cookie and LevelDB stores follow the first time
    /// Desktop is closed for a switch. Returns the alias used.
    @discardableResult
    func saveCurrent(as alias: String?) throws -> String {
        if let alias { try validateNewAlias(alias) }
        guard liveIsSignedIn(), let uuid = liveAccountUUID() else { throw DesktopAccountError.notSignedIn }
        if let existing = accounts().first(where: { $0.accountUUID == uuid }) {
            throw DesktopAccountError.alreadySaved(existing.alias)
        }
        let name = alias ?? defaultAlias(for: uuid)
        try writeMeta(alias: name, accountUUID: uuid)
        try? writeTokenFiles(into: profileDir(name))
        return name
    }

    /// Only GrandeBar's copy is renamed; Claude Desktop never sees aliases.
    func rename(_ alias: String, to newAlias: String) throws {
        guard accounts().contains(where: { $0.alias == alias }) else { throw DesktopAccountError.unknownAlias(alias) }
        guard newAlias != alias else { return }
        // A case-only change finds the old folder on a case-insensitive volume.
        if newAlias.lowercased() == alias.lowercased() {
            try validateAliasFormat(newAlias)
        } else {
            try validateNewAlias(newAlias)
        }
        let staged = accountsDir.appendingPathComponent(".rename-\(UUID().uuidString)")
        try fm.moveItem(at: profileDir(alias), to: staged)
        try fm.moveItem(at: staged, to: profileDir(newAlias))
        var meta = readMeta(newAlias)
        meta["label"] = newAlias
        try writeJSON(meta, to: profileDir(newAlias).appendingPathComponent("meta.json"))
    }

    // MARK: Emails

    /// Remembers an account's email (from a CLIProxy profile) and fills it into its saved copy.
    func recordEmail(_ email: String, for accountUUID: String) {
        guard Self.isEmail(email) else { return }
        var known = readJSONFile(knownEmailsURL)
        if known[accountUUID] as? String != email {
            known[accountUUID] = email
            try? writeJSON(known, to: knownEmailsURL)
        }
        if let account = accounts().first(where: { $0.accountUUID == accountUUID }), account.email != email {
            var meta = readMeta(account.alias)
            meta["email"] = email
            try? writeJSON(meta, to: profileDir(account.alias).appendingPathComponent("meta.json"))
        }
    }

    /// Saved copy first, then emails recorded from CLIProxy, then Claude Code's signed-in account.
    func email(for accountUUID: String) -> String? {
        if let saved = accounts().first(where: { $0.accountUUID == accountUUID })?.email { return saved }
        if let known = readJSONFile(knownEmailsURL)[accountUUID] as? String, Self.isEmail(known) { return known }
        let oauth = readJSONFile(claudeCodeConfig)["oauthAccount"] as? [String: Any] ?? [:]
        if oauth["accountUuid"] as? String == accountUUID, let email = oauth["emailAddress"] as? String, Self.isEmail(email) {
            return email
        }
        return nil
    }

    /// Fills missing emails into saved copies; cheap, so it runs whenever the menu opens.
    func backfillEmails() {
        for account in accounts() where account.email == nil {
            if let email = email(for: account.accountUUID) { recordEmail(email, for: account.accountUUID) }
        }
    }

    /// The email when it is a usable, free alias, else `account-<uuid prefix>`.
    private func defaultAlias(for accountUUID: String, avoiding reserved: Set<String> = []) -> String {
        let taken = Set(accounts().map { $0.alias.lowercased() }).union(reserved.map { $0.lowercased() })
        if let email = email(for: accountUUID), (try? validateAliasFormat(email)) != nil, !taken.contains(email.lowercased()) {
            return email
        }
        let base = "account-" + accountUUID.prefix(8)
        var name = base
        var index = 2
        while taken.contains(name.lowercased()) || fm.fileExists(atPath: profileDir(name).path) {
            name = "\(base)-\(index)"
            index += 1
        }
        return name
    }

    private static func isEmail(_ value: String) -> Bool {
        value.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil
    }

    func remove(_ alias: String) throws {
        guard accounts().contains(where: { $0.alias == alias }) else { throw DesktopAccountError.unknownAlias(alias) }
        try fm.removeItem(at: profileDir(alias))
    }

    // MARK: Switching

    /// Quits Desktop, saves the outgoing session, restores `alias` and relaunches Desktop.
    /// `whileClosed` runs with Desktop closed (e.g. to route it back to claude.ai). Blocking.
    func switchTo(_ alias: String, whileClosed: () throws -> Void = {}) throws {
        guard let target = accounts().first(where: { $0.alias == alias }) else { throw DesktopAccountError.unknownAlias(alias) }
        let alreadyLive = liveIsSignedIn() && liveAccountUUID() == target.accountUUID
        guard alreadyLive || target.hasSnapshot else { throw DesktopAccountError.missingSnapshot(alias) }
        guard app.quitAndWait(timeout: Self.quitTimeout) else { throw DesktopAccountError.desktopDidNotQuit }
        defer { app.launch() }

        let outgoing = try preserveLiveSession(reason: "switch")
        do {
            if !alreadyLive {
                try restore(from: profileDir(alias), accountUUID: target.accountUUID)
            }
            try whileClosed()
        } catch {
            if !alreadyLive, let outgoing {
                try? restore(from: outgoing.dir, accountUUID: outgoing.accountUUID)
            }
            throw error
        }
    }

    // MARK: Adding an account

    /// Saves the live session (under `currentAlias` when it is not saved yet), clears the
    /// login and reopens Desktop at its sign-in screen. Returns the session to roll back to.
    /// Either alias may be nil to use the account's email. An unsaved live account is always
    /// saved first, so the previous login is never lost.
    func beginLogin(newAlias: String?, currentAlias: String?) throws -> DesktopSessionCopy? {
        if let newAlias { try validateNewAlias(newAlias) }
        if let currentAlias {
            try validateNewAlias(currentAlias)
            guard currentAlias.lowercased() != newAlias?.lowercased() else { throw DesktopAccountError.aliasTaken(currentAlias) }
        }
        guard app.quitAndWait(timeout: Self.quitTimeout) else { throw DesktopAccountError.desktopDidNotQuit }
        defer { app.launch() }

        if liveIsSignedIn(), let uuid = liveAccountUUID(),
           !accounts().contains(where: { $0.accountUUID == uuid }) {
            let name = currentAlias ?? defaultAlias(for: uuid, avoiding: Set([newAlias].compactMap { $0 }))
            try writeMeta(alias: name, accountUUID: uuid)
        }
        let rollback = try preserveLiveSession(reason: "login")
        try clearLiveLogin()
        setCancelled(false)
        return rollback
    }

    /// Polls config.json until Desktop has written a new login. Blocking.
    func waitForLogin(timeout: TimeInterval = loginTimeout, pollInterval: TimeInterval = 2) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isCancelled() { throw DesktopAccountError.loginCancelled }
            if liveIsSignedIn(), let uuid = liveAccountUUID(),
               let config = try? readConfig(), !((config["oauth:tokenCacheV2"] as? String) ?? "").isEmpty {
                return uuid
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        throw DesktopAccountError.loginTimedOut
    }

    func finishLogin(newAlias: String?, accountUUID: String) throws -> DesktopLoginResult {
        if let existing = accounts().first(where: { $0.accountUUID == accountUUID }) {
            return .alreadySaved(existing.alias)
        }
        let name = newAlias ?? defaultAlias(for: accountUUID)
        try writeMeta(alias: name, accountUUID: accountUUID)
        try? writeTokenFiles(into: profileDir(name))
        return .added(name)
    }

    /// Puts the session from before `beginLogin` back.
    func abortLogin(rollback: DesktopSessionCopy?) throws {
        guard app.quitAndWait(timeout: Self.quitTimeout) else { throw DesktopAccountError.desktopDidNotQuit }
        defer { app.launch() }
        if let rollback {
            try restore(from: rollback.dir, accountUUID: rollback.accountUUID)
        }
    }

    func cancelPendingLogin() { setCancelled(true) }

    /// Desktop creates an account's Code session folder shortly after sign-in.
    func waitForSessionFolder(accountUUID: String, timeout: TimeInterval = 30, pollInterval: TimeInterval = 1) -> Bool {
        let accountDir = dataDir.appendingPathComponent("claude-code-sessions").appendingPathComponent(accountUUID)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let orgs = (try? fm.contentsOfDirectory(atPath: accountDir.path)) ?? []
            if orgs.contains(where: { !$0.hasPrefix(".") && !$0.contains(".pre-share") }) { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return false
    }

    /// Quits Desktop, saves the live session, runs `whileClosed` and relaunches. Blocking.
    func restartDesktop(whileClosed: () throws -> Void) throws {
        guard app.quitAndWait(timeout: Self.quitTimeout) else { throw DesktopAccountError.desktopDidNotQuit }
        defer { app.launch() }
        try preserveLiveSession(reason: "restart")
        try whileClosed()
    }

    // MARK: Snapshots (Desktop must be closed)

    /// Saves the live session into its own profile when the account is saved, else into a
    /// timestamped backup, so it can be switched back to or rolled back.
    @discardableResult
    private func preserveLiveSession(reason: String) throws -> DesktopSessionCopy? {
        guard liveIsSignedIn(), let uuid = liveAccountUUID() else { return nil }
        let dir: URL
        if let account = accounts().first(where: { $0.accountUUID == uuid }) {
            dir = profileDir(account.alias)
        } else {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            dir = backupsDir.appendingPathComponent("\(stamp)-\(reason)")
            try writeJSON(["accountUuid": uuid, "savedAt": Int(Date().timeIntervalSince1970)], to: dir.appendingPathComponent("meta.json"))
        }
        try capture(into: dir)
        pruneBackups()
        return DesktopSessionCopy(dir: dir, accountUUID: uuid)
    }

    private func capture(into dir: URL) throws {
        try makePrivateDirectory(dir)
        let staged = dir.appendingPathComponent("desktop-state.tmp")
        try? fm.removeItem(at: staged)
        try makePrivateDirectory(staged)
        for name in Self.cookieFiles + Self.levelDBDirs {
            let source = dataDir.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: staged.appendingPathComponent(name))
            }
        }
        try writeTokenFiles(into: dir)
        try replace(dir.appendingPathComponent("desktop-state"), with: staged)
    }

    /// Token caches come only from the snapshot, absence included; every other config.json key
    /// (theme, window, allowlists) stays as it is.
    private func restore(from dir: URL, accountUUID: String) throws {
        let state = dir.appendingPathComponent("desktop-state")
        guard hasSnapshot(dir) else { throw DesktopAccountError.missingSnapshot(dir.lastPathComponent) }

        // Copy into a staging folder first, so a failed copy leaves the live session alone.
        let staging = dataDir.appendingPathComponent(".grandebar-restore")
        try? fm.removeItem(at: staging)
        try makePrivateDirectory(staging)
        defer { try? fm.removeItem(at: staging) }
        for name in Self.cookieFiles + Self.levelDBDirs {
            let source = state.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: staging.appendingPathComponent(name))
            }
        }
        var config = try readConfig()
        for key in Self.tokenKeys {
            let file = dir.appendingPathComponent(Self.tokenFileName(key))
            if let value = try? String(contentsOf: file, encoding: .utf8), !value.isEmpty {
                config[key] = value
            } else {
                config.removeValue(forKey: key)
            }
        }
        config[Self.accountKey] = accountUUID

        for name in Self.cookieFiles + Self.levelDBDirs {
            let live = dataDir.appendingPathComponent(name)
            if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
            let staged = staging.appendingPathComponent(name)
            if fm.fileExists(atPath: staged.path) { try fm.moveItem(at: staged, to: live) }
        }
        try? fm.removeItem(at: dataDir.appendingPathComponent(Self.bridgeFile))
        try writeJSON(config, to: configURL)
    }

    private func clearLiveLogin() throws {
        var config = try readConfig()
        for key in Self.tokenKeys + [Self.accountKey] { config.removeValue(forKey: key) }
        for name in Self.cookieFiles + Self.levelDBDirs + [Self.bridgeFile] {
            let live = dataDir.appendingPathComponent(name)
            if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
        }
        try writeJSON(config, to: configURL)
    }

    private func hasSnapshot(_ dir: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.appendingPathComponent("desktop-state").path, isDirectory: &isDir), isDir.boolValue else { return false }
        return Self.tokenKeys.contains { fm.fileExists(atPath: dir.appendingPathComponent(Self.tokenFileName($0)).path) }
    }

    private func writeTokenFiles(into dir: URL) throws {
        let config = try readConfig()
        try makePrivateDirectory(dir)
        for key in Self.tokenKeys {
            let file = dir.appendingPathComponent(Self.tokenFileName(key))
            if let value = config[key] as? String, !value.isEmpty {
                try Data(value.utf8).write(to: file, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } else {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func writeMeta(alias: String, accountUUID: String) throws {
        var meta: [String: Any] = ["label": alias, "accountUuid": accountUUID, "savedAt": Int(Date().timeIntervalSince1970)]
        meta["email"] = email(for: accountUUID)
        try writeJSON(meta, to: profileDir(alias).appendingPathComponent("meta.json"))
    }

    private func readMeta(_ alias: String) -> [String: Any] {
        readJSONFile(profileDir(alias).appendingPathComponent("meta.json"))
    }

    private func pruneBackups() {
        guard let names = try? fm.contentsOfDirectory(atPath: backupsDir.path) else { return }
        for name in names.sorted().dropLast(Self.backupsToKeep) {
            try? fm.removeItem(at: backupsDir.appendingPathComponent(name))
        }
    }

    // MARK: Helpers

    /// Also accepts an email address, since that is the default alias.
    private func validateAliasFormat(_ alias: String) throws {
        guard alias.range(of: "^[A-Za-z0-9][A-Za-z0-9._@+-]{0,63}$", options: .regularExpression) != nil else {
            throw DesktopAccountError.invalidAlias(alias)
        }
    }

    private func validateNewAlias(_ alias: String) throws {
        try validateAliasFormat(alias)
        if fm.fileExists(atPath: profileDir(alias).path) { throw DesktopAccountError.aliasTaken(alias) }
    }

    private func readJSONFile(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object
    }

    private func readConfig() throws -> [String: Any] {
        guard fm.fileExists(atPath: configURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: configURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DesktopAccountError.unreadableConfig
        }
        return object
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try makePrivateDirectory(url.deletingLastPathComponent())
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func makePrivateDirectory(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func replace(_ target: URL, with staged: URL) throws {
        let old = target.appendingPathExtension("old")
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: old) }
        try fm.moveItem(at: staged, to: target)
        try? fm.removeItem(at: old)
    }

    private func isCancelled() -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelRequested
    }

    private func setCancelled(_ value: Bool) {
        cancelLock.lock(); defer { cancelLock.unlock() }
        cancelRequested = value
    }
}
