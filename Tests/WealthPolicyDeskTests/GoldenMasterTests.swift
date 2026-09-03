import XCTest
@testable import WealthPolicyDesk

/// Golden master over the whole `Engine.evaluate` pipeline on the sample household
/// (the Harrisons). Any change that moves a headline figure fails here — update the
/// expected values deliberately when a change is intended. Captured 2026-08-21;
/// required-return / funded figures re-captured after the couples-spending model
/// (survivor drop + save-until-later-retirement).
///
/// Re-captured again after the tax-input corrections (461 → 465, funded 6252 → 6228).
/// All three drivers RAISE lifetime tax, so the old figures were flattered:
///   1. Itemization no longer claims a fabricated $20,000/yr charitable deduction. The
///      Harrisons give $0, so that deduction was pure invention; charity now reads from
///      `estate.annualGivingUsd`. This is the dominant driver.
///   2. State tax comes from the household's own state profile (NJ 6.37%/1.89%) instead
///      of a hardcoded 6%/1.8% "NJ-ish" constant applied to every client.
///   3. Susan's final working year is now taxed: the projection starts at Robert's
///      retirement, and she works one year past it, which the loop previously ignored.
/// RMDs also correctly begin at 75 rather than 73 (Robert, born 1963 — SECURE 2.0),
/// which pushes the other way but is outweighed by the three above.
final class GoldenMasterTests: XCTestCase {

    func testHarrisonsHeadlineFigures() {
        let e = Engine.evaluate(Seed.sampleHousehold)
        XCTAssertEqual(e.requiredReturn.requiredRealReturnBps, 465)
        XCTAssertEqual(e.requiredReturn.requiredRealReturnPreTaxBps, 403)
        XCTAssertEqual(e.balanceSheet.fundedRatioBps, 6228)
        XCTAssertEqual(e.balanceSheet.afterTaxNetWorthUsd, 2_893_928, accuracy: 0.5)
        XCTAssertEqual(e.balanceSheet.grossNetWorthUsd, 3_105_000, accuracy: 0.5)
        XCTAssertEqual(e.netFixedIncomeUsd, -120_000, accuracy: 0.5)
        XCTAssertEqual(e.riskProfile?.bindingEquityBps, 6000)
        XCTAssertEqual(e.riskProfile?.capacityEquityBps, 6700)
        XCTAssertEqual(e.riskProfile?.toleranceImpliedEquityBps, 6000)
    }

    func testHarrisonsAllocationAndFindings() {
        let e = Engine.evaluate(Seed.sampleHousehold)
        // The sleeve budget is ~8000 bps; alternatives carry the residual ~2000.
        XCTAssertEqual(e.allocation.reduce(0) { $0 + $1.targetBps }, 8000)
        XCTAssertEqual(e.allocation.count, 14)
        XCTAssertEqual(e.altSizing.reduce(0) { $0 + $1.targetBps }, 2000)
        XCTAssertEqual(e.findings.filter { $0.severity == .hard }.count, 4)
        XCTAssertEqual(e.findings.filter { $0.severity == .soft }.count, 12)
        XCTAssertEqual(e.household.goals.filter { $0.kind == .spending }.count, 1)
    }

    /// The balance-sheet identity the whole app rests on.
    func testAfterTaxNetWorthIsGrossMinusEmbeddedTaxAndDebt() {
        let e = Engine.evaluate(Seed.sampleHousehold)
        XCTAssertLessThan(e.balanceSheet.afterTaxNetWorthUsd, e.balanceSheet.grossNetWorthUsd,
                          "after-tax net worth must sit below gross (embedded tax + estate tax removed)")
        XCTAssertGreaterThan(e.balanceSheet.liabilities.deferredTaxUsd, 0)
    }

    /// A blank intake still produces a coherent, evaluable plan (onboarding safety).
    func testDefaultIntakeBuildsAndEvaluates() {
        let h = IntakeModel().buildHousehold()
        let e = Engine.evaluate(h)
        XCTAssertGreaterThan(e.household.goals.count, 0)
        XCTAssertNotNil(e.riskProfile)
        XCTAssertEqual(e.allocation.reduce(0) { $0 + $1.targetBps }, 8000)
    }
}
