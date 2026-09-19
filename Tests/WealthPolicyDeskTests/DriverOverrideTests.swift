import XCTest
@testable import WealthPolicyDesk

/// The editable IPS drivers — that each `HouseholdOverrides` field patches the household
/// correctly and moves the re-derived plan in the right direction. These lock the
/// behavior the Policy Statement's inline editors depend on.
final class DriverOverrideTests: XCTestCase {

    private let base = Seed.sampleHousehold
    private var baseEval: Evaluation { Engine.evaluate(base) }

    // MARK: field patches (withDriverOverrides sets the right household field)

    func testLegacyFloorPatch() {
        let h = base.withDriverOverrides(HouseholdOverrides(legacyFloorUsd: 2_000_000))
        XCTAssertEqual(h.legacyFloorUsd, 2_000_000)
    }

    func testTolerancePatch() {
        let h = base.withDriverOverrides(HouseholdOverrides(toleranceMaxDrawdownBps: 4000))
        XCTAssertEqual(h.statedToleranceMaxDrawdownBps, 4000)
    }

    func testSavingsPatch() {
        let h = base.withDriverOverrides(HouseholdOverrides(annualSavingsUsd: 250_000))
        XCTAssertEqual(h.annualSavingsUsd, 250_000)
    }

    func testAddAndRemoveGoal() {
        let add = HouseholdOverrides(addedGoals: [GoalEdit(id: "t1", label: "College", annualUsd: 40_000, startYear: 2, years: 4)])
        let h = base.withDriverOverrides(add)
        XCTAssertTrue(h.goals.contains { $0.id == "ov_t1" })
        XCTAssertEqual(h.goals.first { $0.id == "ov_t1" }?.outflows.count, 4)

        let removed = base.withDriverOverrides(HouseholdOverrides(removedGoalIds: ["g_reserve"]))
        XCTAssertFalse(removed.goals.contains { $0.id == "g_reserve" })
    }

    func testGoalAmountOverride() {
        let h = base.withDriverOverrides(HouseholdOverrides(goalAmountOverrides: ["g_spending": 300_000]))
        let spend = h.goals.first { $0.id == "g_spending" }
        XCTAssertEqual(spend?.outflows.first?.amountUsd, 300_000)
    }

    // MARK: re-derivation moves in the expected direction

    func testHigherLegacyFloorRaisesRequiredReturn() {
        let hi = Engine.evaluate(base.withDriverOverrides(HouseholdOverrides(legacyFloorUsd: 5_000_000)))
        XCTAssertGreaterThan(hi.requiredReturn.requiredRealReturnBps, baseEval.requiredReturn.requiredRealReturnBps)
    }

    func testMoreSavingsRaisesFundedRatio() {
        let hi = Engine.evaluate(base.withDriverOverrides(HouseholdOverrides(annualSavingsUsd: 300_000)))
        XCTAssertGreaterThan(hi.balanceSheet.fundedRatioBps, baseEval.balanceSheet.fundedRatioBps)
    }

    func testAddingAGoalRaisesRequiredReturn() {
        let add = HouseholdOverrides(addedGoals: [GoalEdit(id: "big", label: "Boat", annualUsd: 100_000, startYear: 1, years: 6)])
        let hi = Engine.evaluate(base.withDriverOverrides(add))
        XCTAssertGreaterThan(hi.requiredReturn.requiredRealReturnBps, baseEval.requiredReturn.requiredRealReturnBps)
    }

    func testRetiringLaterRaisesFundedRatio() {
        guard let primary = base.primary else { return XCTFail("no primary") }
        let later = base.withDriverOverrides(HouseholdOverrides(retirementAge: primary.expectedRetirementAge + 4))
        XCTAssertGreaterThan(Engine.evaluate(later).balanceSheet.fundedRatioBps, baseEval.balanceSheet.fundedRatioBps)
    }

    func testSpouseRetirementEditsSpouseOnly() {
        guard let spouse = base.people.first(where: { $0.role == .spouse }) else { return XCTFail("sample must be a couple") }
        let sid = spouse.id
        let pid = base.primary?.id
        let h = base.withDriverOverrides(HouseholdOverrides(spouseRetirementAge: spouse.expectedRetirementAge + 3))
        XCTAssertEqual(h.people.first { $0.id == sid }?.expectedRetirementAge, spouse.expectedRetirementAge + 3)
        // the primary's retirement age is untouched
        XCTAssertEqual(h.people.first { $0.id == pid }?.expectedRetirementAge, base.primary?.expectedRetirementAge)
    }

    /// Retiring past the plan horizon must be clamped so working years / human capital
    /// never extend past the spending schedule (the reviewed MED fix).
    func testRetirementAgeIsClampedToHorizon() {
        guard let primary = base.primary else { return XCTFail("no primary") }
        let h = base.withDriverOverrides(HouseholdOverrides(retirementAge: 130))
        let eff = h.people.first { $0.id == primary.id }?.expectedRetirementAge ?? 0
        XCTAssertLessThan(eff, 130, "retirement age must be clamped, not applied literally")
        let hc = h.humanCapital.first { $0.personId == primary.id }?.yearsRemaining ?? -1
        XCTAssertGreaterThanOrEqual(hc, 0)
    }

    /// An empty override is a no-op: same plan out.
    func testEmptyOverrideIsNoOp() {
        let same = Engine.evaluate(base.withDriverOverrides(HouseholdOverrides()))
        XCTAssertEqual(same.requiredReturn.requiredRealReturnBps, baseEval.requiredReturn.requiredRealReturnBps)
        XCTAssertEqual(same.balanceSheet.fundedRatioBps, baseEval.balanceSheet.fundedRatioBps)
        XCTAssertTrue(HouseholdOverrides().isEmpty)
    }

    /// Pushing a still-working client into "already retired" via the IPS slider must schedule
    /// this year's spending, not skip to year 1.
    func testRetiringNowEmitsYearZeroSpending() {
        guard let primary = base.primary else { return XCTFail("no primary") }
        let age = Engine.age(birthDate: primary.birthDate, asOf: base.planAsOf)
        let h = base.withDriverOverrides(HouseholdOverrides(retirementAge: age))
        let first = h.goals.first { $0.id == "g_spending" }?.outflows.map(\.year).min()
        XCTAssertEqual(first, 0, "an override that retires the primary today must draw in year 0")
    }

    /// Ages and the spending start must follow the household's own plan date, not the 2026 pin.
    func testRetirementOverrideAgesAgainstTheHouseholdsPlanDate() {
        var h = base
        h.planAsOf = "2031-06-30"
        let ageThen = Engine.age(birthDate: h.primary!.birthDate, asOf: h.planAsOf)
        XCTAssertEqual(ageThen, 68, "Robert (b. 1963-03-01) is 68 on 2031-06-30")
        XCTAssertEqual(Engine.age(birthDate: h.primary!.birthDate, asOf: Engine.planningAsOf), 63,
                       "fixture check: the 2026 pin still ages him 63 — the wrong clock")
        let retired = h.withDriverOverrides(HouseholdOverrides(retirementAge: ageThen))
        XCTAssertEqual(retired.goals.first { $0.id == "g_spending" }?.outflows.map(\.year).min(), 0,
                       "if the override still aged against 2026, start would be 68 − 63 = 5, not 0")
    }
}
