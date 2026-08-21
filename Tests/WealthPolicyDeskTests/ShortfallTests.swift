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
}
