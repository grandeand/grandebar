import Foundation

/// The weekly pace: the share of a 7-day limit window that has already passed, which is what an
/// evenly spent week would have used by now (day 3 of 7 → 43%). An account whose use is under its
/// pace is behind it (quota waits unused and is lost at the reset); one over its pace is ahead.
enum WeeklyPace {
    static let window: TimeInterval = 7 * 86_400
    /// How many points use and pace must differ by before a row counts as behind or ahead.
    static let margin = 15

    enum Standing: String, Equatable {
        /// Used at least `margin` points less than the pace: room that the reset would waste.
        case behind
        case even
        /// Used at least `margin` points more than the pace.
        case ahead
    }

    /// The share of the window that has passed when it resets at `resetsAt`, clamped to 0...1:
    /// 0 with the reset a full week (or more) away, 1 once it has passed. nil without a reset.
    static func fraction(resetsAt: Date?, now: Date = Date()) -> Double? {
        guard let resetsAt else { return nil }
        return min(1, max(0, (window - resetsAt.timeIntervalSince(now)) / window))
    }

    /// The pace a weekly row shows, in whole percent. A pace gdc reported (a fraction of 0...1) is
    /// used as it is; otherwise it comes from the reset time. nil without either, and nil once the
    /// reset has passed: the row then shows a fresh week whose next reset is not known yet.
    static func percent(resetsAt: Date?, now: Date = Date(), reported: Double? = nil) -> Int? {
        if let resetsAt, resetsAt <= now { return nil }
        let reported = reported.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        guard let value = reported ?? fraction(resetsAt: resetsAt, now: now) else { return nil }
        return Int((value * 100).rounded())
    }

    /// Where a row's use stands against its pace; nil when either is unknown. The rows show what
    /// is left, so the use is 100 minus that.
    static func standing(remainingPercent: Int?, pacePercent: Int?) -> Standing? {
        guard let remainingPercent, let pacePercent else { return nil }
        let gap = (100 - remainingPercent) - pacePercent
        if gap <= -margin { return .behind }
        if gap >= margin { return .ahead }
        return .even
    }

    /// What the weekly row adds after its percentage: "· pace 34%" ("· tempo 34%" in Turkish).
    static func rowText(_ pacePercent: Int, turkish: Bool) -> String {
        "· \(turkish ? "tempo" : "pace") \(pacePercent)%"
    }

    /// One account's model-scoped week (Fable) for the room line.
    struct RoomEntry: Equatable {
        let name: String
        let remainingPercent: Int?
        let pacePercent: Int?
    }

    /// "Fable room: a (7% vs pace 34%), b (10% vs pace 40%)": the accounts whose week is at least
    /// `margin` points behind its pace, in the given order. nil when none is.
    static func roomLine(label: String, entries: [RoomEntry], turkish: Bool) -> String? {
        let behind = entries.compactMap { entry -> String? in
            guard standing(remainingPercent: entry.remainingPercent, pacePercent: entry.pacePercent) == .behind,
                  let remaining = entry.remainingPercent, let pace = entry.pacePercent else { return nil }
            let used = 100 - remaining
            return turkish ? "\(entry.name) (\(used)% / tempo \(pace)%)" : "\(entry.name) (\(used)% vs pace \(pace)%)"
        }
        guard !behind.isEmpty else { return nil }
        let list = behind.joined(separator: ", ")
        return turkish ? "\(label) için yer var: \(list)" : "\(label) room: \(list)"
    }
}
