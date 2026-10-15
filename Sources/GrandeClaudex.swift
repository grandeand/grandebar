import Foundation

/// One Claude worker account of the GrandeClaudex system, as reported by `gdc usage --json`.
/// Utilizations are fractions of 0...1 (used, not remaining); nil means unknown.
struct GrandeClaudexWorker: Equatable {
    let id: String
    let alias: String
    let email: String?
    let loggedIn: Bool
    let status: String?
    let fiveHour: Double?
    let fiveHourResetsAt: Date?
    let sevenDay: Double?
    let sevenDayResetsAt: Date?
    let checkedAt: Date?
    let error: String?
}

/// A limit window as the list shows it: what is left, not what is used.
struct GrandeClaudexWindow: Equatable {
    let remainingPercent: Int
    let resetSeconds: Int?
    /// The reset time has passed, so the window is open again and the cached use no longer counts.
    let hasReset: Bool

    init?(used: Double?, resetsAt: Date?, now: Date = Date()) {
        guard let used else { return nil }
        if let resetsAt, resetsAt <= now {
            remainingPercent = 100
            resetSeconds = nil
            hasReset = true
        } else {
            remainingPercent = Int(((1 - used) * 100).rounded())
            resetSeconds = resetsAt.map { Int($0.timeIntervalSince(now)) }
            hasReset = false
        }
    }
}

extension GrandeClaudexWorker {
    func fiveHourWindow(now: Date = Date()) -> GrandeClaudexWindow? {
        GrandeClaudexWindow(used: fiveHour, resetsAt: fiveHourResetsAt, now: now)
    }

    func sevenDayWindow(now: Date = Date()) -> GrandeClaudexWindow? {
        GrandeClaudexWindow(used: sevenDay, resetsAt: sevenDayResetsAt, now: now)
    }
}

struct GrandeClaudexSnapshot: Equatable {
    let chief: String?
    let generatedAt: Date?
    let workers: [GrandeClaudexWorker]
}

/// Reads GrandeClaudex through its `gdc` CLI, which is the only thing that touches the worker
/// credentials: GrandeBar never opens them itself.
enum GrandeClaudexCLI {
    enum Failure: Error, Equatable {
        case notInstalled
        case failed(String)
        case unreadable
    }

    static var defaultExecutable: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/gdc")
    }

    /// Claude workers only; Codex workers have no limits UI.
    static func parse(_ data: Data) -> GrandeClaudexSnapshot? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["workers"] as? [[String: Any]] else { return nil }
        let workers = rows.compactMap { row -> GrandeClaudexWorker? in
            guard (row["kind"] as? String) == "claude", let id = row["id"] as? String else { return nil }
            return GrandeClaudexWorker(
                id: id,
                alias: (row["alias"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                email: nonEmpty(row["email"]) ?? nonEmpty(row["login_email"]),
                loggedIn: (row["logged_in"] as? Bool) ?? false,
                status: nonEmpty(row["status"]),
                fiveHour: fraction(row["five_hour"]),
                fiveHourResetsAt: epoch(row["five_hour_resets_at"]),
                sevenDay: fraction(row["seven_day"]),
                sevenDayResetsAt: epoch(row["seven_day_resets_at"]),
                checkedAt: date(row["checked_at"]),
                error: nonEmpty(row["error"])
            )
        }
        return GrandeClaudexSnapshot(chief: nonEmpty(json["chief"]), generatedAt: date(json["generated_at"]), workers: workers)
    }

    /// `gdc usage --json`, which reads a cache and returns in about half a second; with `probe`
    /// it makes one tiny haiku call per account and takes a few seconds. Blocks, so call it off
    /// the main thread.
    static func fetch(probe: Bool, executable: String = defaultExecutable, timeout: TimeInterval = 120) -> Result<GrandeClaudexSnapshot, Failure> {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return .failure(.notInstalled) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["usage", "--json"] + (probe ? ["--probe"] : [])
        // A menu bar app starts with a minimal PATH, and gdc is a script that looks up its interpreter.
        var environment = ProcessInfo.processInfo.environment
        let extra = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extra + (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)).joined(separator: ":")
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let errorLock = NSLock()
        var errorData = Data()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            errorLock.lock()
            errorData.append(chunk)
            errorLock.unlock()
        }

        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            return .failure(.failed(error.localizedDescription))
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        errors.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            errorLock.lock()
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            errorLock.unlock()
            return .failure(.failed(message.isEmpty ? "gdc exited with \(process.terminationStatus)" : String(message.suffix(200))))
        }
        guard let snapshot = parse(data) else { return .failure(.unreadable) }
        return .success(snapshot)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func fraction(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !(value is Bool) else { return nil }
        return min(1, max(0, number.doubleValue))
    }

    private static func epoch(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, !(value is Bool) else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: text) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
