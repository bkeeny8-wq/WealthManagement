//  PortfolioModel.swift
//  WealthPolicyDesk
//
//  "Bring your current portfolio and integrate it into the model." Two pieces the rest
//  of the desk was missing:
//    1. a ticker → policy-sleeve CLASSIFIER for arbitrary client holdings (the desk could
//       map its own model instruments, but nothing mapped a real held ticker), and
//    2. a per-holding SUGGESTION engine that maps each holding to a sleeve, reads the
//       allocation gap the book already computes, and recommends keep / add / trim /
//       relocate / unwind — tax-aware by account type + cost basis.
//
//  Everything here is a pure read of the household + evaluation; no forecasts. It reuses
//  the sleeve targets (AllocationRow), the sleeves' asset-location preference, and the
//  realized-gain math the disposition/rebalance engines already use.

import Foundation

// MARK: - Ticker → sleeve classification

public extension Seed {
    /// Best-guess policy sleeve for an arbitrary held ticker. Exact instrument match first
    /// (covers every ETF the model itself uses), then the value/growth style ETFs, then a
    /// sector SPDR → the sector-tilt sleeve, then fixed-income/commodity heuristics, then a
    /// single stock inherits a home by its sector. nil = no clean policy home (review).
    static func sleeveId(forTicker raw: String, sector: Sector? = nil) -> String? {
        let t = raw.uppercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        // 1. exact instrument in any sleeve (VOO, BND, VNQ, XLK, VLUE, …)
        if let s = legacyPolicy.sleeves.first(where: { $0.instruments.contains { $0.ticker.uppercased() == t } }) {
            return s.id
        }
        // 2. value/growth style ETFs across the US size ladder
        if let bucket = USSizeBucket.bucket(forTicker: t) { return bucket.sleeveId }
        // 3. a sector SPDR is a sector bet
        if Sector.fromSpdr(t) != nil { return "us_sector_tilt" }
        // 4. fixed-income / commodity families
        if Engine.fiTickers.contains(t) { return "fixed_income_liquid" }
        if Engine.muniTickers.contains(t) { return "fixed_income_liquid" }
        if Engine.commodityTickers.contains(t) { return "commodities" }
        // 5. a single stock inherits its sector's home: a sector name → the sector tilt,
        //    otherwise US large core (a large-cap equity by default).
        if sector != nil { return "us_large_core" }
        return nil
    }
}

// MARK: - Per-holding integration suggestion

public enum HoldingAction: String, Sendable, Hashable {
    case keep, add, trim, relocate, unwind, review
    public var label: String {
        switch self {
        case .keep: return "Keep"
        case .add: return "Room to add"
        case .trim: return "Trim"
        case .relocate: return "Relocate"
        case .unwind: return "Unwind"
        case .review: return "Review"
        }
    }
    /// A stable rank for sorting the board — the actions that need attention first.
    public var rank: Int {
        switch self { case .unwind: return 0; case .relocate: return 1; case .trim: return 2
        case .review: return 3; case .add: return 4; case .keep: return 5 }
    }
}

public struct HoldingSuggestion: Identifiable, Sendable, Hashable {
    public var id: String
    public var ticker: String
    public var accountLabel: String
    public var treatment: AccountTaxTreatment
    public var marketValueUsd: Usd
    public var unrealizedGainUsd: Usd
    public var sleeveId: String?
    public var sleeveLabel: String
    public var action: HoldingAction
    public var rationale: String
    public var taxNote: String?
    public var isConcentrated: Bool
}

public struct PortfolioIntegration: Sendable {
    public var suggestions: [HoldingSuggestion]
    public var itemizedUsd: Usd          // total of the real, entered holdings
    public var classifiedUsd: Usd        // of those, how much mapped to a sleeve
    public var unrealizedGainUsd: Usd    // total embedded gain in the entered holdings
    public var actionCounts: [HoldingAction: Int]
    public var summary: String
    public var hasHoldings: Bool { !suggestions.isEmpty }
}

public extension Engine {

    /// Turn the client's entered holdings (the itemized, real positions — those the advisor
    /// typed, i.e. `sleeveId == nil`) into per-holding integration suggestions against the
    /// policy the desk already derived.
    static func portfolioIntegration(_ eval: Evaluation) -> PortfolioIntegration {
        let h = eval.household
        // The "current portfolio" = the real holdings the advisor entered (itemized held-away
        // positions carry a real ticker and no sleeve). Synthesized policy proxies are skipped.
        let holdings = h.positions.filter { $0.sleeveId == nil && !$0.ticker.trimmingCharacters(in: .whitespaces).isEmpty }
        let rowsBySleeve = Dictionary(uniqueKeysWithValues: eval.allocation.map { ($0.sleeveId, $0) })

        var suggestions: [HoldingSuggestion] = []
        for p in holdings {
            let sleeveId = Seed.sleeveId(forTicker: p.ticker, sector: p.effectiveSector)
            let sleeve = sleeveId.flatMap { sid in Seed.legacyPolicy.sleeves.first { $0.id == sid } }
            let row = sleeveId.flatMap { rowsBySleeve[$0] }
            let gain = p.unrealizedGainUsd
            let treatment = h.treatment(of: p)

            // Decide the action, most-pressing first.
            var action: HoldingAction = .keep
            var rationale = ""
            if sleeveId == nil {
                action = .review
                rationale = "No clean policy sleeve for \(p.ticker) — classify it by hand or treat it as a satellite."
            } else if p.isConcentrated {
                action = .unwind
                rationale = "Concentrated single-name risk. Diversify into \(sleeve?.label ?? "the policy sleeves") on a tax-aware schedule."
            } else if let sl = sleeve, prefersShelter(sl), treatment == .taxable {
                action = .relocate
                rationale = "\(sl.label) is tax-inefficient in a taxable account — hold it in a tax-deferred/Roth account instead."
            } else if let r = row, r.driftBps >= r.innerBandBps {
                action = .trim
                rationale = "\(sleeve?.label ?? "This sleeve") is over its policy target (\(Fmt.pctBps(r.currentBps)) vs \(Fmt.pctBps(r.targetBps))) — trim toward target."
            } else if let r = row, r.driftBps <= -r.innerBandBps {
                action = .add
                rationale = "\(sleeve?.label ?? "This sleeve") is under its policy target (\(Fmt.pctBps(r.currentBps)) vs \(Fmt.pctBps(r.targetBps))) — this holding fits; there is room to add."
            } else {
                action = .keep
                rationale = "Maps cleanly to \(sleeve?.label ?? "policy") and the sleeve is near target — hold it as core."
            }

            // Tax note by account + embedded gain.
            var taxNote: String? = nil
            if action == .trim || action == .unwind || action == .relocate {
                if treatment == .taxable {
                    taxNote = gain > 0
                        ? "Selling realizes ~\(Fmt.usdShort(gain)) of gain — stage within the transition gain budget, or hold low-basis lots to step-up."
                        : "Low/negative embedded gain — little or no tax cost to reposition."
                } else {
                    taxNote = "Held in a \(treatment.short.lowercased()) account — reposition freely, no tax on the sale."
                }
            }

            suggestions.append(HoldingSuggestion(
                id: p.id, ticker: p.ticker, accountLabel: h.account(p.accountId)?.label ?? treatment.short,
                treatment: treatment, marketValueUsd: p.marketValueUsd, unrealizedGainUsd: gain,
                sleeveId: sleeveId, sleeveLabel: sleeve?.label ?? "Unclassified",
                action: action, rationale: rationale, taxNote: taxNote, isConcentrated: p.isConcentrated))
        }

        // Deterministic order: most-pressing action first, then larger positions, then ticker.
        suggestions.sort {
            if $0.action.rank != $1.action.rank { return $0.action.rank < $1.action.rank }
            if $0.marketValueUsd != $1.marketValueUsd { return $0.marketValueUsd > $1.marketValueUsd }
            return $0.ticker < $1.ticker
        }

        let itemized = holdings.reduce(0) { $0 + $1.marketValueUsd }
        let classified = suggestions.filter { $0.sleeveId != nil }.reduce(0) { $0 + $1.marketValueUsd }
        let totalGain = holdings.reduce(0) { $0 + $1.unrealizedGainUsd }
        var counts: [HoldingAction: Int] = [:]
        for s in suggestions { counts[s.action, default: 0] += 1 }

        let summary: String
        if suggestions.isEmpty {
            summary = "No individual holdings entered yet. Add the client's current positions above and each one is mapped to a policy sleeve with a tax-aware integration step."
        } else {
            let attention = suggestions.filter { $0.action != .keep && $0.action != .add }.count
            summary = attention == 0
                ? "All \(suggestions.count) holdings map cleanly to the policy and sit near target — no repositioning needed."
                : "\(attention) of \(suggestions.count) holdings need a step to align with the policy — most-pressing first."
        }

        return PortfolioIntegration(suggestions: suggestions, itemizedUsd: itemized, classifiedUsd: classified,
                                    unrealizedGainUsd: totalGain, actionCounts: counts, summary: summary)
    }

    /// A sleeve is better sheltered when its top location preference is a tax-advantaged account.
    private static func prefersShelter(_ s: Sleeve) -> Bool {
        guard let first = s.locationPreference.first else { return false }
        return first == .taxDeferred || first == .taxFree
    }
}
