//  FrontierModel.swift
//  WealthPolicyDesk
//
//  The efficient frontier — the capstone that ties the pieces together. We do NOT
//  mean-variance OPTIMIZE the weights (that needs return forecasts and would break
//  the forecast-free doctrine). Instead we sweep the app's OWN solver across the
//  equity spectrum — the real menu of portfolios it would build for this household,
//  alts sized as a fixed function budget, bonds/cash the residual — and PRICE each:
//  volatility from the risk model, expected real return from the CME. That locus is
//  the curve.
//
//  On it we place the forecast-free things the client brings: the required return
//  (a horizontal line — what the plan needs), the tolerable-drawdown volatility and
//  the capacity volatility (vertical lines — what they can stomach / afford), and
//  the client's own target and current portfolios. The teaching question is one
//  glance: does the curve, inside the tolerable-σ band, reach the required line?

import Foundation

public struct FrontierPoint: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable { case curve, target, current }
    public var equityBps: Bps
    public var volBps: Bps
    public var expRealBps: Bps
    public var drawdownBps: Bps
    public var kind: Kind
    public var id: String { "\(kind.rawValue)-\(equityBps)-\(volBps)" }
}

public struct FrontierChart: Sendable {
    public var curve: [FrontierPoint]
    public var target: FrontierPoint
    public var current: FrontierPoint
    public var requiredRealBps: Bps
    public var toleranceStated: Bool
    public var toleranceDrawdownBps: Bps
    public var toleranceVolBps: Bps            // vertical line: σ a tolerable drawdown allows
    public var minDrawdownBps: Bps             // the most defensive portfolio's modeled drawdown (the floor)
    public var capacityEquityBps: Bps
    public var capacityVolBps: Bps             // vertical line: σ at the capacity ceiling
    public var hasTolerableBand: Bool          // is any swept portfolio inside the tolerable drawdown?
    public var frontierToleranceEquityBps: Bps? // highest equity whose modeled drawdown ≤ tolerance (nil if none)
    public var flatToleranceEquityBps: Bps     // the old 2× rule, for contrast
    public var reachableWithinToleranceBps: Bps? // best expected real return inside the band (nil if none)
    public var meetsRequiredWithinTolerance: Bool
    public var targetExceedsToleranceBps: Bps  // how far the solved target's drawdown exceeds tolerance (0 if within)
}

public extension Engine {

    static func frontier(_ eval: Evaluation, cme: CapitalMarketSet) -> FrontierChart {
        let base = Seed.legacyPolicy
        let growthIds = Set(base.sleeves.filter { $0.role == .growth }.map { $0.id })
        let fundedRatio = eval.balanceSheet.fundedRatioBps
        let ladder = eval.ladder
        let h = eval.household

        func price(sleeves: [(id: String, label: String, bps: Bps)], alts: [(fn: AltFunction, bps: Bps)], kind: FrontierPoint.Kind) -> FrontierPoint {
            let vol = portfolioVolBps(sleeves: sleeves.map { (id: $0.id, bps: $0.bps) }, alts: alts)
            let er = portfolioExpectation("", sleeves: sleeves, alts: alts, cme: cme).expectedRealBps
            let tot = sleeves.reduce(0) { $0 + max(0, $1.bps) } + alts.reduce(0) { $0 + max(0, $1.bps) }
            let gW = sleeves.filter { growthIds.contains($0.id) }.reduce(0) { $0 + max(0, $1.bps) }
            let eq = tot > 0 ? Int(Double(gW) / Double(tot) * 10000) : 0
            return FrontierPoint(equityBps: eq, volBps: vol, expRealBps: er, drawdownBps: modeledDrawdownBps(volBps: vol), kind: kind)
        }

        // The real menu: the solver's own portfolio at each equity ceiling (alts a
        // fixed budget, bonds the residual — no ballooning).
        func solved(equityCeiling e: Int, kind: FrontierPoint.Kind) -> FrontierPoint {
            let pol = resolveTargets(h, base: base, fundedRatioBps: fundedRatio, equityCeilingBps: e, ladder: ladder)
            return price(sleeves: pol.sleeves.map { (id: $0.id, label: $0.label, bps: $0.targetBps) },
                         alts: pol.altBudgets.map { (fn: $0.fn, bps: $0.targetBps) }, kind: kind)
        }

        var curve: [FrontierPoint] = []
        var e = 1500
        while e <= 9000 { curve.append(solved(equityCeiling: e, kind: .curve)); e += 500 }
        curve.sort { $0.volBps < $1.volBps }

        // The client's own portfolios from the solved allocation.
        func clientPoint(target: Bool) -> FrontierPoint {
            var sleeves = eval.allocation.map { (id: $0.sleeveId, label: $0.label, bps: target ? $0.strategicTargetBps : $0.currentBps) }
            let alts = eval.altSizing.map { (fn: $0.fn, bps: target ? $0.targetBps : $0.currentBps) }
            if !target {   // fold an unclassified concentrated lot in, priced as equity (as the CME reconciliation does)
                let recog = sleeves.reduce(0) { $0 + max(0, $1.bps) } + alts.reduce(0) { $0 + max(0, $1.bps) }
                let residual = 10000 - recog
                if residual > 25 { sleeves.append((id: "us_large_core", label: "Unclassified", bps: residual)) }
            }
            return price(sleeves: sleeves, alts: alts, kind: target ? .target : .current)
        }
        let target = clientPoint(target: true)
        let current = clientPoint(target: false)

        // Tolerance is only real if the household stated one (mirror Engine.riskProfile,
        // which treats 0 as "not stated" — never fabricate a band from a floored default).
        let stated = h.statedToleranceMaxDrawdownBps
        let toleranceStated = stated > 0
        let toleranceVol = toleranceStated ? modeledVolFromDrawdown(stated) : 0
        let capEquity = eval.riskProfile?.capacityEquityBps ?? 6000
        let capVol = solved(equityCeiling: min(9000, max(1500, capEquity)), kind: .curve).volBps
        let minDrawdown = curve.map { $0.drawdownBps }.min() ?? 0

        // The tolerable band: swept portfolios whose modeled drawdown fits the limit.
        // If the limit is below the whole menu's floor, the band is EMPTY — say so,
        // never substitute an out-of-band portfolio.
        let withinTol = toleranceStated ? curve.filter { $0.drawdownBps <= stated } : []
        let hasBand = !withinTol.isEmpty
        let reachable: Bps? = hasBand ? withinTol.map { $0.expRealBps }.max() : nil
        // Report the equity CEILING the solver binds to (matches the Balance Sheet /
        // Risk Scale), not the growth-only share of the curve point — the two differ
        // by the alt equity-beta that also counts against the budget.
        let frontierTolEquity: Bps? = hasBand ? (eval.riskProfile?.toleranceImpliedEquityBps ?? withinTol.map { $0.equityBps }.max()) : nil
        let required = eval.requiredReturn.requiredRealReturnBps

        return FrontierChart(
            curve: curve, target: target, current: current, requiredRealBps: required,
            toleranceStated: toleranceStated, toleranceDrawdownBps: stated, toleranceVolBps: toleranceVol,
            minDrawdownBps: minDrawdown, capacityEquityBps: capEquity, capacityVolBps: capVol,
            hasTolerableBand: hasBand, frontierToleranceEquityBps: frontierTolEquity,
            flatToleranceEquityBps: min(10000, stated * 2), reachableWithinToleranceBps: reachable,
            meetsRequiredWithinTolerance: hasBand && (reachable ?? 0) >= required,
            targetExceedsToleranceBps: toleranceStated ? max(0, target.drawdownBps - stated) : 0
        )
    }

    /// Invert the 3σ drawdown model: the volatility a tolerable drawdown permits.
    static func modeledVolFromDrawdown(_ drawdownBps: Bps) -> Bps { Int((Double(drawdownBps) / 3.0).rounded()) }
}
