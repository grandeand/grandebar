import Foundation

/// The API-equivalent cost of GrandeClaudex's Antigravity accounts, from `gdc ag cost --json`: gdc
/// reads each account's token use per local day and model from agy's own records on the Mac the
/// account lives on, and this prices it. The accounts run on Google AI Pro subscriptions, so this
/// is what the same tokens would cost on the paid API, like the Claude Code and Codex costs.
enum AntigravityCost {
    struct Price: Equatable {
        let input: Double
        let output: Double
        let cacheRead: Double
    }

    struct Reading: Equatable {
        let usage: LocalUsage
        /// Model ids with no known price, left out of the amounts.
        let unpriced: [String]
        /// Aliases of the accounts gdc could not read this time.
        let failed: [String]
    }

    /// USD per million tokens on the Gemini API's standard paid tier (Google's pricing page, read
    /// 2026-11-24; thinking is billed as output). agy's model ids are internal, so they are matched
    /// by family: an orchestrator counts as the model it runs on, agy's own flash worker as Gemini
    /// 3.8 Flash. The Claude models take GrandeBar's Claude Code prices. `day` is the local day the
    /// tokens were used (yyyy-MM-dd), for the prices that change on a date.
    static func price(model: String, day: String) -> Price? {
        let id = model.lowercased()
        if id.contains("claude") {
            return LocalClaudeUsage.basePrice(model: id).map { Price(input: $0.input, output: $0.output, cacheRead: $0.cacheRead) }
        }
        guard id.contains("gemini") else { return nil }
        if id.contains("neon") { return Price(input: 3, output: 15, cacheRead: 0.15) }
        if id.contains("argon") || id.contains("carbon") {
            return day < "2026-12-01" ? Price(input: 2, output: 10, cacheRead: 0.10) : Price(input: 4, output: 20, cacheRead: 0.20)
        }
        if id.contains("hydrogen") { return Price(input: 1.5, output: 7.5, cacheRead: 0.075) }
        if id.contains("flash") {
            return day < "2027-01-01" ? Price(input: 0.75, output: 3.75, cacheRead: 0.075) : Price(input: 1.5, output: 7.5, cacheRead: 0.15)
        }
        return nil
    }

    /// The family name the copied summary lists ("NEON", "OPUS").
    static func family(_ model: String) -> String {
        let id = model.lowercased()
        for name in ["neon", "argon", "carbon", "hydrogen", "flash", "opus", "sonnet", "haiku"] where id.contains(name) {
            return name.uppercased()
        }
        return model.uppercased()
    }

    /// Today, this week and this month from gdc's answer; nil when no account could be read.
    static func reading(from data: Data, now: Date = Date()) -> Reading? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accounts = json["accounts"] as? [[String: Any]] else { return nil }
        let keys = dateKeys(now: now)
        var today = 0.0, week = 0.0, month = 0.0
        var models = Set<String>(), unpriced = Set<String>(), failed: [String] = []
        var read = 0
        for account in accounts {
            guard let days = account["days"] as? [String: Any] else {
                failed.append((account["alias"] as? String) ?? (account["id"] as? String) ?? "?")
                continue
            }
            read += 1
            for (day, value) in days where day >= keys.monthStart || day >= keys.weekStart {
                guard let perModel = value as? [String: Any] else { continue }
                for (model, row) in perModel {
                    guard let counts = row as? [Any], counts.count >= 3,
                          let input = number(counts[0]), let cached = number(counts[1]), let output = number(counts[2]) else { continue }
                    guard let price = price(model: model, day: day) else {
                        if input + cached + output > 0 { unpriced.insert(model) }
                        continue
                    }
                    let cost = (input * price.input + cached * price.cacheRead + output * price.output) / 1_000_000
                    if day == keys.today { today += cost }
                    if day >= keys.weekStart {
                        week += cost
                        models.insert(family(model))
                    }
                    if day >= keys.monthStart { month += cost }
                }
            }
        }
        guard read > 0 else { return nil }
        return Reading(usage: LocalUsage(today: today, week: week, month: month, models: models.sorted()),
                       unpriced: unpriced.sorted(), failed: failed)
    }

    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    /// The same calendar the Claude Code cost uses: ISO weeks from Monday, local time.
    private static func dateKeys(now: Date) -> (today: String, weekStart: String, monthStart: String) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: today), formatter.string(from: weekStart), formatter.string(from: monthStart))
    }
}
