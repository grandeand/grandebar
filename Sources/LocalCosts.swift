import Foundation

/// Which cost the Claude mode footer shows. Codex mode shows only real Codex use; GrandeCodex
/// (the GrandeClaudex Codex workers) belongs to Claude mode and is only added to the Claude
/// Code cost when the total is picked on purpose.
enum CostView: String, CaseIterable {
    case grandeCodex
    case claude
    case total

    /// A click on the footer moves on: GrandeCodex → Claude → Total → GrandeCodex.
    var next: CostView {
        let views = CostView.allCases
        return views[(views.firstIndex(of: self)! + 1) % views.count]
    }

    /// The view picked last, or Claude until one is picked.
    static func resolved(_ stored: String?) -> CostView {
        stored.flatMap(CostView.init(rawValue:)) ?? .claude
    }
}

enum CostReading {
    case loading
    case unavailable
    case usage(LocalUsage)
}

/// The latest local costs, each read on its own.
struct LocalCosts {
    /// Real Codex use, every Codex home except the GrandeClaudex workers; Codex mode only.
    var codex: CostReading = .loading
    var grandeCodex: CostReading = .loading
    var claude: CostReading = .loading

    /// The total needs both costs: when one cannot be computed, neither can the sum.
    func reading(for view: CostView) -> CostReading {
        switch view {
        case .grandeCodex: return grandeCodex
        case .claude: return claude
        case .total:
            switch (grandeCodex, claude) {
            case let (.usage(grandeCodex), .usage(claude)):
                return .usage(LocalUsage(
                    today: grandeCodex.today + claude.today,
                    week: grandeCodex.week + claude.week,
                    month: grandeCodex.month + claude.month,
                    models: Array(Set(grandeCodex.models + claude.models)).sorted()
                ))
            case (.unavailable, _), (_, .unavailable):
                return .unavailable
            default:
                return .loading
            }
        }
    }
}
