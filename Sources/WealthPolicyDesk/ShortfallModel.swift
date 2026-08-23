//  ShortfallModel.swift
//  WealthPolicyDesk
//
//  Risk, expressed as SHORTFALL PROBABILITY — the odds the plan fails to earn what
//  it needs, not just how far a single bad year could drop. The required real return
//  is, by construction, the return that exactly funds the liabilities; earn less over
//  the horizon and the plan is underfunded. So:
//
//      P(shortfall) = P(annualized real return < required)
//                   = Φ( (required − expected) / (σ / √T) )
//
//  with the expected real return μ from the CME (a labeled, QUARANTINED forecast) and
//  σ the portfolio volatility from the risk model. Over a T-year horizon the average
//  annualized return has standard deviation σ/√T (i.i.d. time-diversification). This is
//  an analytic, glass-box normal model — deterministic (it reproduces; no Monte-Carlo
//  RNG, which the engine's purity doctrine forbids) — and it is the probabilistic
//  COMPLEMENT to the Resilience tab's deterministic sequence stresses.
//
//  DOCTRINE: this lives in the same quarantined-forecast zone as the frontier's CMA
//  overlay. It reconciles; it NEVER feeds resolveTargets. The forecast-free strategic
//  target is untouched.
//
//  BASIS: `required` is the after-tax real hurdle; `expected` (CME) is now NET of a
//  labeled friction dial (fund fees + annual investment taxes, Engine.cmeFrictionDragBps),
//  so the two sit on the same basis and the probability is honest rather than optimistic.
//  Sequence risk is deliberately OUT of this i.i.d. model — the Resilience tab's
//  path-dependent stresses are its complement, so the two are not double-counted.

import Foundation

public enum ShortfallBand: String, Sendable, Hashable {
    case low, moderate, elevated, high
    public var label: String {
        switch self {
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .elevated: return "Elevated"
        case .high: return "High"
        }
    }
}

public struct ShortfallEstimate: Sendable, Hashable {
    public var requiredRealBps: Bps
    public var expectedRealBps: Bps          // target portfolio, from the CME — NET of friction
    public var frictionDragBps: Bps = 0      // fund fees + annual tax drag netted off the gross CME
    public var volBps: Bps                   // target portfolio 1yr σ, from the risk model
    public var horizonYears: Int
    public var annualizedSigmaBps: Bps       // σ/√T — the spread of the average annualized return
    public var marginBps: Bps                // expected − required (the median cushion, signed)
    public var zScore: Double
    public var shortfallProbBps: Bps         // Φ(z), the headline — target portfolio
    public var currentShortfallProbBps: Bps  // same, for the current holdings (contrast)
    public var currentExpectedRealBps: Bps
    public var band: ShortfallBand
    public var asOf: IsoDate
}

public extension Engine {

    /// The plan's shortfall probability on the target portfolio (and, for contrast, on
    /// current holdings), from the CME expected return + the risk-model volatility.
    static func shortfallEstimate(_ eval: Evaluation, cme: CapitalMarketSet) -> ShortfallEstimate {
        // Price a portfolio's (σ, expected real) exactly as the frontier's client points do.
        func priced(target: Bool) -> (vol: Bps, mu: Bps) {
            var sleeves = eval.allocation.map { (id: $0.sleeveId, label: $0.label, bps: target ? $0.strategicTargetBps : $0.currentBps) }
            let alts = eval.altSizing.map { (fn: $0.fn, bps: target ? $0.targetBps : $0.currentBps) }
            if !target {   // fold an unclassified concentrated lot in as equity (as the frontier/CME do)
                let recog = sleeves.reduce(0) { $0 + max(0, $1.bps) } + alts.reduce(0) { $0 + max(0, $1.bps) }
                let residual = 10000 - recog
                if residual > 25 { sleeves.append((id: "us_large_core", label: "Unclassified", bps: residual)) }
            }
            let vol = portfolioVolBps(sleeves: sleeves.map { (id: $0.id, bps: $0.bps) }, alts: alts)
            let mu = portfolioExpectation("", sleeves: sleeves, alts: alts, cme: cme).expectedRealBps
            return (vol, mu)
        }

        let friction = Engine.cmeFrictionDragBps
        let (tVol, tMuGross) = priced(target: true)
        let (cVol, cMuGross) = priced(target: false)
        // Net the GROSS CME expected by portfolio friction (fund fees + annual tax drag) so
        // it's on the same basis as the AFTER-TAX required — the probability is then honest,
        // not optimistic. (Sequence risk stays deliberately out: this i.i.d. model is the
        // probabilistic complement to the Resilience tab's path-dependent stresses.)
        let tMu = tMuGross - friction, cMu = cMuGross - friction
        let required = eval.requiredReturn.requiredRealReturnBps
        let horizon = max(1, eval.household.goals.compactMap { $0.horizonYears }.max() ?? 30)
        let sqrtT = Double(horizon).squareRoot()

        // Φ( (required − μ) / (σ/√T) ). A degenerate σ collapses to a step at the mean.
        func probBps(vol: Bps, mu: Bps) -> (annSigma: Bps, z: Double, prob: Bps) {
            let sigmaAnn = Double(vol) / sqrtT
            let z = sigmaAnn > 0 ? (Double(required) - Double(mu)) / sigmaAnn : (required > mu ? 8.0 : -8.0)
            return (Int(sigmaAnn.rounded()), z, Int((normalCDF(z) * 10000).rounded()))
        }
        let t = probBps(vol: tVol, mu: tMu)
        let c = probBps(vol: cVol, mu: cMu)
        let band: ShortfallBand = t.prob < 2000 ? .low : (t.prob < 4000 ? .moderate : (t.prob < 6000 ? .elevated : .high))

        return ShortfallEstimate(
            requiredRealBps: required, expectedRealBps: tMu, frictionDragBps: friction, volBps: tVol, horizonYears: horizon,
            annualizedSigmaBps: t.annSigma, marginBps: tMu - required, zScore: t.z,
            shortfallProbBps: t.prob, currentShortfallProbBps: c.prob, currentExpectedRealBps: cMu,
            band: band, asOf: eval.asOf)
    }

    /// Standard-normal CDF via Zelen & Severo (1964); |error| < 7.5e-8. Self-contained
    /// (no erf dependency), keeping the engine pure and portable.
    static func normalCDF(_ x: Double) -> Double {
        let t = 1.0 / (1.0 + 0.2316419 * abs(x))
        let d = 0.3989422804014327 * exp(-x * x / 2.0)       // φ(x) = e^(−x²/2)/√(2π)
        let poly = t * (0.319381530 + t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429))))
        let upper = d * poly                                  // ≈ 1 − Φ(|x|)
        return x >= 0 ? 1.0 - upper : upper
    }
}
