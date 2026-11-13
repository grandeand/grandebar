import Foundation

/// One Claude worker account of the GrandeClaudex system, as reported by `gdc usage --json`.
/// Utilizations are fractions of 0...1 (used, not remaining); nil means unknown.
struct GrandeClaudexWorker: Equatable {
    let id: String
    let alias: String
    /// The account the worker is signed into, else the one it is meant to use.
    let email: String?
    let loggedIn: Bool
    /// Claude Code's subscription type, e.g. "team".
    let plan: String?
    let status: String?
    let fiveHour: Double?
    let fiveHourResetsAt: Date?
    let sevenDay: Double?
    let sevenDayResetsAt: Date?
    /// "all models" for the general weekly limit, the model (e.g. "Fable") for a model-scoped one.
    let sevenDayLabel: String?
    /// The weekly pace gdc reports (`seven_day_pace`, 0...1); nil when this gdc does not.
    let sevenDayPace: Double?
    /// The model-scoped weekly limit gdc reports next to the general one (`seven_day_model*`).
    /// Older gdc versions leave these fields out; they then read as nil.
    let sevenDayModel: Double?
    let sevenDayModelResetsAt: Date?
    let sevenDayModelLabel: String?
    let sevenDayModelPace: Double?
    let checkedAt: Date?
    let error: String?
}

/// A limit window as the cards show it: what is left, not what is used.
struct GrandeClaudexWindow: Equatable {
    let remainingPercent: Int
    let resetSeconds: Int?
    /// The reset time has passed, so the window is full again and the cached use no longer counts.
    let hasReset: Bool
    /// The weekly pace in percent (`WeeklyPace`); nil for the 5h window, without a reset time and
    /// once the reset has passed.
    let pacePercent: Int?

    init?(used: Double?, resetsAt: Date?, now: Date = Date(), weekly: Bool = false, reportedPace: Double? = nil) {
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
        pacePercent = weekly ? WeeklyPace.percent(resetsAt: resetsAt, now: now, reported: reportedPace) : nil
    }
}

extension GrandeClaudexWorker {
    func fiveHourWindow(now: Date = Date()) -> GrandeClaudexWindow? {
        GrandeClaudexWindow(used: fiveHour, resetsAt: fiveHourResetsAt, now: now)
    }

    func sevenDayWindow(now: Date = Date()) -> GrandeClaudexWindow? {
        GrandeClaudexWindow(used: sevenDay, resetsAt: sevenDayResetsAt, now: now, weekly: true, reportedPace: sevenDayPace)
    }

    func sevenDayModelWindow(now: Date = Date()) -> GrandeClaudexWindow? {
        GrandeClaudexWindow(used: sevenDayModel, resetsAt: sevenDayModelResetsAt, now: now, weekly: true, reportedPace: sevenDayModelPace)
    }

    /// The plan as the Desktop chip writes it: "team" → "Team".
    var planTitle: String? {
        plan.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
    }

    /// The weekly row's name like the Desktop card's: nil for the general limit ("Weekly"),
    /// the model for a model-scoped one.
    var weeklyModel: String? {
        guard let sevenDayLabel, !["all models", "all"].contains(sevenDayLabel.lowercased()) else { return nil }
        return sevenDayLabel
    }
}

struct GrandeClaudexSnapshot: Equatable {
    let chief: String?
    /// The chief account's own limits (the Mac's default Claude Code login), when gdc reports them
    /// as `chief_usage`; shown as the first card of the Claudex tab.
    let chiefUsage: GrandeClaudexWorker?
    let generatedAt: Date?
    let workers: [GrandeClaudexWorker]
}

extension GrandeClaudexSnapshot {
    /// What the Claudex tab calls the chief's card, in place of a worker alias.
    static func chiefName(turkish: Bool) -> String {
        turkish ? "Şef" : "Chief"
    }
}

/// The chief seat: the account Claude Desktop runs the GrandeClaudex chief on, from
/// `gdc chief-seat --json`. GrandeClaudex sends no worker to it.
struct GrandeClaudexSeat: Equatable {
    let email: String
    /// The Claude worker whose account it is (`gc-grande1`), nil for an account no worker uses.
    let worker: String?
    /// That worker's display name ("Trossard").
    let name: String?
    let since: Date?
}

/// Reads GrandeClaudex through its `gdc` CLI, which is the only thing that touches the worker
/// credentials: GrandeBar never opens them itself.
enum GrandeClaudexCLI {
    enum Failure: Error, Equatable {
        case notInstalled
        case failed(String)
        case timedOut
        case unreadable
    }

    /// Where gdc is looked for and what it runs with: GrandeClaudex installs it in ~/.local/bin, and
    /// a menu bar app starts with launchd's minimal PATH, so the usual bins come first.
    static func searchPath(home: String = NSHomeDirectory(), path: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + (path ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
    }

    /// gdc's path, ~/.local/bin/gdc first; nil when GrandeClaudex is not installed.
    static func locate(home: String = NSHomeDirectory(), path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        searchPath(home: home, path: path)
            .filter { $0.hasPrefix("/") }
            .map { ($0 as NSString).appendingPathComponent("gdc") }
            .first { candidate in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
                    && FileManager.default.isExecutableFile(atPath: candidate)
            }
    }

    /// A cache read still asks `claude auth status` for every worker; a probe also runs Claude
    /// Code's `/usage` per worker, with a haiku turn as gdc's fallback.
    static func defaultTimeout(probe: Bool) -> TimeInterval {
        probe ? 300 : 60
    }

    /// Claude workers only, in gdc's order, plus the chief's own record; Codex workers have no limits UI.
    static func parse(_ data: Data) -> GrandeClaudexSnapshot? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["workers"] as? [[String: Any]] else { return nil }
        return GrandeClaudexSnapshot(
            chief: nonEmpty(json["chief"]),
            chiefUsage: (json["chief_usage"] as? [String: Any]).flatMap(worker(from:)),
            generatedAt: date(json["generated_at"]),
            workers: rows.compactMap(worker(from:))
        )
    }

    /// One `usage --json` record; nil for a Codex worker or a row without an id.
    private static func worker(from row: [String: Any]) -> GrandeClaudexWorker? {
        guard (row["kind"] as? String) == "claude", let id = nonEmpty(row["id"]) else { return nil }
        return GrandeClaudexWorker(
            id: id,
            alias: nonEmpty(row["alias"]) ?? id,
            email: nonEmpty(row["login_email"]) ?? nonEmpty(row["email"]),
            loggedIn: flag(row["logged_in"]),
            plan: nonEmpty(row["plan"]),
            status: nonEmpty(row["status"]),
            fiveHour: fraction(row["five_hour"]),
            fiveHourResetsAt: epoch(row["five_hour_resets_at"]),
            sevenDay: fraction(row["seven_day"]),
            sevenDayResetsAt: epoch(row["seven_day_resets_at"]),
            sevenDayLabel: nonEmpty(row["seven_day_label"]),
            sevenDayPace: number(row["seven_day_pace"]),
            sevenDayModel: fraction(row["seven_day_model"]),
            sevenDayModelResetsAt: epoch(row["seven_day_model_resets_at"]),
            sevenDayModelLabel: nonEmpty(row["seven_day_model_label"]),
            sevenDayModelPace: number(row["seven_day_model_pace"]),
            checkedAt: date(row["checked_at"]),
            error: nonEmpty(row["error"])
        )
    }

    /// `gdc usage --json`, or with `probe` `gdc usage --json --probe`, which reads every worker's
    /// limits again first. Blocks until gdc exits or the timeout stops it, so call it off the main
    /// thread.
    static func fetch(probe: Bool, executable: String? = nil, timeout: TimeInterval? = nil) -> Result<GrandeClaudexSnapshot, Failure> {
        run(["usage", "--json"] + (probe ? ["--probe"] : []), executable: executable, timeout: timeout ?? defaultTimeout(probe: probe))
            .flatMap { data in parse(data).map { .success($0) } ?? .failure(.unreadable) }
    }

    /// `gdc chief-seat --json`: the account Claude Desktop runs the chief on. Blocking.
    static func chiefSeat(executable: String? = nil, timeout: TimeInterval = 20) -> Result<GrandeClaudexSeat, Failure> {
        run(["chief-seat", "--json"], executable: executable, timeout: timeout)
            .flatMap { data in parseSeat(data).map { .success($0) } ?? .failure(.unreadable) }
    }

    /// `gdc chief-seat --set <email> --source grandebar --json`, right after GrandeBar moved the
    /// chief, so GrandeClaudex sends no worker to that account from then on. Blocking.
    static func setChiefSeat(_ email: String, executable: String? = nil, timeout: TimeInterval = 20) -> Result<GrandeClaudexSeat, Failure> {
        run(["chief-seat", "--set", email, "--source", "grandebar", "--json"], executable: executable, timeout: timeout)
            .flatMap { data in parseSeat(data).map { .success($0) } ?? .failure(.unreadable) }
    }

    /// `chief-seat --json`'s record; nil without an email.
    static func parseSeat(_ data: Data) -> GrandeClaudexSeat? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let email = nonEmpty(json["email"]) else { return nil }
        return GrandeClaudexSeat(email: email, worker: nonEmpty(json["worker"]), name: nonEmpty(json["name"]), since: date(json["since"]))
    }

    /// Runs gdc with `arguments` and returns what it printed. Blocks until gdc exits or the
    /// timeout stops it, so call it off the main thread.
    private static func run(_ arguments: [String], executable: String?, timeout: TimeInterval) -> Result<Data, Failure> {
        guard let executable = executable ?? locate(), FileManager.default.isExecutableFile(atPath: executable) else {
            return .failure(.notInstalled)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // gdc is a script that looks up its interpreter.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath(path: environment["PATH"]).joined(separator: ":")
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        // Both pipes are drained while gdc runs, so a long reply cannot fill one and stall gdc.
        let drained = DispatchGroup()
        var data = Data()
        var errorData = Data()
        DispatchQueue.global(qos: .utility).async(group: drained) { data = output.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .utility).async(group: drained) { errorData = errors.fileHandleForReading.readDataToEndOfFile() }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return .failure(.timedOut)
        }
        // gdc has exited; a process it left behind could still hold the pipes, so do not wait on that.
        guard drained.wait(timeout: .now() + 3) == .success else { return .failure(.timedOut) }

        guard process.terminationStatus == 0 else {
            // A traceback or gdc's own error ends with the line that says what went wrong.
            let message = String(decoding: errorData, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) }
            return .failure(.failed(message ?? "gdc exited with \(process.terminationStatus)"))
        }
        return .success(data)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A JSON number. JSON's true and false arrive as NSNumbers as well, and Swift casts the
    /// numbers 0 and 1 to Bool, so only Core Foundation's type tells them apart.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func flag(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private static func fraction(_ value: Any?) -> Double? {
        number(value).map { min(1, max(0, $0)) }
    }

    private static func epoch(_ value: Any?) -> Date? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
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
