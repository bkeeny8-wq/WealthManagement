//  AllocationSolver.swift
//  WealthPolicyDesk
//
//  resolveTargets — "allocation is an output" made real. Instead of handing a
//  fixed sleeve policy to every household, this derives the equity/FI split from
//  the household's OWN claims, with NO capital-market forecast:
//
//    • BOND FLOOR = liability. Fixed income is sized to the ladder + reserve +
//      12-month floor (the liquidity requirement), expressed as a share — "sized
//      to liquidity, NOT to a target percentage", finally enforced.
//    • EQUITY CEILING = risk. The capacity-vs-tolerance binding equity share the
//      risk profile already computes is the most equity the plan may hold.
//    • WHERE equity sits between a de-risk floor and that ceiling is set by the
//      FUNDED RATIO: at/below fully-funded, pin equity to the ceiling (you need
//      the growth); as the plan runs past fully-funded, glide it down to the
//      floor (you've won — stop taking the risk).
//
//  If even the ceiling can't fund the plan, that is a FUNDING problem — defer or
//  scale a goal, or save more — not an allocation dial (surfaced as the
//  `underfunded_at_risk_ceiling` finding). The intra-equity diversification mix
//  stays a structural template, renormalized to the derived equity total: nobody
//  derives "emerging vs. developed" from a household's goals; the stock/bond
//  split is the real allocation decision and the one worth solving.
//
//  The funded-status glide knobs below are planning heuristics, NOT forecasts.

import Foundation

public extension Engine {
    /// At or below this funded ratio, hold the most equity the risk ceiling allows.
    static let fundedFloorBps: Bps = 10_000        // 100%
    /// At or above this funded ratio, de-risk equity all the way to the floor.
    static let fundedCeilBps: Bps = 12_500         // 125%
    /// The de-risked equity floor for an over-funded, long-horizon plan.
    static let equityDeriskFloorBps: Bps = 3_000   // 30%
    /// The one sleeve that is fixed income (everything else is the growth bucket).
    static let fiSleeveId = "fixed_income_liquid"

    /// The alt budget's equity/credit-beta contribution to total-portfolio equity,
    /// so the risk ceiling can be a TRUE total cap: buffered equity (shaped payoff)
    /// carries ~0.5 beta, private credit / PE ~0.7; convexity hedges (trend, gold)
    /// carry ~none. Lets resolveTargets reserve room for the alt slice's risk.
    static func altEquityEquivalentBps(_ policy: InvestmentPolicy) -> Bps {
        policy.altBudgets.reduce(0) { acc, b in
            let beta: Double
            switch b.fn {
            case .shapedPayoff: beta = 0.5
            case .illiquidityPremium: beta = 0.7
            case .convexity: beta = 0.0
            }
            return acc + Int((Double(b.targetBps) * beta).rounded())
        }
    }

    /// Derive per-household sleeve targets. Returns a copy of `base` with sleeve
    /// `targetBps` replaced; tiers, alt budgets, instruments, bands, and rationale
    /// are untouched. Falls back to `base` unchanged when there is nothing to size.
    static func resolveTargets(_ h: Household, base: InvestmentPolicy, fundedRatioBps: Bps, equityCeilingBps: Bps, ladder: LadderPlan) -> InvestmentPolicy {
        let v = h.portfolioValueUsd
        let sleeveBudget = base.sleeves.reduce(0) { $0 + $1.targetBps }      // the non-alt space (~8000 bps)
        let baseGrowth = base.sleeves.filter { $0.role == .growth }.reduce(0) { $0 + $1.targetBps }
        let nonGrowth = base.sleeves.filter { $0.role != .growth }
        guard v > 0, sleeveBudget > 0, baseGrowth > 0, !nonGrowth.isEmpty else { return base }

        // 1) Liquidity floor = a NEAR-TERM minimum — the rebalance reserve plus ~one
        //    year of near-term net outflow — expressed as a share. It flows to CASH
        //    (the zero-duration bucket). NOT the full multi-year ladder, which stays
        //    the separate hard liquidity_floor finding; here the growth/defensive
        //    split is driven by risk and funded status, cash never below this minimum.
        let fiFloorUsd = ladder.rebalanceReserveUsd + ladder.twelveMonthFloorUsd
        let cashFloor = max(0, min(sleeveBudget, (fiFloorUsd / v).bps))

        // 2) Growth ceiling = risk. bindingEquityBps is a TOTAL-portfolio equity cap,
        //    so charge the alt budget's own equity/credit beta against it — sleeve
        //    growth PLUS that alt beta stays under the ceiling — within the room the
        //    cash floor leaves.
        let altEquiv = altEquityEquivalentBps(base)
        let growthCeiling = max(0, min(equityCeilingBps - altEquiv, sleeveBudget - cashFloor))
        let growthFloor = min(growthCeiling, equityDeriskFloorBps)

        // 3) Funded-status glide: underfunded → ceiling, overfunded → floor.
        let span = max(1, fundedCeilBps - fundedFloorBps)
        let t = min(1.0, max(0.0, Double(fundedRatioBps - fundedFloorBps) / Double(span)))
        let growthTarget = Int((Double(growthCeiling) * (1 - t) + Double(growthFloor) * t).rounded())
        let nonGrowthBudget = max(0, sleeveBudget - growthTarget)

        // 4) Within non-growth, cash takes at least the liquidity floor (or its
        //    structural share, whichever is larger); the rest of the defensive /
        //    real-diversifier sleeves split what remains by their structural weights.
        let baseNonGrowth = nonGrowth.reduce(0) { $0 + $1.targetBps }
        let baseCash = nonGrowth.filter { $0.role == .cash }.reduce(0) { $0 + $1.targetBps }
        let structuralCash = baseNonGrowth > 0 ? Int(Double(nonGrowthBudget) * Double(baseCash) / Double(baseNonGrowth)) : 0
        let cashTarget = min(nonGrowthBudget, max(structuralCash, cashFloor))
        let otherBudget = max(0, nonGrowthBudget - cashTarget)
        let baseOther = nonGrowth.filter { $0.role != .cash }.reduce(0) { $0 + $1.targetBps }

        // 5) Build the derived sleeves in place (order preserved). Growth scales to
        //    growthTarget; cash to cashTarget; other non-growth to otherBudget.
        var derived: [Sleeve] = base.sleeves.map { s in
            var ns = s
            switch s.role {
            case .growth:
                ns.targetBps = baseGrowth > 0 ? Int((Double(growthTarget) * Double(s.targetBps) / Double(baseGrowth)).rounded()) : 0
            case .cash:
                ns.targetBps = cashTarget
            default:   // defensive, realDiversifier
                ns.targetBps = baseOther > 0 ? Int((Double(otherBudget) * Double(s.targetBps) / Double(baseOther)).rounded()) : 0
            }
            return ns
        }
        // Absorb per-sleeve rounding so BOTH invariants hold exactly: (a) growth
        // sums to growthTarget — so growth + alt beta stays strictly under the risk
        // ceiling — by folding its rounding into the largest growth sleeve; then
        // (b) the whole budget sums to sleeveBudget by folding the remaining
        // (cash/other) rounding into the largest NON-growth sleeve, which is
        // guaranteed non-zero whenever there is any non-growth budget.
        let growthResidual = growthTarget - derived.filter { $0.role == .growth }.reduce(0) { $0 + $1.targetBps }
        if growthResidual != 0, let gi = derived.indices.filter({ derived[$0].role == .growth })
            .max(by: { derived[$0].targetBps < derived[$1].targetBps }) {
            derived[gi].targetBps = max(0, derived[gi].targetBps + growthResidual)
        }
        let residual = sleeveBudget - derived.reduce(0) { $0 + $1.targetBps }
        if residual != 0, let ni = derived.indices.filter({ derived[$0].role != .growth })
            .max(by: { derived[$0].targetBps < derived[$1].targetBps }) {
            derived[ni].targetBps = max(0, derived[ni].targetBps + residual)
        }

        var p = base
        p.sleeves = derived
        return p
    }
}
