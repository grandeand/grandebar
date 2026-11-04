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

    /// What the copied summary adds after a weekly value: "· pace 34%" ("· tempo 34%" in Turkish).
    static func rowText(_ pacePercent: Int, turkish: Bool) -> String {
        "· \(turkish ? "tempo" : "pace") \(pacePercent)%"
    }

    /// One weekly row of an account for the pace summary: the general weekly or the model one.
    struct Row: Equatable {
        let label: String
        let remainingPercent: Int?
        let pacePercent: Int?
    }

    /// One account in a list, with its weekly rows.
    struct Account: Equatable {
        let name: String
        let rows: [Row]
    }

    /// An account in the summary: its widest gap to the pace in points, and the rows that make it.
    struct Entry: Equatable {
        let name: String
        let gap: Int
        let rows: [Row]
    }

    /// The summary over a list of accounts: those with a weekly row at least `margin` points
    /// behind its pace (room the reset would waste) and those with one at least `margin` points
    /// ahead, each widest gap first, the list order between equal gaps. An account with one row
    /// behind and another ahead is in both.
    static func summary(_ accounts: [Account]) -> (behind: [Entry], ahead: [Entry]) {
        func entries(_ wanted: Standing) -> [Entry] {
            let found = accounts.enumerated().compactMap { index, account -> (Int, Entry)? in
                let rows = account.rows.filter { standing(remainingPercent: $0.remainingPercent, pacePercent: $0.pacePercent) == wanted }
                let gaps = rows.compactMap(gap)
                guard let widest = gaps.map(abs).max() else { return nil }
                return (index, Entry(name: account.name, gap: widest, rows: rows))
            }
            return found.sorted { $0.1.gap != $1.1.gap ? $0.1.gap > $1.1.gap : $0.0 < $1.0 }.map(\.1)
        }
        return (entries(.behind), entries(.ahead))
    }

    /// Use minus pace in points: negative behind the pace, positive ahead. nil when either is unknown.
    static func gap(_ row: Row) -> Int? {
        guard let remaining = row.remainingPercent, let pace = row.pacePercent else { return nil }
        return (100 - remaining) - pace
    }

    /// The tooltip of an account's chip in the summary, one line per row:
    /// "Fable: 20% used, pace 43% · 23 points behind".
    static func entryToolTip(_ entry: Entry, turkish: Bool) -> String {
        entry.rows.compactMap { row -> String? in
            guard let remaining = row.remainingPercent, let pace = row.pacePercent, let gap = gap(row) else { return nil }
            let used = 100 - remaining
            if turkish {
                return "\(row.label): \(used)% kullanıldı, tempo \(pace)% · \(abs(gap)) puan \(gap < 0 ? "geride" : "önde")"
            }
            return "\(row.label): \(used)% used, pace \(pace)% · \(abs(gap)) points \(gap < 0 ? "behind" : "ahead")"
        }.joined(separator: "\n")
    }
}
