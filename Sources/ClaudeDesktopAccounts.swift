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

    private var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }

    var isRunning: Bool { running != nil }

    func quitAndWait(timeout: TimeInterval) -> Bool {
        guard let app = running else { return true }
        app.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.isTerminated || running == nil {
                // Helper processes outlive the main one briefly; let them drop the LevelDB locks.
                Thread.sleep(forTimeInterval: 1.5)
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return running == nil
    }

    func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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

    let dataDir: URL
    let storeDir: URL
    private let app: DesktopAppControl
    private let fm = FileManager.default
    private let cancelLock = NSLock()
    private var cancelRequested = false

    init(home: String, app: DesktopAppControl) {
        let support = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support")
        dataDir = support.appendingPathComponent("Claude")
        storeDir = support.appendingPathComponent("GrandeBar/ClaudeDesktop")
        self.app = app
    }

    private var accountsDir: URL { storeDir.appendingPathComponent("accounts") }
    private var backupsDir: URL { storeDir.appendingPathComponent("backups") }
    private var configURL: URL { dataDir.appendingPathComponent("config.json") }

    private func profileDir(_ alias: String) -> URL { accountsDir.appendingPathComponent(alias) }

    private static func tokenFileName(_ key: String) -> String {
        "config-" + (key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key)
    }

    // MARK: Reading

    func accounts() -> [DesktopAccount] {
        guard let names = try? fm.contentsOfDirectory(atPath: accountsDir.path) else { return [] }
        return names.sorted().compactMap { name in
            let dir = profileDir(name)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let uuid = meta["accountUuid"] as? String, !uuid.isEmpty else { return nil }
            let savedAt = (meta["savedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .distantPast
            return DesktopAccount(alias: name, accountUUID: uuid, savedAt: savedAt, hasSnapshot: hasSnapshot(dir))
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

    /// Saves the live account under `alias`. Only the token caches are copied now; the cookie
    /// and LevelDB stores follow the first time Desktop is closed for a switch.
    func saveCurrent(as alias: String) throws {
        try validateNewAlias(alias)
        guard liveIsSignedIn(), let uuid = liveAccountUUID() else { throw DesktopAccountError.notSignedIn }
        if let existing = accounts().first(where: { $0.accountUUID == uuid }) {
            throw DesktopAccountError.alreadySaved(existing.alias)
        }
        try writeMeta(alias: alias, accountUUID: uuid)
        try? writeTokenFiles(into: profileDir(alias))
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
    func beginLogin(newAlias: String, currentAlias: String?) throws -> DesktopSessionCopy? {
        try validateNewAlias(newAlias)
        if let currentAlias {
            try validateNewAlias(currentAlias)
            guard currentAlias != newAlias else { throw DesktopAccountError.aliasTaken(newAlias) }
        }
        guard app.quitAndWait(timeout: Self.quitTimeout) else { throw DesktopAccountError.desktopDidNotQuit }
        defer { app.launch() }

        if let currentAlias, liveIsSignedIn(), let uuid = liveAccountUUID(),
           !accounts().contains(where: { $0.accountUUID == uuid }) {
            try writeMeta(alias: currentAlias, accountUUID: uuid)
        }
        let rollback = try preserveLiveSession(reason: "login")
        try clearLiveLogin()
        setCancelled(false)
        return rollback
    }

    /// Polls config.json until Desktop has written a new login. Blocking.
    func waitForLogin(timeout: TimeInterval = 300, pollInterval: TimeInterval = 2) throws -> String {
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

    func finishLogin(newAlias: String, accountUUID: String) throws -> DesktopLoginResult {
        if let existing = accounts().first(where: { $0.accountUUID == accountUUID }) {
            return .alreadySaved(existing.alias)
        }
        try writeMeta(alias: newAlias, accountUUID: accountUUID)
        try? writeTokenFiles(into: profileDir(newAlias))
        return .added(newAlias)
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

    // MARK: Snapshots (Desktop must be closed)

    /// Saves the live session into its own profile when the account is saved, else into a
    /// timestamped backup, so it can be switched back to or rolled back.
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
        try writeJSON(
            ["label": alias, "accountUuid": accountUUID, "savedAt": Int(Date().timeIntervalSince1970)],
            to: profileDir(alias).appendingPathComponent("meta.json")
        )
    }

    private func pruneBackups() {
        guard let names = try? fm.contentsOfDirectory(atPath: backupsDir.path) else { return }
        for name in names.sorted().dropLast(Self.backupsToKeep) {
            try? fm.removeItem(at: backupsDir.appendingPathComponent(name))
        }
    }

    // MARK: Helpers

    private func validateNewAlias(_ alias: String) throws {
        guard alias.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$", options: .regularExpression) != nil else {
            throw DesktopAccountError.invalidAlias(alias)
        }
        if fm.fileExists(atPath: profileDir(alias).path) { throw DesktopAccountError.aliasTaken(alias) }
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
