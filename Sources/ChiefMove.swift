import Foundation

/// Where to move the GrandeClaudex chief when the account Claude Desktop runs it on runs low: the
/// saved Desktop logins that are GrandeClaudex Claude workers with room, best first. GrandeBar
/// then switches Desktop to the pick, so the chief's Code session goes on there, and records the
/// new seat with `gdc chief-seat --set`.
///
/// An account has room when its 5-hour window is under `fiveHourLimit` and none of its weekly
/// limits (the general one and the Fable one) is used ahead of its pace. Among those the same
/// email domain (organization) as the current account comes first, then the lowest weekly pace
/// gap (use minus the share of the week that has passed, the widest of its weekly rows: quota a
/// reset would waste goes first), then the lowest 5-hour use, then the order of the saved logins.
enum ChiefMove {
    /// A 5-hour window used this much (percent) or more leaves no room for the chief.
    static let fiveHourLimit = 80

    /// A login GrandeBar keeps for Claude Desktop (`DesktopAccount`), as far as the ranking needs it.
    struct SavedAccount: Equatable {
        let alias: String
        let accountUUID: String
        let email: String?
    }

    /// One weekly limit of an account, in whole percent.
    struct WeeklyRow: Equatable {
        /// nil for the general weekly limit, the model ("Fable") for a model-scoped one.
        let label: String?
        let usedPercent: Int
        /// nil when gdc gives no reset time or pace, or the reset has passed.
        let pacePercent: Int?

        /// Use minus pace in points: negative behind the pace, positive ahead of it.
        var gap: Int? { pacePercent.map { usedPercent - $0 } }
    }

    enum Skip: Equatable {
        /// The 5-hour window is used `fiveHourLimit` percent or more.
        case fiveHourFull
        /// A weekly limit is used ahead of its pace.
        case aheadOfPace
        /// gdc has no limits for the account: the worker is signed out or was never read.
        case noLimits
    }

    /// A GrandeClaudex Claude worker's account with its numbers, and the saved Desktop login for it.
    struct Option: Equatable {
        /// nil for a worker account Claude Desktop has no saved login for yet.
        let account: SavedAccount?
        let worker: GrandeClaudexWorker
        let fiveHourUsed: Int?
        let weekly: [WeeklyRow]
        /// The same email domain (organization) as the account Desktop is on now.
        let sameDomain: Bool
        /// Why the account has no room now; nil when it has.
        let skip: Skip?

        var email: String { account?.email ?? worker.email ?? worker.id }

        /// The weekly row furthest ahead of its pace (or least behind it); nil when no row has a pace.
        var paceGap: Int? { weekly.compactMap(\.gap).max() }
    }

    struct Plan: Equatable {
        /// Saved Desktop logins with room, best first.
        let candidates: [Option]
        /// Saved Desktop logins of workers without room now, in the same order.
        let skipped: [Option]
        /// Worker accounts with room that Desktop has no saved login for; "Add Account…" adds them.
        let missing: [Option]

        var pick: Option? { candidates.first }
        var runnerUp: Option? { candidates.dropFirst().first }
    }

    /// Ranks the saved Desktop logins that match a GrandeClaudex Claude worker by email, without
    /// the one Desktop is signed into now (`currentAccountUUID`). `currentEmail` decides the
    /// preferred domain; a worker with that email is never reported as missing either.
    static func plan(accounts: [SavedAccount], currentAccountUUID: String?, currentEmail: String?,
                     snapshot: GrandeClaudexSnapshot, now: Date = Date()) -> Plan {
        let domain = currentEmail.flatMap(Self.domain)
        func workerFor(_ email: String?) -> GrandeClaudexWorker? {
            guard let email = email?.lowercased() else { return nil }
            return snapshot.workers.first { $0.email?.lowercased() == email }
        }
        let saved = accounts
            .filter { $0.accountUUID != currentAccountUUID }
            .compactMap { account in workerFor(account.email).map { option(account: account, worker: $0, domain: domain, now: now) } }
        let savedEmails = Set(accounts.compactMap { $0.email?.lowercased() })
        let missing = snapshot.workers
            .filter { worker in
                guard let email = worker.email?.lowercased() else { return false }
                return !savedEmails.contains(email) && email != currentEmail?.lowercased()
            }
            .map { option(account: nil, worker: $0, domain: domain, now: now) }
            .filter { $0.skip == nil }
        return Plan(
            candidates: ranked(saved.filter { $0.skip == nil }),
            skipped: ranked(saved.filter { $0.skip != nil }),
            missing: ranked(missing)
        )
    }

    /// The account's numbers from gdc, as the Claudex cards show them (a window whose reset has
    /// passed counts as unused).
    static func option(account: SavedAccount?, worker: GrandeClaudexWorker, domain: String?, now: Date = Date()) -> Option {
        let fiveHour = worker.fiveHourWindow(now: now).map { 100 - $0.remainingPercent }
        let general = worker.sevenDayWindow(now: now).map {
            WeeklyRow(label: worker.weeklyModel, usedPercent: 100 - $0.remainingPercent, pacePercent: $0.pacePercent)
        }
        let model = worker.sevenDayModelWindow(now: now).map {
            WeeklyRow(label: worker.sevenDayModelLabel ?? "Fable", usedPercent: 100 - $0.remainingPercent, pacePercent: $0.pacePercent)
        }
        let weekly = [general, model].compactMap { $0 }
        let skip: Skip?
        if !worker.loggedIn || (fiveHour == nil && weekly.isEmpty) {
            skip = .noLimits
        } else if (fiveHour ?? 0) >= fiveHourLimit {
            skip = .fiveHourFull
        } else if weekly.contains(where: { ($0.gap ?? 0) > 0 }) {
            skip = .aheadOfPace
        } else {
            skip = nil
        }
        let email = account?.email ?? worker.email
        return Option(account: account, worker: worker, fiveHourUsed: fiveHour, weekly: weekly,
                      sameDomain: domain != nil && email.flatMap(Self.domain) == domain, skip: skip)
    }

    /// Same domain first, then the lowest pace gap (a row without a pace counts as on pace), then
    /// the lowest 5-hour use, then the given order.
    static func ranked(_ options: [Option]) -> [Option] {
        options.enumerated().sorted { left, right in
            let a = left.element, b = right.element
            if a.sameDomain != b.sameDomain { return a.sameDomain }
            if (a.paceGap ?? 0) != (b.paceGap ?? 0) { return (a.paceGap ?? 0) < (b.paceGap ?? 0) }
            if (a.fiveHourUsed ?? 0) != (b.fiveHourUsed ?? 0) { return (a.fiveHourUsed ?? 0) < (b.fiveHourUsed ?? 0) }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// The part after the @, lowercased; nil for something that is not an address.
    static func domain(_ email: String) -> String? {
        let parts = email.lowercased().split(separator: "@")
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    // MARK: Text

    /// "5h 5% · weekly 20% (pace 75%) · Fable 14% (pace 75%)": use, not what is left.
    static func numbers(_ option: Option, turkish: Bool) -> String {
        var parts = [(turkish ? "5 saat " : "5h ") + percent(option.fiveHourUsed)]
        for row in option.weekly {
            let name = row.label ?? (turkish ? "haftalık" : "weekly")
            let pace = row.pacePercent.map { turkish ? " (tempo \($0)%)" : " (pace \($0)%)" } ?? ""
            parts.append("\(name) \(row.usedPercent)%" + pace)
        }
        return parts.joined(separator: " · ")
    }

    /// "55 points behind the pace", "on pace", "12 points ahead of the pace"; nil without a pace.
    static func gapText(_ gap: Int?, turkish: Bool) -> String? {
        guard let gap else { return nil }
        if gap == 0 { return turkish ? "tempoda" : "on pace" }
        if gap < 0 { return turkish ? "tempodan \(-gap) puan geride" : "\(-gap) points behind the pace" }
        return turkish ? "tempodan \(gap) puan önde" : "\(gap) points ahead of the pace"
    }

    /// Why an account has no room: "5h 85%", "weekly 12 points ahead of the pace", …
    static func skipText(_ option: Option, turkish: Bool) -> String {
        switch option.skip {
        case .fiveHourFull?:
            return (turkish ? "5 saat " : "5h ") + percent(option.fiveHourUsed)
        case .aheadOfPace?:
            let row = option.weekly.max { ($0.gap ?? .min) < ($1.gap ?? .min) }
            let name = row?.label ?? (turkish ? "haftalık" : "weekly")
            return "\(name) " + (gapText(row?.gap, turkish: turkish) ?? "")
        case .noLimits?:
            return turkish ? "gdc'de limiti yok" : "no limits from gdc"
        case nil:
            return turkish ? "yer var" : "has room"
        }
    }

    /// The account as a confirmation line: "grande1@grandecorpo.com (trossard): 5h 5% · weekly
    /// 20% (pace 75%) · 55 points behind the pace".
    static func line(_ option: Option, turkish: Bool) -> String {
        let gap = gapText(option.paceGap, turkish: turkish).map { " · " + $0 } ?? ""
        return "\(option.email) (\(option.worker.alias)): " + numbers(option, turkish: turkish) + gap
    }

    private static func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "--"
    }
}
