//  RiskScale.swift
//  WealthPolicyDesk
//
//  Client risk-tolerance scaling. The allocation is a function of how much
//  drawdown the household can stomach, so the SAME solver, run across a spectrum
//  of tolerances, IS a set of model portfolios (Defensive → Aggressive). Capacity
//  caps every rung — you cannot dial past what the situation affords. Forecast-free.

import Foundation

/// One rung of the risk spectrum: a stated drawdown tolerance and the model
/// allocation the solver derives at it (funded status + capacity held fixed).
public struct RiskModelPortfolio: Identifiable, Sendable, Hashable {
    public var label: String
    public var maxDrawdownBps: Bps
    public var toleranceEquityBps: Bps    // what the tolerance alone would allow
    public var bindingEquityBps: Bps      // after the capacity cap
    public var capacityBound: Bool        // capacity, not tolerance, is the limit here
    public var growthBps: Bps
    public var defensiveBps: Bps
    public var realDiversifierBps: Bps
    public var cashBps: Bps
    public var altBps: Bps
    public var isClientLevel: Bool
    public var id: String { label }
}

public extension Engine {
    /// Five model portfolios across the risk spectrum, each the solver's output at
    /// that drawdown tolerance, with the household's own rung flagged.
    static func riskLadder(_ h: Household, fundedRatioBps: Bps, ladder: LadderPlan) -> [RiskModelPortfolio] {
        let cap = riskCapacityBps(h, fundedRatioBps: fundedRatioBps)
        // The drawdown of the solver's portfolio at each equity ceiling — computed
        // once and reused, so every rung reads its tolerance off the same frontier.
        let ddCurve = drawdownByCeiling(h, ladder: ladder)
        let altTotal = Seed.legacyPolicy.altBudgets.reduce(0) { $0 + $1.targetBps }
        let base: [(String, Bps)] = [("Defensive", 1500), ("Conservative", 2000), ("Moderate", 3000), ("Growth", 4000), ("Aggressive", 5000)]
        let clientDd = h.statedToleranceMaxDrawdownBps
        // The five standard rungs, plus the client's OWN tolerance as its own rung
        // (so it shows their real allocation, not the nearest model's).
        var rungs: [(name: String, dd: Bps, isClient: Bool)] = base.map { ($0.0, $0.1, clientDd > 0 && $0.1 == clientDd) }
        if clientDd > 0, !base.contains(where: { $0.1 == clientDd }) {
            rungs.append((name: "Your plan", dd: clientDd, isClient: true))
        }
        rungs.sort { $0.dd < $1.dd }
        return rungs.map { rung in
            let tolEq = toleranceEquityBps(fromCurve: ddCurve, maxDrawdownBps: rung.dd)
            let binding = min(cap, tolEq)
            let pol = resolveTargets(h, base: Seed.legacyPolicy, fundedRatioBps: fundedRatioBps, equityCeilingBps: binding, ladder: ladder)
            func sum(_ role: AssetRole) -> Bps { pol.sleeves.filter { $0.role == role }.reduce(0) { $0 + $1.targetBps } }
            return RiskModelPortfolio(
                label: rung.name, maxDrawdownBps: rung.dd, toleranceEquityBps: tolEq, bindingEquityBps: binding,
                capacityBound: cap <= tolEq, growthBps: sum(.growth), defensiveBps: sum(.defensive),
                realDiversifierBps: sum(.realDiversifier), cashBps: sum(.cash), altBps: altTotal,
                isClientLevel: rung.isClient)
        }
    }
}
