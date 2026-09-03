//  CapitalMarketRisk.swift
//  WealthPolicyDesk
//
//  The risk companion to the CME's returns: per-asset volatilities and a
//  correlation structure, so a portfolio's total volatility — and a modeled
//  drawdown — can be computed. Sleeves and alts map to a small set of risk
//  BUCKETS (a glass box: nine annual vols + a 9×9 correlation matrix, all dials
//  to VERIFY). σ_portfolio = √(wᵀ Σ w) over the buckets.
//
//  This is what lets the frontier be DRAWN. It never sets the strategic target —
//  the weights come from the forecast-free solver; this only prices their risk,
//  the way the CME prices their return.

import Foundation

/// A small set of risk buckets. Every sleeve and alt maps to one.
public enum MarketRiskBucket: String, CaseIterable, Sendable, Hashable {
    case usEq, intlEq, emEq, realEstate, govtBond, credit, commodity, cash, alt
    /// Annual volatility (bps). A dial — verify.
    public var volBps: Bps {
        switch self {
        case .usEq: return 1600
        case .intlEq: return 1700
        case .emEq: return 2300
        case .realEstate: return 1900
        case .govtBond: return 550
        case .credit: return 1000
        case .commodity: return 1600
        case .cash: return 100
        case .alt: return 1000
        }
    }
    var idx: Int { MarketRiskBucket.allCases.firstIndex(of: self)! }
}

public extension Engine {

    /// Correlation matrix over the buckets, in `MarketRiskBucket.allCases` order:
    /// usEq, intlEq, emEq, realEstate, govtBond, credit, commodity, cash, alt.
    static let bucketCorrelation: [[Double]] = [
        [ 1.00, 0.85, 0.72, 0.65, -0.10, 0.60, 0.25, 0.00, 0.45],
        [ 0.85, 1.00, 0.78, 0.60, -0.05, 0.58, 0.30, 0.00, 0.45],
        [ 0.72, 0.78, 1.00, 0.55, -0.05, 0.62, 0.40, 0.00, 0.45],
        [ 0.65, 0.60, 0.55, 1.00,  0.15, 0.55, 0.25, 0.00, 0.45],
        [-0.10,-0.05,-0.05, 0.15,  1.00, 0.35,-0.10, 0.15, 0.10],
        [ 0.60, 0.58, 0.62, 0.55,  0.35, 1.00, 0.30, 0.05, 0.45],
        [ 0.25, 0.30, 0.40, 0.25, -0.10, 0.30, 1.00, 0.00, 0.35],
        [ 0.00, 0.00, 0.00, 0.00,  0.15, 0.05, 0.00, 1.00, 0.05],
        [ 0.45, 0.45, 0.45, 0.45,  0.10, 0.45, 0.35, 0.05, 1.00],
    ]

    static func riskBucket(sleeveId: String) -> MarketRiskBucket {
        switch sleeveId {
        case "us_large_core", "us_factor_tilt", "us_sector_tilt", "us_mid_small": return .usEq
        case "intl_developed", "intl_small": return .intlEq
        case "emerging": return .emEq
        case "real_assets": return .realEstate
        case "fixed_income_liquid", "tips": return .govtBond
        case "credit_hy", "em_debt": return .credit
        case "commodities": return .commodity
        case "cash": return .cash
        default: return .usEq   // unclassified holdings priced as US equity (see the CME reconciliation)
        }
    }

    static func riskBucket(alt: AltFunction) -> MarketRiskBucket { .alt }

    /// Portfolio volatility (bps): collapse sleeve + alt weights into bucket weights,
    /// normalize to 1, then σ = √(Σᵢ Σⱼ wᵢ wⱼ σᵢ σⱼ ρᵢⱼ).
    static func portfolioVolBps(sleeves: [(id: String, bps: Bps)], alts: [(fn: AltFunction, bps: Bps)]) -> Bps {
        var w = [Double](repeating: 0, count: MarketRiskBucket.allCases.count)
        var total = 0.0
        for s in sleeves where s.bps > 0 { w[riskBucket(sleeveId: s.id).idx] += Double(s.bps); total += Double(s.bps) }
        for a in alts where a.bps > 0 { w[riskBucket(alt: a.fn).idx] += Double(a.bps); total += Double(a.bps) }
        guard total > 0 else { return 0 }
        for i in w.indices { w[i] /= total }
        let vol = MarketRiskBucket.allCases.map { Double($0.volBps) }
        var variance = 0.0
        for i in w.indices {
            for j in w.indices {
                variance += w[i] * w[j] * vol[i] * vol[j] * bucketCorrelation[i][j]
            }
        }
        return Int(Double(max(0, variance)).squareRoot().rounded())
    }

    /// A modeled severe-year drawdown from volatility: a crash is roughly 3σ, which
    /// puts a ~16% equity vol near the ~50% drawdown the old flat rule assumed — but
    /// now diversification (bonds cutting σ) earns a lower drawdown honestly.
    static func modeledDrawdownBps(volBps: Bps) -> Bps { Int((Double(volBps) * 3.0).rounded()) }

    // MARK: - Frontier-derived tolerance mapping

    /// The modeled drawdown of the solver's own portfolio at each equity ceiling —
    /// the risk profile of the app's real menu for this household. Sweeps the
    /// forecast-free solver (alts a fixed budget, bonds the residual) and prices the
    /// risk of each rung. Uses only volatilities/correlations — never return forecasts.
    ///
    /// The sweep deliberately runs at the funded FLOOR so the funded-status glide is
    /// neutral (t = 0) and each rung genuinely holds its ceiling. Sweeping at the
    /// household's actual funded ratio conflated two separate questions: an overfunded
    /// household glides to the 30% derisk floor at EVERY ceiling, which flattened the
    /// curve, so "the highest ceiling within the stated drawdown" returned 95% for any
    /// overfunded client no matter how little loss they said they could take. How much
    /// of the allowed ceiling to actually use is the glide's job, applied afterwards.
    static func drawdownByCeiling(_ h: Household, ladder: LadderPlan) -> [(ceilingBps: Bps, drawdownBps: Bps)] {
        var out: [(ceilingBps: Bps, drawdownBps: Bps)] = []
        var e = 1500
        while e <= 9500 {
            let pol = resolveTargets(h, base: Seed.legacyPolicy, fundedRatioBps: fundedFloorBps, equityCeilingBps: e, ladder: ladder)
            let vol = portfolioVolBps(sleeves: pol.sleeves.map { (id: $0.id, bps: $0.targetBps) },
                                      alts: pol.altBudgets.map { (fn: $0.fn, bps: $0.targetBps) })
            out.append((e, modeledDrawdownBps(volBps: vol)))
            e += 250
        }
        return out
    }

    /// The highest equity ceiling whose modeled drawdown stays within the stated
    /// limit — the frontier-derived replacement for the flat 2× rule. It reads the
    /// drawdown off the diversified portfolio the solver would actually build, so a
    /// mix whose "defensive" half carries credit/commodity/alt risk earns a lower
    /// ceiling than the naive equity-only rule. Falls back to the most-defensive
    /// ceiling when even that exceeds the limit (nothing lower can be built).
    static func toleranceEquityBps(fromCurve curve: [(ceilingBps: Bps, drawdownBps: Bps)], maxDrawdownBps: Bps) -> Bps {
        curve.filter { $0.drawdownBps <= maxDrawdownBps }.map { $0.ceilingBps }.max() ?? (curve.first?.ceilingBps ?? 3000)
    }

    static func toleranceEquityBps(_ h: Household, ladder: LadderPlan, maxDrawdownBps: Bps) -> Bps {
        toleranceEquityBps(fromCurve: drawdownByCeiling(h, ladder: ladder), maxDrawdownBps: maxDrawdownBps)
    }
}
