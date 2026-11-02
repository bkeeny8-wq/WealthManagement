import XCTest
@testable import WealthPolicyDesk

/// FORWARD INCOME MODELLING — "potential income".
///
/// The app carried one salary and one bonus per earner. The first real case study earns a
/// $50,000 bonus THIS year, prorated after a mid-year move, against a $200,000+ target from
/// 2027 on. A single number is either wrong this year or wrong every year after it, and the
/// error propagates into the savings cap, the wage term the decumulation credits, the required
/// return and the human-capital present value.
///
/// Every assertion here is written in BOTH directions. A schedule that raises compensation must
/// raise the PV and the savings PV; one that lowers it must lower them. A one-sided test here
/// would pass against a stub that ignored the schedule in one direction, or against the rival
/// wrong fix — a schedule read as a REPLACEMENT for the single number in every year, including
/// the years before the first stated entry.
final class CompensationScheduleTests: XCTestCase {

    private let asOf: IsoDate = "2026-11-01"
    private var planYear: Int { Engine.year(asOf) }

    // MARK: - Fixtures

    /// The case study, as a single number: $225,000 + $50,000, every year.
    private func singleNumber() -> IntakeModel {
        var a = IntakeAdult()
        a.name = "A"; a.birthYear = planYear - 36; a.retirementAge = 65
        a.salaryUsd = 225_000; a.bonusUsd = 50_000
        a.incomeCharacter = .equityLike; a.sector = .financials
        a.socialSecurityMonthlyUsd = 4_253
        var m = IntakeModel()
        m.adults = [a]
        m.state = "NJ"; m.planToAge = 92
        m.taxableUsd = 16_937; m.emergencyReserveUsd = 2_000
        m.retirementSpendingUsd = 140_000
        m.annualSavingsUsd = 30_000
        return m
    }

    /// The case study as it actually is: $50,000 of bonus this year because it is prorated
    /// after a mid-year move, $200,000 from next year on.
    private func statedPath() -> IntakeModel {
        var m = singleNumber()
        m.adults[0].compYears = [
            IntakeCompYear(calendarYear: planYear, salaryUsd: 225_000, cashBonusUsd: 50_000),
            IntakeCompYear(calendarYear: planYear + 1, salaryUsd: 225_000, cashBonusUsd: 200_000),
        ]
        return m
    }

    private func hc(_ h: Household) -> HumanCapital { h.humanCapital[0] }

    // MARK: - The single-number case is untouched

    /// No schedule ⇒ the level is the single number in every year, and the projected path is
    /// exactly `annualIncomeUsd * (1 + g)^(t - 1)` — the term the human-capital PVs already
    /// contained. The legacy expression is RECOMPUTED here rather than read back through the
    /// new accessor, so a stub that returned `statedIncomeUsd` for both could not pass.
    func testEmptyScheduleReproducesTheOldArithmeticExactly() {
        let c = hc(singleNumber().buildHousehold(asOf: asOf))
        XCTAssertTrue(c.compensationSchedule.isEmpty, "fixture check: this adult has no stated path")
        let g = c.realGrowthRateBps.frac
        XCTAssertGreaterThan(g, 0, "fixture check: a zero growth rate would make the two accessors coincide")
        for t in 0...40 {
            XCTAssertEqual(c.statedIncomeUsd(planYear: t), 275_000, accuracy: 0.5,
                           "year \(t): with no schedule the wage level must stay the single number")
            XCTAssertEqual(c.projectedIncomeUsd(planYear: t), 275_000 * pow(1 + g, Double(max(0, t - 1))), accuracy: 0.5,
                           "year \(t): with no schedule the projected path must be the pre-existing PV term")
        }
    }

    /// And the whole evaluation is unchanged: the sample household's human-capital PV, required
    /// return and funded ratio are the same with the schedule machinery in place as the
    /// independently recomputed legacy formula gives.
    func testSeededHouseholdHumanCapitalPvIsUnchanged() {
        let h = Seed.sampleHousehold
        var expected: Usd = 0
        for c in h.humanCapital where c.yearsRemaining > 0 {
            let g = c.realGrowthRateBps.frac
            for t in 1...c.yearsRemaining {
                expected += c.annualIncomeUsd * pow(1 + g, Double(t - 1)) / pow(1 + Engine.humanCapitalDiscount, Double(t))
            }
        }
        XCTAssertGreaterThan(expected, 0, "fixture check: the seeded household must still have human capital")
        XCTAssertEqual(Engine.evaluate(h).balanceSheet.assets.humanCapitalPvUsd, expected, accuracy: 1,
                       "the schedule machinery moved a household that states no path")
    }

    // MARK: - The near-term path

    /// The case study. $275,000 this year, $425,000 next, and the last stated level holds —
    /// flat as a wage level, growing as a projection.
    func testKnownNearTermPathIsPaidYearByYear() {
        let h = statedPath().buildHousehold(asOf: asOf)
        let c = hc(h)
        XCTAssertEqual(c.compensationSchedule.map(\.year), [0, 1],
                       "calendar years must arrive as plan-year offsets from asOf")

        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: 0, asOf: asOf), 275_000, accuracy: 0.5,
                       "this year's prorated bonus must be paid, not the target")
        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: 1, asOf: asOf), 425_000, accuracy: 0.5,
                       "next year's stated target must be paid, not this year's prorated figure")
        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: 5, asOf: asOf), 425_000, accuracy: 0.5,
                       "past the last stated year the level holds; it must not revert to the single number")

        // The mirror: the single-number household pays the WRONG number in both years, which is
        // the defect. If these two coincided the test above would prove nothing.
        let flat = singleNumber().buildHousehold(asOf: asOf)
        XCTAssertEqual(Engine.wagesAtPlanYear(flat, year: 0, asOf: asOf), 275_000, accuracy: 0.5)
        XCTAssertNotEqual(Engine.wagesAtPlanYear(flat, year: 1, asOf: asOf),
                          Engine.wagesAtPlanYear(h, year: 1, asOf: asOf), accuracy: 1_000,
                          "fixture check: the stated path must differ from the single number somewhere")
    }

    /// A step change at a date is the SAME construct — one entry. The years BEFORE it keep the
    /// single number. This is the rival wrong fix: reading the schedule as a replacement in
    /// every year would pay the promoted salary from today.
    func testStepChangeLeavesTheYearsBeforeItAlone() {
        var m = singleNumber()
        m.adults[0].compYears = [IntakeCompYear(calendarYear: planYear + 3, salaryUsd: 300_000, cashBonusUsd: 60_000)]
        let h = m.buildHousehold(asOf: asOf)

        for t in 0...2 {
            XCTAssertEqual(Engine.wagesAtPlanYear(h, year: t, asOf: asOf), 275_000, accuracy: 0.5,
                           "year \(t) is before the step: the single number must still govern")
            XCTAssertNotEqual(Engine.wagesAtPlanYear(h, year: t, asOf: asOf), 360_000, accuracy: 1_000,
                              "year \(t) must not already be paying the post-promotion level")
        }
        for t in 3...8 {
            XCTAssertEqual(Engine.wagesAtPlanYear(h, year: t, asOf: asOf), 360_000, accuracy: 0.5,
                           "year \(t) is at or after the step: the new level must govern")
        }
    }

    /// A stated year already BEHIND the evaluation date is history. Left in, it would be the
    /// greatest entry at or below year 0 and would govern this year's wages.
    func testStatedYearsInThePastAreDropped() {
        var m = singleNumber()
        m.adults[0].compYears = [
            IntakeCompYear(calendarYear: planYear - 2, salaryUsd: 120_000, cashBonusUsd: 0),
            IntakeCompYear(calendarYear: planYear + 1, salaryUsd: 225_000, cashBonusUsd: 200_000),
        ]
        let h = m.buildHousehold(asOf: asOf)
        XCTAssertEqual(hc(h).compensationSchedule.map(\.year), [1],
                       "a year behind the evaluation date is history and must not enter the schedule")
        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: 0, asOf: asOf), 275_000, accuracy: 0.5,
                       "a stale past year must not govern this year's wages")
        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: 1, asOf: asOf), 425_000, accuracy: 0.5,
                       "dropping the past year must not drop the future one with it")
    }

    // MARK: - The two accessors cannot drift

    /// `statedIncomeUsd` is a flat real LEVEL; `projectedIncomeUsd` grows it. They must agree
    /// exactly AT a stated year, where the growth exponent is zero — the only identity holding
    /// the wage term and the PV path to the same path.
    func testLevelAndProjectionAgreeAtEveryStatedYear() {
        let c = hc(statedPath().buildHousehold(asOf: asOf))
        for e in c.compensationSchedule {
            XCTAssertEqual(c.projectedIncomeUsd(planYear: e.year), c.statedIncomeUsd(planYear: e.year), accuracy: 0.5,
                           "year \(e.year) is stated: the projection must not have grown off it")
        }
        // And they must DIVERGE past the last stated year — otherwise the equality above is
        // vacuous because growth is being ignored everywhere.
        let last = c.compensationSchedule.map(\.year).max() ?? 0
        XCTAssertGreaterThan(c.projectedIncomeUsd(planYear: last + 5), c.statedIncomeUsd(planYear: last + 5) + 1,
                             "past the last stated year the projection must grow at the real growth rate")
    }

    /// Salary and cash bonus stay separable, so a volatility band taken around the bonus takes
    /// it around the GOVERNING year's bonus. `bonusVolatilityBps` reads nothing today; this
    /// pins the hook so the first reader cannot reach for a stale `expectedBonusUsd`.
    func testBonusComponentIsReadableForTheGoverningYear() {
        let c = hc(statedPath().buildHousehold(asOf: asOf))
        XCTAssertEqual(c.statedCompUsd(planYear: 0).cashBonus, 50_000, accuracy: 0.5,
                       "this year's bonus is the prorated one")
        XCTAssertEqual(c.statedCompUsd(planYear: 1).cashBonus, 200_000, accuracy: 0.5,
                       "next year's bonus is the target")
        XCTAssertEqual(c.statedCompUsd(planYear: 1).salary, 225_000, accuracy: 0.5,
                       "the salary component must not absorb the bonus step")
        XCTAssertNotEqual(c.statedCompUsd(planYear: 1).cashBonus, c.expectedBonusUsd, accuracy: 1_000,
                          "fixture check: the stale single-number bonus must differ from the governing one")
    }

    // MARK: - Human-capital PV, both directions

    /// A path that RAISES compensation raises the PV; a path that LOWERS it lowers the PV. Both
    /// against the same single-number baseline, because a fix that ignored the schedule, or one
    /// that took its absolute value, would pass either assertion alone.
    func testPvMovesWithTheStatedPathInBothDirections() {
        let base = Engine.evaluate(singleNumber().buildHousehold(asOf: asOf)).balanceSheet.assets.humanCapitalPvUsd

        let up = Engine.evaluate(statedPath().buildHousehold(asOf: asOf)).balanceSheet.assets.humanCapitalPvUsd

        var downModel = singleNumber()
        downModel.adults[0].compYears = [
            IntakeCompYear(calendarYear: planYear, salaryUsd: 225_000, cashBonusUsd: 50_000),
            IntakeCompYear(calendarYear: planYear + 1, salaryUsd: 120_000, cashBonusUsd: 0),
        ]
        let down = Engine.evaluate(downModel.buildHousehold(asOf: asOf)).balanceSheet.assets.humanCapitalPvUsd

        XCTAssertGreaterThan(up, base + 1_000, "a bonus stepping UP to the target must raise human capital")
        XCTAssertLessThan(down, base - 1_000, "a career stepping DOWN must lower human capital")
    }

    /// A stated year past retirement is never reached. The schedule describes compensation, it
    /// does not extend a career. Mirror: the same entry placed INSIDE the working window does
    /// move the numbers, so the test is not just asserting that schedules do nothing.
    func testAStatedYearPastRetirementIsNeverPaid() {
        let retireIn = 65 - 36                       // 29 plan years
        var late = singleNumber()
        late.adults[0].compYears = [IntakeCompYear(calendarYear: planYear + retireIn + 5, salaryUsd: 900_000, cashBonusUsd: 0)]
        let lateH = late.buildHousehold(asOf: asOf)
        let baseH = singleNumber().buildHousehold(asOf: asOf)

        XCTAssertEqual(Engine.wagesAtPlanYear(lateH, year: retireIn, asOf: asOf), 0, accuracy: 0.5,
                       "the retirement gate still ends the earning")
        XCTAssertEqual(Engine.wagesAtPlanYear(lateH, year: retireIn + 5, asOf: asOf), 0, accuracy: 0.5,
                       "a stated year past retirement must not resurrect wages")
        XCTAssertEqual(Engine.evaluate(lateH).balanceSheet.assets.humanCapitalPvUsd,
                       Engine.evaluate(baseH).balanceSheet.assets.humanCapitalPvUsd, accuracy: 1,
                       "an unreachable stated year must not price into human capital")

        var inside = singleNumber()
        inside.adults[0].compYears = [IntakeCompYear(calendarYear: planYear + retireIn - 5, salaryUsd: 900_000, cashBonusUsd: 0)]
        XCTAssertGreaterThan(Engine.evaluate(inside.buildHousehold(asOf: asOf)).balanceSheet.assets.humanCapitalPvUsd,
                             Engine.evaluate(baseH).balanceSheet.assets.humanCapitalPvUsd + 1_000,
                             "fixture check: the same entry inside the working window must price in")
    }

    /// The wealth glide and the balance sheet are two copies of the same discounted-earnings
    /// model. At k = 0 they must be the same number — the shape this codebase keeps producing
    /// is one site updated and the other left reading `annualIncomeUsd`.
    func testGlideAndBalanceSheetPriceTheSameIncomePath() {
        let eval = Engine.evaluate(statedPath().buildHousehold(asOf: asOf))
        XCTAssertEqual(Engine.humanCapitalAtYear(eval.household, yearsFromNow: 0),
                       eval.balanceSheet.assets.humanCapitalPvUsd, accuracy: 1,
                       "the glide's human capital at k=0 must equal the balance sheet's")
        XCTAssertGreaterThan(eval.balanceSheet.assets.humanCapitalPvUsd, 0,
                             "fixture check: a zero PV would make the equality vacuous")
    }

    // MARK: - The savings cap, both directions

    /// Savings are capped at the SAME year's wages. With a stated path the cap follows the
    /// path, so a household saving more than this year's prorated income can book the full rate
    /// once the target arrives — and a household whose income steps down cannot.
    func testSavingsPvFollowsTheStatedPathInBothDirections() {
        var upModel = statedPath()
        upModel.annualSavingsUsd = 300_000          // above this year's 275k, below next year's 425k
        var flatModel = singleNumber()
        flatModel.annualSavingsUsd = 300_000
        var downModel = singleNumber()
        downModel.annualSavingsUsd = 300_000
        downModel.adults[0].compYears = [IntakeCompYear(calendarYear: planYear + 1, salaryUsd: 100_000, cashBonusUsd: 0)]

        let up = upModel.buildHousehold(asOf: asOf)
        let flat = flatModel.buildHousehold(asOf: asOf)
        let down = downModel.buildHousehold(asOf: asOf)

        XCTAssertEqual(min(up.annualSavingsUsd, Engine.wagesAtPlanYear(up, year: 1, asOf: asOf)), 300_000, accuracy: 0.5,
                       "with the target arriving, the full stated savings rate fits inside year 1's wages")
        XCTAssertEqual(min(flat.annualSavingsUsd, Engine.wagesAtPlanYear(flat, year: 1, asOf: asOf)), 275_000, accuracy: 0.5,
                       "fixture check: the single-number household is capped at 275k in year 1")

        let upPv = Engine.requiredReturn(up, asOf: asOf).futureSavingsPvUsd
        let flatPv = Engine.requiredReturn(flat, asOf: asOf).futureSavingsPvUsd
        let downPv = Engine.requiredReturn(down, asOf: asOf).futureSavingsPvUsd
        XCTAssertGreaterThan(upPv, flatPv + 1_000, "a rising stated path must raise the savings the wage cap admits")
        XCTAssertLessThan(downPv, flatPv - 1_000, "a falling stated path must lower it")
    }

    // MARK: - Cash and stock must not be counted twice

    /// Total compensation is cash wages PLUS what vests. Both terms must be non-zero and
    /// distinct in the fixture, or the equality would hold for a function that returned either
    /// one alone.
    func testTotalCompensationIsWagesPlusVestingAndNeitherAlone() {
        var m = statedPath()
        var g = IntakeRsuGrant()
        g.label = "26BSS"; g.employer = "BAC"; g.ticker = "BAC"
        g.unitsUnvested = 193; g.sharePriceUsd = 62.69
        g.vestDates = ["\(planYear + 1)-03-01"]; g.unitsByDate = [193]
        m.adults[0].grantWithholdingBps = 4178
        m.adults[0].rsuGrants = [g]
        let h = m.buildHousehold(asOf: asOf)

        let wages = Engine.wagesAtPlanYear(h, year: 1, asOf: asOf)
        let vest = Engine.vestingNetInYear(h, year: 1, asOf: asOf)
        let total = Engine.totalCompensationAtPlanYear(h, year: 1, asOf: asOf)
        XCTAssertGreaterThan(wages, 0, "fixture check: year 1 must pay cash")
        XCTAssertGreaterThan(vest, 0, "fixture check: year 1 must have a vest")
        XCTAssertEqual(total, wages + vest, accuracy: 0.5, "total compensation must be the sum of the two stores")
        XCTAssertNotEqual(total, wages, accuracy: 1_000, "total compensation must not be the cash term alone")
        XCTAssertNotEqual(total, vest, accuracy: 1_000, "total compensation must not be the vest term alone")

        // The vest is NOT inside the wage term — that is the double count the split prevents.
        XCTAssertEqual(wages, 425_000, accuracy: 0.5,
                       "the wage term must carry the stated CASH bonus only, with no vest folded in")
    }

    /// The overlap finding fires only when BOTH stores describe the same year, and is silent in
    /// each of the three mirror cases. A rule that fired on a schedule alone, or on vesting
    /// alone, would be noise on every client.
    func testVestOverlapFindingFiresOnlyWhenBothStoresAreLive() {
        func grant() -> IntakeRsuGrant {
            var g = IntakeRsuGrant()
            g.ticker = "BAC"; g.unitsUnvested = 193; g.sharePriceUsd = 62.69
            g.vestDates = ["\(planYear + 1)-03-01"]; g.unitsByDate = [193]
            return g
        }
        func fires(_ m: IntakeModel) -> Bool {
            Engine.evaluate(m.buildHousehold(asOf: asOf), asOf: asOf)
                .findings.contains { $0.ruleId == "comp_schedule_vest_overlap" }
        }

        var both = statedPath()
        both.adults[0].grantWithholdingBps = 4178
        both.adults[0].rsuGrants = [grant()]
        XCTAssertTrue(fires(both), "a stated cash bonus in the same year as a vest must be surfaced")

        var scheduleOnly = statedPath()
        scheduleOnly.adults[0].rsuGrants = []
        XCTAssertFalse(fires(scheduleOnly), "a stated path with no vesting must not raise an overlap")

        var vestOnly = singleNumber()
        vestOnly.adults[0].grantWithholdingBps = 4178
        vestOnly.adults[0].rsuGrants = [grant()]
        XCTAssertFalse(fires(vestOnly), "vesting with no stated path must not raise an overlap")

        var zeroBonus = statedPath()
        zeroBonus.adults[0].grantWithholdingBps = 4178
        zeroBonus.adults[0].rsuGrants = [grant()]
        zeroBonus.adults[0].compYears = zeroBonus.adults[0].compYears.map {
            var e = $0; e.cashBonusUsd = 0; e.salaryUsd = 225_000; return e
        }
        XCTAssertFalse(fires(zeroBonus), "a stated year with no cash bonus cannot be hiding a vest")

        var otherYear = statedPath()
        otherYear.adults[0].grantWithholdingBps = 4178
        var gLate = grant()
        gLate.vestDates = ["\(planYear + 7)-03-01"]
        otherYear.adults[0].rsuGrants = [gLate]
        XCTAssertFalse(fires(otherYear),
                       "a vest in a year with no STATED bonus must not raise an overlap; only the stated years are at risk")
    }

    // MARK: - Round trip

    /// The stated path must survive a save/load. A newly added key missing from older JSON must
    /// not fail the adult, and the new one must come back whole.
    func testStatedPathSurvivesEncodeDecode() throws {
        let m = statedPath()
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(IntakeModel.self, from: data)
        XCTAssertEqual(back.adults[0].compYears.map(\.calendarYear), [planYear, planYear + 1],
                       "the stated years must round-trip")
        XCTAssertEqual(back.adults[0].compYears.map(\.cashBonusUsd), [50_000, 200_000],
                       "the stated bonuses must round-trip")
        XCTAssertEqual(Engine.wagesAtPlanYear(back.buildHousehold(asOf: asOf), year: 1, asOf: asOf), 425_000, accuracy: 0.5,
                       "a reloaded file must pay the same year-1 wages")
    }
}
