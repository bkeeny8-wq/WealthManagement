import XCTest
@testable import WealthPolicyDesk

/// Intake claims that used to date or offset incorrectly: additional/education years
/// colliding this-year with next-year, a 529 that never reduced tuition, QCD dollars
/// that survived an eligibility toggle, and ISO/83(b) flags that survived deselection.
final class IntakeClaimWiringTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"
    private var yr: Int { Engine.year(asOf) }

    private func base() -> IntakeModel {
        var m = IntakeModel()
        var a = IntakeAdult(); a.birthYear = yr - 45; a.retirementAge = 65; a.salaryUsd = 180_000
        m.adults = [a]
        m.taxableUsd = 800_000
        m.retirementSpendingUsd = 90_000
        return m
    }

    /// Calendar this-year and next-year must be distinct plan years. `max(1, year − yr)`
    /// mapped both to plan year 1, so a home purchase "this year" was silently next year.
    func testThisYearAndNextYearAdditionalGoalsAreDistinctPlanYears() {
        var m = base()
        var now = IntakeGoal(); now.label = "Now"; now.amountUsd = 80_000; now.targetYear = yr; now.spanYears = 1
        var next = IntakeGoal(); next.label = "Next"; next.amountUsd = 80_000; next.targetYear = yr + 1; next.spanYears = 1
        m.additionalGoals = [now, next]
        let h = m.buildHousehold(asOf: asOf)
        let nowYears = h.goals.first { $0.label == "Now" }?.outflows.map(\.year) ?? []
        let nextYears = h.goals.first { $0.label == "Next" }?.outflows.map(\.year) ?? []
        XCTAssertEqual(nowYears, [0], "a claim dated this calendar year is plan year 0")
        XCTAssertEqual(nextYears, [1], "next calendar year must not collapse onto this year")
    }

    func testEducationStartingThisYearIsPlanYearZero() {
        var m = base()
        var g = IntakeEducationGoal(); g.annualCostTodayUsd = 40_000; g.years = 1; g.startYear = yr
        m.educationGoals = [g]
        let years = m.buildHousehold(asOf: asOf).goals
            .first { $0.id.hasPrefix("g_edu_") }?.outflows.map(\.year) ?? []
        XCTAssertEqual(years, [0])
    }

    /// The education form promises a 529 offset. Spreading the balance across the
    /// tuition years is that offset — without it the full ladder is a liability and
    /// the 529 is stored then ignored.
    func testA529ReducesTheEducationOutflow() {
        var m = base()
        var g = IntakeEducationGoal()
        g.annualCostTodayUsd = 40_000; g.years = 4; g.startYear = yr + 10
        g.five29BalanceUsd = 80_000          // $20k/yr against $40k tuition
        m.educationGoals = [g]
        let out = m.buildHousehold(asOf: asOf).goals.first { $0.id.hasPrefix("g_edu_") }?.outflows ?? []
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0].amountUsd, 20_000, accuracy: 0.5)
        XCTAssertEqual(out.map(\.amountUsd).reduce(0, +), 80_000, accuracy: 0.5)
    }

    func testTurningOffQcdEligibilityDropsPlannedQcd() {
        var m = base()
        m.qcdEligible = false
        m.qcdPlannedUsd = 12_000
        XCTAssertEqual(m.buildHousehold(asOf: asOf).estate.qcdPlannedUsd, 0,
                       "hidden QCD dollars must not reach Disposition, matching DAF")
        m.qcdEligible = true
        XCTAssertEqual(m.buildHousehold(asOf: asOf).estate.qcdPlannedUsd, 12_000, accuracy: 0.5)
    }

    /// Clearing the ISO chip hides the AMT fields but used to leave them on the
    /// mechanics object, so `iso_amt_exposure` still fired.
    func testDroppingIsoClearsAmtFindings() {
        var m = base()
        m.equityGrantTypes = [.espp]
        m.planningIsoExerciseAndHold = true
        m.isoBargainElementUsd = 250_000
        m.esppAnnualContributionUsd = 15_000
        let ids = Engine.evaluate(m.buildHousehold(asOf: asOf)).findings.map(\.ruleId)
        XCTAssertFalse(ids.contains("iso_amt_exposure"),
                       "an ESPP-only grant set must not carry a leftover ISO AMT flag")
    }

    func testDroppingRestrictedStockClearsThe83bWindow() {
        var m = base()
        m.equityGrantTypes = [.iso]
        m.pending83bGrantDate = "2026-08-01"
        m.isoUnexercisedValueUsd = 50_000
        let ids = Engine.evaluate(m.buildHousehold(asOf: asOf)).findings.map(\.ruleId)
        XCTAssertFalse(ids.contains("83b_window"),
                       "an ISO-only grant set must not keep a hidden 83(b) date")
    }

    /// The education form can bind a goal to a named child. `buildHousehold` already
    /// labels from `childId`; without a picker the field stayed nil and every College
    /// row read as unlabeled "College".
    func testEducationGoalBoundToAChildCarriesTheName() {
        var m = base()
        var c = IntakeChild(); c.name = "Ada"
        m.children = [c]
        var g = IntakeEducationGoal(); g.annualCostTodayUsd = 40_000; g.years = 1
        g.startYear = yr + 10; g.childId = c.id
        m.educationGoals = [g]
        let label = m.buildHousehold(asOf: asOf).goals.first { $0.id.hasPrefix("g_edu_") }?.label ?? ""
        XCTAssertTrue(label.hasPrefix("Ada"), "bound childId must surface on the claim: \(label)")
    }

    /// Dropping a child used to leave `educationGoals[].childId` pointing at a UUID
    /// with no roster match, so the picker showed a dangling id and the goal still
    /// labelled as that child's college.
    func testRemovingAChildUnbindsEducationGoals() {
        var m = base()
        var c = IntakeChild(); c.name = "Ada"
        m.children = [c]
        var g = IntakeEducationGoal(); g.annualCostTodayUsd = 40_000; g.years = 1
        g.startYear = yr + 10; g.childId = c.id
        m.educationGoals = [g]
        m.removeChild(c.id)
        XCTAssertTrue(m.children.isEmpty)
        XCTAssertNil(m.educationGoals.first?.childId,
                     "a deleted child's id must not linger on the education row")
        let label = m.buildHousehold(asOf: asOf).goals.first { $0.id.hasPrefix("g_edu_") }?.label ?? ""
        XCTAssertEqual(label, "College", "unbound goal must drop the deleted child's name: \(label)")
    }

    /// Batch 6 dated a this-year extra goal as plan year 0; the required-return solve
    /// still started at t=1 for workers, so the claim never entered the rate.
    func testThisYearExtraGoalMovesAWorkersRequiredReturn() {
        var now = base(); var later = base()
        var gNow = IntakeGoal(); gNow.label = "Home"; gNow.amountUsd = 200_000; gNow.targetYear = yr; gNow.spanYears = 1
        var gLater = gNow; gLater.targetYear = yr + 1
        now.additionalGoals = [gNow]
        later.additionalGoals = [gLater]
        let rNow = Engine.requiredReturn(now.buildHousehold(asOf: asOf), asOf: asOf)
        let rLater = Engine.requiredReturn(later.buildHousehold(asOf: asOf), asOf: asOf)
        XCTAssertGreaterThan(rNow.requiredRealReturnBps, rLater.requiredRealReturnBps,
                             "a worker's this-year extra claim must raise required return vs next year")
    }
}
