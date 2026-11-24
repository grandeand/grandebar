import Foundation

/// Claude mode's limit list is split by where the accounts come from.
enum ClaudeLimitsTab: String, CaseIterable {
    case desktop
    case claudex
    case cliproxy
    /// GrandeClaudex's Antigravity accounts (Google's agy), read through the same gdc.
    case antigravity

    var title: String {
        switch self {
        case .desktop: return "Desktop"
        case .claudex: return "Claudex"
        case .cliproxy: return "CLIProxy"
        case .antigravity: return "Antigravity"
        }
    }

    /// The Claudex and Antigravity tabs are there only while GrandeClaudex's gdc is installed.
    static func visible(claudexInstalled: Bool) -> [ClaudeLimitsTab] {
        allCases.filter { !$0.readsGdc || claudexInstalled }
    }

    /// Filled from `gdc usage --json`.
    var readsGdc: Bool {
        self == .claudex || self == .antigravity
    }

    /// The remembered tab, or Desktop when it is unknown or not shown.
    static func resolved(_ stored: String?, claudexInstalled: Bool) -> ClaudeLimitsTab {
        guard let tab = stored.flatMap(ClaudeLimitsTab.init(rawValue:)),
              visible(claudexInstalled: claudexInstalled).contains(tab) else { return .desktop }
        return tab
    }
}
