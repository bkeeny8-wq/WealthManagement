import XCTest
@testable import WealthPolicyDesk

/// The resilience engine — return-sensitivity and sequence-of-returns stresses, plus the
/// bisected max-safe-spend. No market forecasts, so these lock shape, not levels:
/// sensitivities rise with the realized return, survivors are bounded, headroom is signed
/// consistently with the safe-spend solve.
final class ResilienceTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"
    private func analysis() -> ResilienceAnalysis {
        let h = Seed.sampleHousehold
        let rr = Engine.requiredReturn(h, asOf: asOf)
        return Engine.resilience(h, tax: Seed.tax2026, rr: rr, asOf: asOf, annualTaxUsd: [:])
    }

    func testTerminalBalanceRisesWithTheRealizedReturn() {
        let s = analysis().sensitivities.sorted { $0.realReturnBps < $1.realReturnBps }
        XCTAssertGreaterThan(s.count, 1)
        for (lo, hi) in zip(s, s.dropFirst()) {
            XCTAssertLessThanOrEqual(lo.terminalBalanceUsd, hi.terminalBalanceUsd + 0.5,
                                     "a higher realized return cannot leave a smaller terminal balance")
        }
    }

    func testRequiredReturnIsOneOfTheSensitivityPoints() {
        let a = analysis()
        XCTAssertTrue(a.sensitivities.contains { $0.realReturnBps == a.requiredRealReturnBps },
                      "the required return itself must be a sampled point")
    }

    func testSurvivorCountIsBoundedAndConsistent() {
        let a = analysis()
        XCTAssertEqual(a.stressCount, a.stresses.count)
        XCTAssertEqual(a.stressCount, 3, "three historical bad-order stresses")
        XCTAssertEqual(a.stressesSurvived, a.stresses.filter { $0.survives }.count)
        XCTAssertTrue((0...a.stressCount).contains(a.stressesSurvived))
        // A stress that depletes cannot also be recorded as surviving.
        for s in a.stresses { if s.depletionAge != nil { XCTAssertFalse(s.survives) } }
    }

    func testMaxSafeSpendAndHeadroomAreSignConsistent() {
        let a = analysis()
        XCTAssertGreaterThanOrEqual(a.maxSafeSpendUsd, 0)
        if a.currentSpendUsd > 0 {
            if a.maxSafeSpendUsd > a.currentSpendUsd + 1 {
                XCTAssertGreaterThan(a.spendHeadroomBps, 0)
            } else if a.maxSafeSpendUsd < a.currentSpendUsd - 1 {
                XCTAssertLessThan(a.spendHeadroomBps, 0)
            }
        }
    }

    func testResilienceIsDeterministic() {
        let a = analysis(), b = analysis()
        XCTAssertEqual(a.maxSafeSpendUsd, b.maxSafeSpendUsd, accuracy: 0.0001)
        XCTAssertEqual(a.stressesSurvived, b.stressesSurvived)
        XCTAssertEqual(a.sensitivities.map(\.terminalBalanceUsd), b.sensitivities.map(\.terminalBalanceUsd))
    }
}
