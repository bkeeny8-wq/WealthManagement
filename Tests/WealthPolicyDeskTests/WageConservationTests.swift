import XCTest
@testable import WealthPolicyDesk

/// The projection frame starts at the PRIMARY's retirement, so a younger spouse is often
/// still earning. Modelling those overlap years used to be asymmetric in a way that
/// inverted the plan: the wages were added to taxable income and taxed, the tax was
/// debited from the portfolio, and the cash itself was credited nowhere. Sweeping the
/// sample's spouse salary $0 → $200k → $400k made the required return WORSE at every step.
///
/// The fix is one shared wage term (`Engine.wagesAtPlanYear`) plus one principle: wages
/// meet the year's spending, then the year's tax, and what is left is saved at the rate
/// the household reports. These tests lock the principle, the shared term, and the
/// plumbing that carries it into the required-return recursion.
final class WageConservationTests: XCTestCase {

    private let asOf = Engine.planningAsOf

    // MARK: - The shared wage term

    /// Robert (b. 1963, retires at 65) and Susan (b. 1965, retires at 64) are 63 and 61 as
    /// of the pinned date, so both earn through plan-year 1, Susan alone earns in year 2,
    /// and nobody earns from year 3. An unfiltered `humanCapital` sum reports $470,000 for
    /// all of them.
    func testWagesStopTheYearAnAdultReachesTheirRetirementAge() {
        let h = Seed.sampleHousehold
        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: 0, asOf: asOf), 470_000, accuracy: 0.5)
        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: 1, asOf: asOf), 470_000, accuracy: 0.5)
        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: 2, asOf: asOf), 160_000, accuracy: 0.5,
                       "Robert has retired; Susan works one more year")
        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: 3, asOf: asOf), 0, accuracy: 0.5,
                       "both retired — a plan year with no earner must report no wages")
        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: 30, asOf: asOf), 0, accuracy: 0.5)
    }

    /// A dependent's income is not household earning capacity for this purpose, and used to
    /// be summed straight into the realized-gain preview's stacking base.
    func testDependentEarningsAreNotHouseholdWages() {
        var h = Seed.sampleHousehold
        let kid = Person(id: "p_kid", label: "Kid", birthDate: "2004-01-01", role: .dependent,
                         expectedRetirementAge: 65, healthStatus: .good, longevityPercentileTarget: 90)
        h.people.append(kid)
        h.humanCapital.append(HumanCapital(personId: "p_kid", baseSalaryUsd: 500_000, expectedBonusUsd: 0,
                                           bonusVolatilityBps: 0, character: .equityLike, impliedBeta: 1,
                                           sector: nil, yearsRemaining: 40, realGrowthRateBps: 0,
                                           jobLossInDrawdownProbabilityBps: 0))
        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: 0, asOf: asOf), 470_000, accuracy: 0.5,
                       "a $500,000-earning dependent must not enter household wages")
    }

    // MARK: - The inversion itself

    /// The headline defect: a household must not be reported as worse off for earning more.
    func testEarningMoreNeverDegradesThePlan() {
        func rr(spouseSalary: Usd) -> Bps {
            var h = Seed.sampleHousehold
            h.humanCapital = h.humanCapital.map {
                var c = $0
                if c.personId == "p_susan" { c.baseSalaryUsd = spouseSalary; c.expectedBonusUsd = 0 }
                return c
            }
            return Engine.evaluate(h).requiredReturn.requiredRealReturnBps
        }
        let none = rr(spouseSalary: 0), some = rr(spouseSalary: 200_000), lots = rr(spouseSalary: 400_000)
        XCTAssertLessThan(some, none, "a working spouse must improve the plan, not worsen it")
        XCTAssertLessThanOrEqual(lots, some, "and earning still more must never reverse that")
    }

    // MARK: - Cash conservation inside the projection

    /// A working year with no spending obligation must ADD to the portfolio. The old model
    /// taxed that year's $160,000 and credited nothing, so the balance fell.
    func testAWorkingYearWithNoSpendingGrowsThePortfolio() {
        let e = Engine.evaluate(Seed.sampleHousehold)
        guard let overlap = e.decumulation.baseline.years.first(where: { $0.wagesUsd > 0 }) else {
            return XCTFail("the sample has an overlap year by construction")
        }
        XCTAssertEqual(overlap.spendingNeedUsd, 0, accuracy: 0.5, "fixture check: nothing to fund that year")
        XCTAssertGreaterThan(overlap.federalTaxUsd, 0, "fixture check: those wages are taxed")
        XCTAssertEqual(overlap.portfolioTaxUsd, 0, accuracy: 0.5,
                       "a working year settles its own tax from wages before touching the portfolio")
    }

    /// The wage column has to exist and be reported, or the Decumulation tab shows a year
    /// with a large federal tax and no stated source of income.
    func testTheProjectionReportsTheWagesItTaxed() {
        let e = Engine.evaluate(Seed.sampleHousehold)
        guard let overlap = e.decumulation.baseline.years.first(where: { $0.age == 65 }) else {
            return XCTFail("expected an age-65 row")
        }
        XCTAssertEqual(overlap.wagesUsd, 160_000, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(overlap.ordinaryIncomeUsd, overlap.wagesUsd,
                                    "wages are ordinary income and must be inside the reported total")
    }

    /// A retired year has no wages to pay from, so the portfolio pays the whole bill —
    /// the wage offset must not leak into years nobody is working.
    func testARetiredYearPaysItsFullTaxFromThePortfolio() {
        let e = Engine.evaluate(Seed.sampleHousehold)
        let retired = e.decumulation.baseline.years.filter { $0.wagesUsd == 0 && $0.federalTaxUsd > 0 }
        XCTAssertFalse(retired.isEmpty, "fixture check: the plan reaches taxed retirement years")
        for y in retired {
            XCTAssertEqual(y.portfolioTaxUsd, y.federalTaxUsd + y.irmaaUsd, accuracy: 0.5,
                           "age \(y.age): no wages exist to absorb this tax")
        }
    }

    // MARK: - The plumbing that carries it

    /// `portfolioTaxUsd` is computed on a pass that does NOT debit balances — the first of
    /// the two required-return passes runs with `debitTax: false` purely to build the tax
    /// series. Computing it inside the debit branch fed the second pass an all-zero series,
    /// which silently collapsed the after-tax solve back onto the pre-tax one with no test
    /// failing. The two figures differing is the guard.
    func testTheAfterTaxSolveActuallyReceivesATaxSeries() {
        let rr = Engine.evaluate(Seed.sampleHousehold).requiredReturn
        XCTAssertGreaterThan(rr.requiredRealReturnBps, rr.requiredRealReturnPreTaxBps,
                             "the after-tax required return must exceed the pre-tax one; equality means the tax series arrived empty")
    }

    /// Savings can only come out of wages. `householdSaveYears` runs to the LATER
    /// retirement, so it books a savings inflow in a plan year where nobody earns.
    func testSavingsAreNeverCreditedInAYearWithNoWages() {
        let h = Seed.sampleHousehold
        let saveYears = Engine.householdSaveYears(h, asOf: asOf)
        XCTAssertEqual(saveYears, 3, "fixture check: the savings window runs one year past the last wage")
        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: saveYears, asOf: asOf), 0, accuracy: 0.5,
                       "the last 'saving' year has no earner, so its savings inflow must be capped away")
    }

    /// The funded-ratio savings PV must use the same wage cap as the required-return solve.
    /// A typed savings rate above wages used to inflate how-funded-am-I without helping rr.
    func testFundedRatioSavingsPvIsWageCapped() {
        var h = Seed.sampleHousehold
        h.annualSavingsUsd = 10_000_000
        let rr = Engine.requiredReturn(h, asOf: asOf)
        var wagePv: Usd = 0
        let saveYears = Engine.householdSaveYears(h, asOf: asOf)
        for t in 1...saveYears {
            let cap = min(h.annualSavingsUsd, Engine.wagesAtPlanYear(h, year: t, asOf: asOf))
            wagePv += cap / pow(1 + Engine.safeRealRate, Double(t))
        }
        XCTAssertEqual(rr.futureSavingsPvUsd, wagePv, accuracy: 0.5)
        XCTAssertLessThan(rr.futureSavingsPvUsd, 10_000_000 / 1.015,
                          "heroic savings cannot be credited above the wages that fund them")
    }

    /// And the Harrisons' own PV must skip plan-year 3, where nobody earns.
    func testHarrisonsSavingsPvSkipsTheZeroWageYear() {
        let h = Seed.sampleHousehold
        let rr = Engine.requiredReturn(h, asOf: asOf)
        let expected = (1...2).reduce(0.0) { acc, t in
            acc + min(h.annualSavingsUsd, Engine.wagesAtPlanYear(h, year: t, asOf: asOf))
                / pow(1 + Engine.safeRealRate, Double(t))
        }
        XCTAssertEqual(rr.futureSavingsPvUsd, expected, accuracy: 0.5)
    }

    // MARK: - The preview agrees with the projection

    /// `currentOrdinaryIncome` documents itself as mirroring the projection's year-0 build.
    /// It summed every `humanCapital` row instead, so a fully retired household's sell
    /// preview stacked gains on $470,000 of phantom wages.
    func testRetiredHouseholdsSellPreviewSeesNoWages() {
        var h = Seed.sampleHousehold
        h.people = h.people.map { var p = $0; p.expectedRetirementAge = 40; return p }   // everyone retired
        let income = Engine.currentOrdinaryIncome(h, asOf: asOf, capGains: 0)
        XCTAssertEqual(income.gross, 0, accuracy: 0.5,
                       "a retired household has no wages to stack a realized gain on")
        let working = Engine.currentOrdinaryIncome(Seed.sampleHousehold, asOf: asOf, capGains: 0)
        XCTAssertEqual(working.gross, 470_000, accuracy: 0.5, "and a working one still reports its wages")
    }

    /// The MAGI estimate behind the SALT/itemization analysis uses the same rule.
    func testEstimatedMagiUsesTheRetirementGatedWage() {
        var h = Seed.sampleHousehold
        h.people = h.people.map { var p = $0; p.expectedRetirementAge = 40; return p }
        XCTAssertLessThan(Engine.estimatedMagi(h, asOf: asOf), 470_000,
                          "a retired household's MAGI is its draw, not the salary it no longer earns")
    }
}
