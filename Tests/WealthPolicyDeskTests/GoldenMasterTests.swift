import XCTest
@testable import WealthPolicyDesk

/// Golden master over the whole `Engine.evaluate` pipeline on the sample household
/// (the Harrisons). Any change that moves a headline figure fails here — update the
/// expected values deliberately when a change is intended. Captured 2026-08-21;
/// required-return / funded figures re-captured after the couples-spending model
/// (survivor drop + save-until-later-retirement).
///
/// Re-captured after the tax-input corrections (461 → 465, funded 6252 → 6228) and again
/// after wage cash conservation (465 → 479, pre-tax 403 → 423, funded 6228 → 6264).
///
/// Each move below is MEASURED by reverting that driver alone, not inferred. An earlier
/// version of this comment credited the itemization corrections; reverting them moves
/// nothing, because `itemizationInput` feeds only the itemization, muni-crossover and
/// paydown outputs and never reaches the required-return solve.
///
/// 461 → 465 / 6252 → 6228:
///   • Susan's final working year is taxed (+5 bps rr, −25 bps funded) — dominant.
///   • RMDs begin at 75, not 73 (Robert, born 1963 — SECURE 2.0): −1 bp / +1 bp.
///   • Itemization state profile and real charitable giving: 0 bps. Inert to these figures.
///
/// 465 → 479 / 6228 → 6264:
///   • Savings are capped at the wages that fund them (+21 bps rr). `householdSaveYears`
///     books savings through the LATER retirement — plan-year 3 for Susan — but she stops
///     earning at plan-year 2, so the recursion was crediting one phantom savings year.
///   • A working year's tax is settled from that year's wages before the portfolio
///     (−7 bps rr). The recursion now reads `portfolioTaxUsd`, not the headline tax.
///   • Funded ratio rises with rr because the goal liabilities are discounted at it.
///
/// 6264 → 6262: RMDs follow each ACCOUNT OWNER's own required age rather than the
/// primary's. Susan (b. 1965) is younger than Robert (b. 1963), so her 401(k) begins
/// distributing two years after his IRA instead of alongside it, moving the tax series
/// slightly. Required return is unchanged at 479.
///
/// 6262 → 6086: funded-ratio savings PV is now wage-capped like the required-return
/// solve. Plan-year 3 is a saving year by `householdSaveYears` but has no earner, so
/// the $80k phantom contribution drops out of the PV. Required return is unchanged
/// (it already capped that year at $0).
final class GoldenMasterTests: XCTestCase {

    func testHarrisonsHeadlineFigures() {
        let e = Engine.evaluate(Seed.sampleHousehold)
        XCTAssertEqual(e.requiredReturn.requiredRealReturnBps, 479)
        XCTAssertEqual(e.requiredReturn.requiredRealReturnPreTaxBps, 423)
        XCTAssertEqual(e.balanceSheet.fundedRatioBps, 6086)
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
        // 4 -> 5: `liquidity_floor` now fires. The ladder is measured against cash and
        // fixed income rather than every non-private position, so the Harrisons' need of
        // ~$1.29M is no longer "covered" by $460k of defensive assets plus equities. The
        // rule was previously unfireable, while the IPS told the client the opposite.
        XCTAssertEqual(e.findings.filter { $0.severity == .hard }.count, 5)
        XCTAssertTrue(e.findings.contains { $0.ruleId == "liquidity_floor" && $0.severity == .hard },
                      "the spending ladder must not be satisfied by equities")
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
