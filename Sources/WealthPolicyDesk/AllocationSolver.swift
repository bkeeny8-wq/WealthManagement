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
        let equitySleeves = base.sleeves.filter { $0.id != fiSleeveId }
        let baseEquity = equitySleeves.reduce(0) { $0 + $1.targetBps }
        guard v > 0, sleeveBudget > 0, baseEquity > 0 else { return base }

        // 1) Bond floor = a NEAR-TERM liquidity minimum — the rebalance reserve plus
        //    ~one year of net outflow — expressed as a share. NOT the full multi-year
        //    ladder (requiredLiquidUsd): for an underfunded near-retiree the ladder can
        //    exceed the whole sleeve budget and would crush equity to zero. The full
        //    ladder stays enforced as the separate hard liquidity_floor finding; here
        //    the equity/FI split is driven by risk and funded status, with FI never
        //    below this modest liquidity minimum.
        let fiFloorUsd = ladder.rebalanceReserveUsd + ladder.twelveMonthFloorUsd
        let fiFloor = max(0, min(sleeveBudget, (fiFloorUsd / v).bps))

        // 2) Equity ceiling = risk. bindingEquityBps is a TOTAL-portfolio equity
        //    cap, so charge the alt budget's own equity/credit beta against it —
        //    sleeve equity PLUS that alt beta must stay under the ceiling — then fit
        //    within the room the bond floor leaves.
        let altEquiv = altEquityEquivalentBps(base)
        let equityCeiling = max(0, min(equityCeilingBps - altEquiv, sleeveBudget - fiFloor))
        let equityFloor = min(equityCeiling, equityDeriskFloorBps)

        // 3) Funded-status glide: underfunded → ceiling, overfunded → floor.
        let span = max(1, fundedCeilBps - fundedFloorBps)
        let t = min(1.0, max(0.0, Double(fundedRatioBps - fundedFloorBps) / Double(span)))
        let equityTarget = Int((Double(equityCeiling) * (1 - t) + Double(equityFloor) * t).rounded())

        // 4) Distribute equity across the equity sleeves by their structural
        //    weights; FI absorbs the remainder so the sleeve budget is preserved.
        var assignedEquity = 0
        var derived: [Sleeve] = []
        for s in base.sleeves where s.id != fiSleeveId {
            var ns = s
            ns.targetBps = Int((Double(equityTarget) * Double(s.targetBps) / Double(baseEquity)).rounded())
            assignedEquity += ns.targetBps
            derived.append(ns)
        }
        if let fi = base.sleeves.first(where: { $0.id == fiSleeveId }) {
            var nfi = fi
            nfi.targetBps = max(0, sleeveBudget - assignedEquity)
            derived.append(nfi)
        }

        // Preserve the original sleeve order for a stable UI.
        let order = Dictionary(base.sleeves.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        derived.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }

        var p = base
        p.sleeves = derived
        return p
    }
}
