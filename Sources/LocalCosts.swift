import Foundation

/// Which local token cost the popover footer shows. The Codex and Claude Code costs stay apart;
/// their sum is only on screen when it is picked on purpose.
enum CostView: String, CaseIterable {
    case codex
    case claude
    case total

    /// A click on the footer moves on: Codex → Claude → Total → Codex.
    var next: CostView {
        let views = CostView.allCases
        return views[(views.firstIndex(of: self)! + 1) % views.count]
    }

    /// The view picked last, or, until one is picked, the view that matches the mode.
    static func resolved(_ stored: String?, claudeMode: Bool) -> CostView {
        stored.flatMap(CostView.init(rawValue:)) ?? (claudeMode ? .claude : .codex)
    }
}

enum CostReading {
    case loading
    case unavailable
    case usage(LocalUsage)
}

/// The latest Codex and Claude Code costs, each read on its own whatever the mode.
struct LocalCosts {
    var codex: CostReading = .loading
    var claude: CostReading = .loading

    /// The total needs both costs: when one cannot be computed, neither can the sum.
    func reading(for view: CostView) -> CostReading {
        switch view {
        case .codex: return codex
        case .claude: return claude
        case .total:
            switch (codex, claude) {
            case let (.usage(codex), .usage(claude)):
                return .usage(LocalUsage(
                    today: codex.today + claude.today,
                    week: codex.week + claude.week,
                    month: codex.month + claude.month,
                    models: Array(Set(codex.models + claude.models)).sorted()
                ))
            case (.unavailable, _), (_, .unavailable):
                return .unavailable
            default:
                return .loading
            }
        }
    }
}
