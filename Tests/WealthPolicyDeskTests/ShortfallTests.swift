import XCTest
@testable import WealthPolicyDesk

/// The shortfall-probability engine and its self-contained standard-normal CDF. The CDF
/// is a closed-form approximation with no `erf` dependency — reference values guard it;
/// the estimate's structural identities guard the wiring.
final class ShortfallTests: XCTestCase {

    // MARK: - normalCDF (Zelen & Severo, |error| < 7.5e-8)

    func testNormalCDFReferenceValues() {
        let eps = 1e-3
        XCTAssertEqual(Engine.normalCDF(0), 0.5, accuracy: eps)
        XCTAssertEqual(Engine.normalCDF(1), 0.841345, accuracy: eps)
        XCTAssertEqual(Engine.normalCDF(-1), 0.158655, accuracy: eps)
        XCTAssertEqual(Engine.normalCDF(1.96), 0.975002, accuracy: eps)
        XCTAssertEqual(Engine.normalCDF(2), 0.977250, accuracy: eps)
        XCTAssertEqual(Engine.normalCDF(-2), 0.022750, accuracy: eps)
    }

    func testNormalCDFIsSymmetricMonotonicAndBounded() {
        for x in stride(from: -3.0, through: 3.0, by: 0.25) {
            XCTAssertEqual(Engine.normalCDF(x) + Engine.normalCDF(-x), 1.0, accuracy: 1e-6, "symmetry at \(x)")
            let v = Engine.normalCDF(x)
            XCTAssertGreaterThanOrEqual(v, 0); XCTAssertLessThanOrEqual(v, 1)
            XCTAssertLessThan(Engine.normalCDF(x), Engine.normalCDF(x + 0.25), "monotone at \(x)")
        }
        XCTAssertEqual(Engine.normalCDF(6), 1.0, accuracy: 1e-6)
        XCTAssertEqual(Engine.normalCDF(-6), 0.0, accuracy: 1e-6)
    }

    // MARK: - shortfallEstimate wiring

    private func estimate() -> ShortfallEstimate {
        let regime = Engine.macroRegime(Seed.macroIndicators)
        let cme = Engine.capitalMarketExpectations(Seed.macroIndicators, regime: regime)
        return Engine.shortfallEstimate(Engine.evaluate(Seed.sampleHousehold), cme: cme)
    }

    func testProbabilitiesAreInRangeAndMarginIsConsistent() {
        let s = estimate()
        for p in [s.shortfallProbBps, s.currentShortfallProbBps] {
            XCTAssertTrue((0...10000).contains(p), "a probability out of [0,1]")
        }
        XCTAssertEqual(s.marginBps, s.expectedRealBps - s.requiredRealBps, "margin is expected − required")
    }

    func testShortfallProbabilityTracksTheSignOfTheMargin() {
        let s = estimate()
        // Φ(z) with z = (required − expected)/σ crosses 50% exactly at margin = 0.
        if s.marginBps < -1 {
            XCTAssertGreaterThan(s.shortfallProbBps, 5000, "a negative cushion means worse-than-even odds")
        } else if s.marginBps > 1 {
            XCTAssertLessThan(s.shortfallProbBps, 5000)
        }
    }

    func testBandMatchesTheProbabilityThresholds() {
        let s = estimate()
        let expected: ShortfallBand = s.shortfallProbBps < 2000 ? .low
            : (s.shortfallProbBps < 4000 ? .moderate : (s.shortfallProbBps < 6000 ? .elevated : .high))
        XCTAssertEqual(s.band, expected)
    }

    func testShortfallIsDeterministic() {
        XCTAssertEqual(estimate().shortfallProbBps, estimate().shortfallProbBps)
    }

    // MARK: - CME reconciliation honesty (friction netting + cash floats)

    func testShortfallExpectedIsNetOfTheFrictionDial() {
        let s = estimate()
        XCTAssertEqual(s.frictionDragBps, Engine.cmeFrictionDragBps)
        XCTAssertGreaterThan(s.frictionDragBps, 0, "fees + tax drag must be netted, not zero")
    }

    private func reconciliation() -> CMEReconciliation {
        let regime = Engine.macroRegime(Seed.macroIndicators)
        let cme = Engine.capitalMarketExpectations(Seed.macroIndicators, regime: regime)
        return Engine.cmeReconciliation(Engine.evaluate(Seed.sampleHousehold), cme: cme)
    }

    func testReconciliationGapIsNetOfFrictionAndConsistent() {
        let rec = reconciliation()
        XCTAssertEqual(rec.frictionDragBps, Engine.cmeFrictionDragBps)
        XCTAssertEqual(rec.netTargetBps, rec.target.expectedRealBps - rec.frictionDragBps)
        XCTAssertEqual(rec.gapTargetBps, rec.netTargetBps - rec.requiredRealBps)
        // Netting can only tighten the gap vs the old gross basis — never flatter it.
        XCTAssertLessThan(rec.gapTargetBps, (rec.target.expectedRealBps - rec.requiredRealBps) + 1)
    }

    /// All THREE expected-vs-required surfaces (reconciliation, shortfall, frontier) must
    /// share one net-of-friction basis — the frontier target can't read 40bp higher than
    /// the reconciliation, or the same plan could show "Reachable" here and "STRETCH" there.
    func testFrontierSharesTheNetBasisWithTheReconciliation() {
        let eval = Engine.evaluate(Seed.sampleHousehold)
        let regime = Engine.macroRegime(Seed.macroIndicators)
        let cme = Engine.capitalMarketExpectations(Seed.macroIndicators, regime: regime)
        let rec = Engine.cmeReconciliation(eval, cme: cme)
        let front = Engine.frontier(eval, cme: cme)
        XCTAssertEqual(front.target.expRealBps, rec.netTargetBps,
                       "frontier target expected must be net of friction, matching the reconciliation")
        XCTAssertEqual(front.requiredRealBps, rec.requiredRealBps, "same required hurdle on both")
    }

    /// Cash's CME now floats off the snapshot 10y real (minus a term discount) instead of
    /// the frozen 1.5% PV anchor, and sits below the 10y bond's locked-in real yield.
    func testCashCMEFloatsWithTheMarketRealRateBelowBonds() {
        let regime = Engine.macroRegime(Seed.macroIndicators)
        let cme = Engine.capitalMarketExpectations(Seed.macroIndicators, regime: regime)
        let real10 = Int((Seed.macroIndicators.first { $0.name == "10y real rate" }!.value * 100).rounded())
        let cash = cme.realBps(sleeveId: "cash")!
        XCTAssertEqual(cash, max(0, real10 - 85), "cash real = 10y real − term discount, not a frozen anchor")
        XCTAssertLessThan(cash, cme.realBps(sleeveId: "fixed_income_liquid")!,
                          "rolling cash sits below the 10y bond's locked-in real yield")
    }
}
