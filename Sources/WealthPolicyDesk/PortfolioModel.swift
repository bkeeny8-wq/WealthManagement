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

    /// Widely-held funds mapped to the sleeve whose exposure they actually carry. A dated
    /// convenience table to VERIFY, not an endorsement: it exists so a real brokerage
    /// statement classifies instead of arriving as a page of "classify by hand".
    /// Deliberately excludes anything already covered by a sleeve instrument or the
    /// value/growth style ladder, so this never shadows the model's own mapping.
    static let commonFundSleeves: [String: String] = [
        // US total market / large blend
        "VTI": "us_large_core", "ITOT": "us_large_core", "SCHB": "us_large_core",
        "SPY": "us_large_core", "FXAIX": "us_large_core", "VFIAX": "us_large_core",
        "VTSAX": "us_large_core", "SWPPX": "us_large_core", "IWB": "us_large_core",
        // Dividend / low-vol large blend
        "SCHD": "us_large_core", "VYM": "us_large_core", "DGRO": "us_large_core", "NOBL": "us_large_core",
        // US mid / small
        "IWM": "us_mid_small", "VXF": "us_mid_small", "IJS": "us_mid_small", "VTWO": "us_mid_small",
        // International developed
        "VXUS": "intl_developed", "IEFA": "intl_developed", "IXUS": "intl_developed",
        "SCHF": "intl_developed", "EFA": "intl_developed", "VTIAX": "intl_developed",
        // Emerging
        "IEMG": "emerging", "SCHE": "emerging", "SPEM": "emerging",
        // Real assets
        "SCHH": "real_assets", "IYR": "real_assets", "XLRE": "real_assets", "VNQI": "real_assets",
        // Core fixed income
        "AGG": "fixed_income_liquid", "SCHZ": "fixed_income_liquid", "IUSB": "fixed_income_liquid",
        "FXNAX": "fixed_income_liquid", "VBTLX": "fixed_income_liquid", "BNDX": "fixed_income_liquid",
        "VCIT": "fixed_income_liquid", "VCSH": "fixed_income_liquid", "LQD": "fixed_income_liquid",
        // Inflation-linked
        "TIP": "tips", "STIP": "tips", "SCHP": "tips",
        // Credit
        "USHY": "credit_hy", "SJNK": "credit_hy", "SHYG": "credit_hy",
        // Cash and money markets — the row every statement has and the model had no home for
        "VMFXX": "cash", "SPAXX": "cash", "SWVXX": "cash", "FDRXX": "cash",
        "VUSXX": "cash", "SGOV": "cash", "BIL": "cash", "SHV": "cash", "USFR": "cash",
    ]

    /// Best-guess policy sleeve for an arbitrary held ticker. Exact instrument match first
    /// (covers every ETF the model itself uses), then the value/growth style ETFs, then a
    /// sector SPDR → the sector-tilt sleeve, then fixed-income/commodity heuristics, then a
    /// single stock inherits a home by its sector. nil = no clean policy home (review).
    static func sleeveId(forTicker raw: String, sector: Sector? = nil) -> String? {
        let t = raw.uppercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        // 1. value/growth style ETFs across the US size ladder — FIRST, because VUG is both
        //    the large-growth style ETF and an option instrument of us_factor_tilt; a held VUG
        //    is US large core (growth flavor), not the factor satellite.
        if let bucket = USSizeBucket.bucket(forTicker: t) { return bucket.sleeveId }
        // 2. exact instrument in any sleeve (VOO, BND, VNQ, XLK, VLUE, …)
        if let s = legacyPolicy.sleeves.first(where: { $0.instruments.contains { $0.ticker.uppercased() == t } }) {
            return s.id
        }
        // 3. a sector SPDR is a sector bet
        if Sector.fromSpdr(t) != nil { return "us_sector_tilt" }
        // 4. fixed-income / commodity families
        if Engine.fiTickers.contains(t) { return "fixed_income_liquid" }
        if Engine.muniTickers.contains(t) { return "fixed_income_liquid" }
        if Engine.commodityTickers.contains(t) { return "commodities" }
        // 5. the common market: the funds a real statement is actually full of. The model
        //    only knew its OWN instruments, so a client holding VTI, SPY, SCHD or a money
        //    market fell to "classify by hand" — which is most of a typical book.
        if let s = commonFundSleeves[t] { return s }
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
    /// Given a home in the model — a policy sleeve, or an alt-budget function.
    public var isPlaced: Bool
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

            // Decide the action, most-pressing first. Concentration is checked BEFORE
            // classification: a concentrated single name (e.g. AAPL) usually has no clean
            // sleeve home, and "unwind it on a tax-aware schedule" is precisely the advice.
            var action: HoldingAction = .keep
            var rationale = ""
            var altLabel: String? = nil
            if !Engine.isSellable(p, treatment: treatment) {
                // The client already DECLARED what happens to this lot — hold it to step-up,
                // gift it, leave it to charity. Telling them to unwind it, and then in the
                // same card to hold it for the step-up, was the desk arguing with itself.
                action = .keep
                rationale = "Held per the plan for this position (\(p.disposition.label.lowercased()))"
                    + (p.isConcentrated ? " — concentrated, so revisit that earmark if the exposure is uncomfortable." : ".")
            } else if p.isConcentrated {
                action = .unwind
                rationale = "Concentrated single-name risk. Diversify into \(sleeve?.label ?? "the core policy sleeves") on a tax-aware schedule."
            } else if let fn = Engine.altFunction(ofTicker: p.ticker.uppercased()) {
                // An alternative is sized by its ALT BUDGET, not the sleeve targets — read it
                // against that budget rather than sending it to "review" for having no sleeve.
                altLabel = fn.label
                let row = eval.altSizing.first { $0.fn == fn }
                let target = row?.targetBps ?? 0
                let current = row?.currentBps ?? 0
                if current > target, target > 0, current - target >= 100 {
                    action = .trim
                    rationale = "A \(fn.label.lowercased()) alternative. The book carries \(Fmt.pctBps(current)) against a \(Fmt.pctBps(target)) budget for this function — trim toward budget."
                } else {
                    action = .keep
                    rationale = "A \(fn.label.lowercased()) alternative, sized by the alt budget rather than the sleeve targets: \(Fmt.pctBps(current)) held against a \(Fmt.pctBps(target)) budget."
                }
            } else if sleeveId == nil {
                action = .review
                rationale = "No clean policy sleeve for \(p.ticker) — classify it by hand or treat it as a satellite."
            } else if let sl = sleeve, prefersShelter(sl), treatment == .taxable,
                      !Engine.muniTickers.contains(p.ticker.uppercased()),
                      h.accounts.contains(where: { $0.treatment != .taxable }) {
                // Two guards. A municipal fund belongs in taxable — its whole point is
                // tax-exempt interest, which is wasted inside a shelter, so "relocate this
                // muni out of taxable" is backwards. And there is nowhere to relocate TO
                // unless the household actually holds a sheltered account.
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
                sleeveId: sleeveId, sleeveLabel: altLabel ?? sleeve?.label ?? "Unclassified",
                action: action, rationale: rationale, taxNote: taxNote, isConcentrated: p.isConcentrated,
                isPlaced: sleeveId != nil || altLabel != nil))
        }

        // Deterministic order: most-pressing action first, then larger positions, then ticker.
        suggestions.sort {
            if $0.action.rank != $1.action.rank { return $0.action.rank < $1.action.rank }
            if $0.marketValueUsd != $1.marketValueUsd { return $0.marketValueUsd > $1.marketValueUsd }
            return $0.ticker < $1.ticker
        }

        let itemized = holdings.reduce(0) { $0 + $1.marketValueUsd }
        let classified = suggestions.filter { $0.isPlaced }.reduce(0) { $0 + $1.marketValueUsd }
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
