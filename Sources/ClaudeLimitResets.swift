import Foundation

/// Claude's limit resets, the reset credits Claude Code spends with `/limit-reset`. The usage
/// endpoint adds them as a `cedar_ember` block when it is asked the way Claude Code asks
/// (`/api/oauth/usage?cedar_ember=1&skip_spend=1`); a plain read carries `cedar_ember: null`.
/// The block holds grants, each with `resets_left` resets usable until `ends_at`. Like Claude
/// Code, a null block, an ineligible account or one without grants holds no reset.
struct ClaudeLimitResets: Equatable {
    /// Resets left over every grant that has not run out.
    let count: Int
    /// When each reset runs out, soonest first: a grant's `ends_at` once per reset it holds, like
    /// the Codex reset credits' expiries. Resets of a grant without an end are counted, not listed.
    let expiries: [Date]

    static let none = ClaudeLimitResets(count: 0, expiries: [])

    /// nil when the answer says nothing about resets: no `cedar_ember` key at all, or a block that
    /// is not an object. Claude Code drops a grant it cannot read; so does this.
    static func parse(_ usage: [String: Any], now: Date = Date()) -> ClaudeLimitResets? {
        guard let raw = usage["cedar_ember"] else { return nil }
        if raw is NSNull { return ClaudeLimitResets.none }
        guard let block = raw as? [String: Any] else { return nil }
        guard (block["eligible"] as? Bool) == true else { return ClaudeLimitResets.none }

        var count = 0
        var expiries: [Date] = []
        for case let grant as [String: Any] in block["grants"] as? [Any] ?? [] {
            guard let left = wholeNumber(grant["resets_left"]), left > 0 else { continue }
            let endsAt = (grant["ends_at"] as? String).flatMap(date)
            if let endsAt, endsAt <= now { continue }
            count += left
            if let endsAt { expiries += Array(repeating: endsAt, count: min(left, maxListedPerGrant)) }
        }
        return ClaudeLimitResets(count: count, expiries: expiries.sorted())
    }

    /// A stored read moved to `now`: the resets whose grant ran out since are gone. nil when the
    /// read carried no count.
    static func stored(count: Int?, expiries: [Date]?, now: Date = Date()) -> ClaudeLimitResets? {
        guard let count else { return nil }
        let all = (expiries ?? []).sorted()
        let left = all.filter { $0 > now }
        return ClaudeLimitResets(count: max(0, count - (all.count - left.count)), expiries: left)
    }

    private static let maxListedPerGrant = 100

    /// A count the API sends as a whole number; Claude Code refuses fractions and negatives.
    private static func wholeNumber(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double >= 0, double == double.rounded(), double < Double(Int.max) else { return nil }
        return Int(double)
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// How Claude mode writes the resets, in Codex mode's words: "Reset N" and the soonest expiry on
/// a line under the card's rows, and "N account · R reset" in the header. The plan chip stays as
/// it is, so the e-mail beside it keeps its room.
extension ClaudeLimitResets {
    /// "Reset 2 · first credit expires Nov 20 14:00", or "Reset 2" when no reset has an end; nil
    /// while the account holds no reset or its count is unknown (the header still says 0).
    static func cardLine(count: Int?, expiries: [Date], now: Date = Date(), turkish: Bool, format: (Date) -> String) -> String? {
        guard let count, count > 0 else { return nil }
        guard let first = expiries.sorted().first(where: { $0 > now }) else { return "Reset \(count)" }
        return turkish ? "Reset \(count) · ilk hak bitişi \(format(first))" : "Reset \(count) · first credit expires \(format(first))"
    }

    /// The plan chip's tooltip; nil while the count is unknown.
    static func chipToolTip(count: Int?, turkish: Bool) -> String? {
        guard let count else { return nil }
        if count == 0 {
            return turkish ? "Limit reset hakkı yok (Claude Code /limit-reset)" : "No limit resets (Claude Code's /limit-reset)"
        }
        return turkish ? "\(count) limit reset hakkı kaldı (Claude Code /limit-reset)" : "\(count) limit reset(s) left (Claude Code's /limit-reset)"
    }

    /// " · R reset" after a header's account count, the known counts summed; empty while no
    /// account's count is known, so an unknown count never reads as 0.
    static func headerSuffix(_ counts: [Int?]) -> String {
        let known = counts.compactMap { $0 }
        guard !known.isEmpty else { return "" }
        return " · \(known.reduce(0, +)) reset"
    }
}
