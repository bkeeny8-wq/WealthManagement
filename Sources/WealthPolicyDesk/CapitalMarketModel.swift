//  CapitalMarketModel.swift
//  WealthPolicyDesk
//
//  The Capital Market Expectations (CME) engine — the second half of the CME/macro
//  track. It answers: what is each asset class priced to DELIVER, in real terms,
//  over ~10 years? Built block-by-block (a glass box, not a black box):
//    • Equities — Grinold-Kroner: dividend + net buyback + real earnings growth +
//      valuation reversion (partial mean-reversion of CAPE toward a fair-value dial).
//    • Bonds — the starting real yield + credit spread − expected loss (yield is the
//      single best predictor of a bond's long-run return).
//    • Real assets / commodities / cash — their own small blocks.
//  Every input is either an OBSERVABLE read straight off the macro board (CAPE, real
//  rates, breakevens, OAS) or a small, labeled forecast DIAL. The macro inning then
//  applies a modest, capped regime overlay (early lifts / late trims equity + credit).
//
//  DOCTRINE FIREWALL: the CME never sets the forecast-free strategic target
//  (resolveTargets never reads it). It exists to RECONCILE — to compare what the
//  market is priced to deliver against what the plan REQUIRES. A required return the
//  market isn't priced to fund is closed by saving/spending/deferring, not by
//  reaching for risk the market isn't paying for. Values are a dated snapshot to
//  VERIFY; the app stays offline.

import Foundation

/// One labeled component of a building-block expected-return stack (in bps).
public struct CMEBlock: Sendable, Hashable, Identifiable {
    public var label: String
    public var bps: Bps
    public var id: String { label }
    public init(_ label: String, _ bps: Bps) { self.label = label; self.bps = bps }
}

public enum CMEKind: String, Sendable, Hashable, CaseIterable {
    case equity = "Equity", bond = "Fixed income", real = "Real assets", cash = "Cash"
}

/// The expected real return of one asset class, with its building blocks shown.
public struct AssetClassCME: Identifiable, Sendable, Hashable {
    public var sleeveId: String
    public var label: String
    public var kind: CMEKind
    public var realReturnBps: Bps
    public var blocks: [CMEBlock]
    public var note: String
    public var id: String { sleeveId }
}

/// The whole firm-wide capital-market picture — household-independent, so it lives
/// on the Econ tab. The reconciliation against a plan's required return is per-client.
public struct CapitalMarketSet: Sendable {
    public var classes: [AssetClassCME]
    public var altRealBps: [AltFunction: Bps]
    public var phase: CyclePhase
    public var cycleScore: Int
    public var equityRegimeBps: Bps
    public var creditRegimeBps: Bps
    public var expectedInflationBps: Bps
    public var asOf: IsoDate
    public var source: String
    public func realBps(sleeveId: String) -> Bps? { classes.first { $0.sleeveId == sleeveId }?.realReturnBps }
}

/// A portfolio's expected real return = its weights × the per-class CMEs.
public struct PortfolioExpectation: Sendable, Hashable {
    public struct Contribution: Sendable, Hashable, Identifiable {
        public var label: String
        public var weightBps: Bps
        public var realBps: Bps
        public var contribBps: Bps
        public var id: String { label }
    }
    public var label: String
    public var expectedRealBps: Bps
    public var rows: [Contribution]
}

/// Expected (what the market is priced to deliver) vs required (what the plan needs).
public struct CMEReconciliation: Sendable {
    public enum Verdict: String, Sendable { case cushion = "Cushion", funded = "Roughly funded", stretch = "Stretch" }
    public var requiredRealBps: Bps            // after-tax hurdle — the gross return that also funds the plan's taxes
    public var requiredFlexBps: Bps            // the same hurdle after deferring / scaling the goal
    public var target: PortfolioExpectation
    public var current: PortfolioExpectation
    public var cme: CapitalMarketSet
    /// Share of current holdings not mapped to a sleeve/alt (e.g. a concentrated
    /// stock) that was priced by default as US-large equity — disclosed, not dropped.
    public var unpricedResidualBps: Bps = 0
    public var gapTargetBps: Bps { target.expectedRealBps - requiredRealBps }
    public var gapCurrentBps: Bps { current.expectedRealBps - requiredRealBps }
    public static func verdict(_ gapBps: Bps) -> Verdict { gapBps >= 50 ? .cushion : (gapBps <= -50 ? .stretch : .funded) }
}

public extension Engine {

    // MARK: the firm-wide CME

    /// Build the capital-market expectations from the observable macro board plus a
    /// small labeled dial set, regime-adjusted by the inning.
    static func capitalMarketExpectations(_ indicators: [MacroIndicator], regime: MacroRegime,
                                          asOf: IsoDate = "2026-08-15",
                                          source: String = "FRED · Shiller · market data (verify)") -> CapitalMarketSet {
        func obs(_ name: String, _ fallback: Double) -> Double { indicators.first { $0.name == name }?.value ?? fallback }
        let capeUS   = obs("Shiller CAPE", 42.4)
        let real10   = Int((obs("10y real rate", 2.0) * 100).rounded())   // pct → bps
        let hyOAS    = Int(obs("HY OAS", 271).rounded())                  // already bps
        let emSov    = Int(obs("EM sovereign spread", 335).rounded())     // already bps
        let inflBps  = Int((obs("10y breakeven", 2.3) * 100).rounded())
        let cashReal = Int((Engine.safeRealRate * 10000).rounded())       // 1.5% → 150

        // Regime overlay: continuous and capped. cycleScore 50 (mid) → 0; 100 (late)
        // → trim; 0 (early) → lift. Kept small on purpose — CAPE already carries the
        // valuation signal, so this only adds the cycle-position (drawdown) tilt.
        let score = regime.cycleScore
        let eqRegime = Int((-Double(score - 50) / 50.0 * 75.0).rounded())   // ±75 bp
        let crRegime = Int((-Double(score - 50) / 50.0 * 40.0).rounded())   // ±40 bp

        // Grinold-Kroner equity: real = div + net buyback + real growth + ΔPE + regime.
        // ΔPE = partial (φ) annualized log-reversion of CAPE toward a fair-value dial.
        func equity(_ id: String, _ label: String, div: Int, buyback: Int, growth: Int,
                    cape: Double, fairCape: Double, regime: Bool = true) -> AssetClassCME {
            let phi = 0.5, horizon = 10.0
            let valBps = Int((phi * (1.0 / horizon) * log(fairCape / cape) * 10000).rounded())
            let reg = regime ? eqRegime : 0
            let total = div + buyback + growth + valBps + reg
            var blocks = [CMEBlock("Div", div), CMEBlock("Buyback", buyback),
                          CMEBlock("Growth", growth), CMEBlock("Valuation", valBps)]
            if regime { blocks.append(CMEBlock("Regime", reg)) }
            let capeTxt = String(format: "%.0f", cape), fairTxt = String(format: "%.0f", fairCape)
            return AssetClassCME(sleeveId: id, label: label, kind: .equity, realReturnBps: total, blocks: blocks,
                note: "CAPE \(capeTxt) reverting toward a \(fairTxt) fair value; income + real growth carry the rest.")
        }

        func bond(_ id: String, _ label: String, realYield: Int, spread: Int, loss: Int,
                  credit: Bool, note: String) -> AssetClassCME {
            let reg = credit ? crRegime : 0
            let total = realYield + spread - loss + reg
            var blocks = [CMEBlock("Real yield", realYield)]
            if spread != 0 { blocks.append(CMEBlock("Spread", spread)) }
            if loss   != 0 { blocks.append(CMEBlock("Loss", -loss)) }
            if credit      { blocks.append(CMEBlock("Regime", reg)) }
            return AssetClassCME(sleeveId: id, label: label, kind: .bond, realReturnBps: total, blocks: blocks, note: note)
        }

        var classes: [AssetClassCME] = [
            // Equities (Grinold-Kroner). Regional CAPEs and payout/growth are dials.
            equity("us_large_core",  "US Large Core",           div: 130, buyback: 150, growth: 160, cape: capeUS, fairCape: 27),
            equity("us_factor_tilt", "US Factor Tilt",          div: 170, buyback: 130, growth: 160, cape: 34,     fairCape: 24),
            equity("us_sector_tilt", "SPDR Sector Tilt",        div: 130, buyback: 150, growth: 160, cape: capeUS, fairCape: 27),
            equity("us_mid_small",   "US Mid/Small",            div: 140, buyback: 100, growth: 180, cape: 28,     fairCape: 22),
            equity("intl_developed", "International Developed",  div: 320, buyback:  50, growth: 130, cape: 17,     fairCape: 18),
            equity("intl_small",     "Intl Small-Cap",          div: 280, buyback:  30, growth: 160, cape: 15,     fairCape: 17),
            equity("emerging",       "Emerging Markets",        div: 300, buyback: -50, growth: 300, cape: 14,     fairCape: 15),
        ]
        // REIT: equity-like but priced off yield + growth, not CAPE.
        classes.append(AssetClassCME(sleeveId: "real_assets", label: "Real Assets / REIT", kind: .equity,
            realReturnBps: 380 + 100 - 30 + eqRegime,
            blocks: [CMEBlock("Div", 380), CMEBlock("Growth", 100), CMEBlock("Valuation", -30), CMEBlock("Regime", eqRegime)],
            note: "A ~3.8% real distribution yield + modest real income growth, lightly de-rated."))

        classes += [
            bond("fixed_income_liquid", "Core Bonds", realYield: real10, spread: 40, loss: 5, credit: false,
                 note: "Starting real yield (the best return predictor) + a small aggregate spread."),
            bond("tips", "TIPS / Inflation-Linked", realYield: real10, spread: 0, loss: 0, credit: false,
                 note: "The TIPS real yield IS the expected real return — inflation is passed through."),
            bond("credit_hy", "Credit / High-Yield", realYield: real10, spread: hyOAS, loss: 200, credit: true,
                 note: "Real yield + HY spread − expected default loss; the macro-regime overlay trims credit modestly late in the cycle."),
            bond("em_debt", "EM Debt", realYield: real10, spread: emSov, loss: 100, credit: true,
                 note: "Real yield + EM sovereign spread − expected loss."),
        ]
        classes.append(AssetClassCME(sleeveId: "commodities", label: "Commodities / Gold", kind: .real,
            realReturnBps: 150 - 50,
            blocks: [CMEBlock("Collateral", 150), CMEBlock("Roll/spot", -50)],
            note: "Held for the inflation-shock hedge, not the level of return — real carry is thin."))
        classes.append(AssetClassCME(sleeveId: "cash", label: "Cash / Short Reserve", kind: .cash,
            realReturnBps: cashReal,
            blocks: [CMEBlock("Real rate", cashReal)],
            note: "The short real rate — the zero-duration liquidity floor."))

        // Alternatives, by function: an equity-equivalent beta on US large + a premium.
        let usLarge = classes.first { $0.sleeveId == "us_large_core" }?.realReturnBps ?? 214
        func beta(_ b: Double, premium: Int) -> Bps { Int((b * Double(usLarge) + (1 - b) * Double(cashReal)).rounded()) + premium }
        let altReal: [AltFunction: Bps] = [
            .illiquidityPremium: beta(0.70, premium: 150),   // PE / private credit, net of fees
            .shapedPayoff:       beta(0.50, premium: 0),     // buffers / notes — dampened equity
            .convexity:          100,                         // trend / commodities — return is not the point
        ]

        return CapitalMarketSet(classes: classes, altRealBps: altReal, phase: regime.phase, cycleScore: score,
                                equityRegimeBps: eqRegime, creditRegimeBps: crRegime, expectedInflationBps: inflBps,
                                asOf: asOf, source: source)
    }

    // MARK: blend a portfolio through the CME

    /// A portfolio's expected real return = Σ weight × per-class CME. Weights are
    /// normalized so sleeves + alts sum to 100%.
    static func portfolioExpectation(_ label: String,
                                     sleeves: [(id: String, label: String, bps: Bps)],
                                     alts: [(fn: AltFunction, bps: Bps)],
                                     cme: CapitalMarketSet) -> PortfolioExpectation {
        let total = sleeves.reduce(0) { $0 + max(0, $1.bps) } + alts.reduce(0) { $0 + max(0, $1.bps) }
        guard total > 0 else { return PortfolioExpectation(label: label, expectedRealBps: 0, rows: []) }
        var rows: [PortfolioExpectation.Contribution] = []
        var acc = 0.0
        for s in sleeves where s.bps > 0 {
            let r = cme.realBps(sleeveId: s.id) ?? 0
            let w = Double(s.bps) / Double(total)
            let contrib = w * Double(r)
            acc += contrib
            rows.append(.init(label: s.label, weightBps: Int((w * 10000).rounded()), realBps: r, contribBps: Int(contrib.rounded())))
        }
        for a in alts where a.bps > 0 {
            let r = cme.altRealBps[a.fn] ?? 0
            let w = Double(a.bps) / Double(total)
            let contrib = w * Double(r)
            acc += contrib
            rows.append(.init(label: "\(a.fn.label) (alt)", weightBps: Int((w * 10000).rounded()), realBps: r, contribBps: Int(contrib.rounded())))
        }
        return PortfolioExpectation(label: label, expectedRealBps: Int(acc.rounded()),
                                    rows: rows.sorted { $0.contribBps > $1.contribBps })
    }

    /// Reconcile both portfolios (strategic target and current holdings) against the
    /// plan's required real return.
    static func cmeReconciliation(_ eval: Evaluation, cme: CapitalMarketSet) -> CMEReconciliation {
        // Price the forecast-free STRATEGIC target (pre-tilt), so the "strategic
        // target" line stays about the policy, not the tactical overlay.
        let targetSleeves  = eval.allocation.map { (id: $0.sleeveId, label: $0.label, bps: $0.strategicTargetBps) }
        var currentSleeves = eval.allocation.map { (id: $0.sleeveId, label: $0.label, bps: $0.currentBps) }
        let targetAlts  = eval.altSizing.map { (fn: $0.fn, bps: $0.targetBps) }
        let currentAlts = eval.altSizing.map { (fn: $0.fn, bps: $0.currentBps) }
        // Any held dollar not mapped to a sleeve or alt — a concentrated single stock,
        // say — would otherwise vanish from the numerator AND the denominator, silently
        // pricing the current column over <100% of the book while the target covers all
        // of it (an apples-to-oranges basis). Fold that residual back in, priced as
        // US-large equity (what an unclassified concentrated lot almost always is), so
        // both columns share one 100% basis. The share is disclosed on the card.
        let recognized = currentSleeves.reduce(0) { $0 + max(0, $1.bps) } + currentAlts.reduce(0) { $0 + max(0, $1.bps) }
        let residual = 10000 - recognized
        if residual > 25 {
            currentSleeves.append((id: "us_large_core", label: "Unclassified (held equity)", bps: residual))
        }
        let target  = portfolioExpectation("Strategic target",  sleeves: targetSleeves,  alts: targetAlts,  cme: cme)
        let current = portfolioExpectation("Current holdings",   sleeves: currentSleeves, alts: currentAlts, cme: cme)
        return CMEReconciliation(requiredRealBps: eval.requiredReturn.requiredRealReturnBps,
                                 requiredFlexBps: eval.requiredReturn.requiredRealReturnWithFlexibilityBps,
                                 target: target, current: current, cme: cme,
                                 unpricedResidualBps: residual > 25 ? residual : 0)
    }
}
