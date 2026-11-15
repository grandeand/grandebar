import Foundation

/// One limit window as other tools read it: the share used (0...100) and when it resets.
struct QuotaFileWindow {
    let utilization: Int
    let resetsAt: Date?

    /// GrandeBar keeps remaining percentages; the file carries the used share, like the usage API.
    init?(remaining: Int?, resetsAt: Date?) {
        guard let remaining else { return nil }
        self.utilization = max(0, min(100, 100 - remaining))
        self.resetsAt = resetsAt
    }
}

/// What `~/.config/grandebar/quota.json` holds after a successful refresh: the values the menu
/// bar shows for the current mode. It never carries a token, key or email address.
struct QuotaFileSnapshot {
    var mode: String
    /// "account" when one account's limits are shown, "pool" for the CLIProxy pool total.
    var scope: String
    var plan: String?
    var account: String?
    var accountCount: Int?
    var fiveHour: QuotaFileWindow?
    var sevenDay: QuotaFileWindow?
    /// Model-scoped weekly limits, keyed by model ("fable" → `seven_day_fable`).
    var modelWeekly: [String: QuotaFileWindow] = [:]
    /// The pool's remaining 5h session percentage, as on the menu bar's first line.
    var sessionPoolPercent: Int?
    var updatedAt: Date
    var version: String
}

enum QuotaFile {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/grandebar/quota.json")
    }

    private static let queue = DispatchQueue(label: "co.grande.grandebar.quota-file", qos: .utility)

    /// Writes off the main thread; a failed write is ignored and leaves the previous file as it was.
    static func save(_ snapshot: QuotaFileSnapshot, to url: URL = defaultURL) {
        queue.async { _ = write(snapshot, to: url) }
    }

    /// Atomic: the JSON goes to a temporary file in the same folder, then replaces the file with
    /// rename(2), so a reader never sees a half-written file.
    @discardableResult
    static func write(_ snapshot: QuotaFileSnapshot, to url: URL) -> Bool {
        guard let data = data(for: snapshot) else { return false }
        let folder = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o644]) else {
            return false
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            return false
        }
        return true
    }

    static func data(for snapshot: QuotaFileSnapshot) -> Data? {
        try? JSONSerialization.data(withJSONObject: jsonObject(for: snapshot), options: [.prettyPrinted, .sortedKeys])
    }

    static func jsonObject(for snapshot: QuotaFileSnapshot) -> [String: Any] {
        func window(_ value: QuotaFileWindow?) -> Any {
            guard let value else { return NSNull() }
            return ["utilization": value.utilization, "resets_at": value.resetsAt.map(timestamp) ?? NSNull()] as [String: Any]
        }
        var object: [String: Any] = [
            "mode": snapshot.mode,
            "scope": snapshot.scope,
            "plan": safeLabel(snapshot.plan) ?? NSNull(),
            "account": safeLabel(snapshot.account) ?? NSNull(),
            "five_hour": window(snapshot.fiveHour),
            "seven_day": window(snapshot.sevenDay),
            "updated_at": timestamp(snapshot.updatedAt),
            "source": "grandebar \(snapshot.version)"
        ]
        for (model, value) in snapshot.modelWeekly {
            guard let key = modelKey(model) else { continue }
            object["seven_day_\(key)"] = window(value)
        }
        if let count = snapshot.accountCount {
            object["account_count"] = count
        }
        if let percent = snapshot.sessionPoolPercent {
            object["session_pool_percent"] = percent
        }
        return object
    }

    /// A display label without anything that looks like an email address or a secret.
    static func safeLabel(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.contains("@"), text.count <= 64 else { return nil }
        return text
    }

    /// "Fable" → "fable"; nil for a label that does not make a plain key.
    static func modelKey(_ label: String) -> String? {
        let key = label.lowercased().replacingOccurrences(of: " ", with: "_")
        guard !key.isEmpty, key.count <= 32,
              key.unicodeScalars.allSatisfy({ CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "_" }),
              key.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return key
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
