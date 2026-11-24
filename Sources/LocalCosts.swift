import Foundation

/// Which cost the Claude mode footer shows. Codex mode shows only real Codex use; GrandeCodex
/// (the GrandeClaudex Codex workers) belongs to Claude mode and is only added to the Claude
/// Code cost when the total is picked on purpose.
enum CostView: String, CaseIterable {
    case grandeCodex
    case claude
    /// GrandeClaudex's Antigravity accounts, read through gdc; left out where gdc is not installed.
    case antigravity
    case total

    /// A click on the footer moves on: GrandeCodex → Claude → Antigravity → Total → GrandeCodex.
    var next: CostView {
        next(withAntigravity: true)
    }

    func next(withAntigravity: Bool) -> CostView {
        let views = CostView.allCases.filter { withAntigravity || $0 != .antigravity }
        let index = views.firstIndex(of: self) ?? views.firstIndex(of: .total)!
        return views[(index + 1) % views.count]
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
    /// nil where GrandeClaudex's gdc is not installed: no Antigravity cost, and the total leaves it out.
    var antigravity: CostReading? = nil

    /// The total needs every cost it adds up: when one cannot be computed, neither can the sum.
    func reading(for view: CostView) -> CostReading {
        switch view {
        case .grandeCodex: return grandeCodex
        case .claude: return claude
        case .antigravity: return antigravity ?? .unavailable
        case .total:
            let parts = [grandeCodex, claude] + (antigravity.map { [$0] } ?? [])
            var usages: [LocalUsage] = []
            for part in parts {
                switch part {
                case .usage(let usage): usages.append(usage)
                case .unavailable: return .unavailable
                case .loading: break
                }
            }
            guard usages.count == parts.count else {
                return parts.contains { if case .unavailable = $0 { return true } else { return false } } ? .unavailable : .loading
            }
            return .usage(LocalUsage(
                today: usages.reduce(0) { $0 + $1.today },
                week: usages.reduce(0) { $0 + $1.week },
                month: usages.reduce(0) { $0 + $1.month },
                models: Array(Set(usages.flatMap(\.models))).sorted()
            ))
        }
    }
}
