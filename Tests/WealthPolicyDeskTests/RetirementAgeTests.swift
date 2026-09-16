import XCTest
@testable import WealthPolicyDesk

/// The plan has ONE retirement age. It used to have two.
///
/// `IntakeAdult.retirementAge` drove the wage and saving window (human capital,
/// `householdSaveYears`, the decumulation feeder); a separate household-level
/// `IntakeModel.retirementStartAge` drove the spending schedule. Two wheels, in two
/// different steps of the form, both reading "retire at age" — and every combination
/// produced a plan the engine could not fault:
///
///   • wages stopping at 58 with spending starting at 65 left SEVEN YEARS funded by
///     nothing at all, and still reported the household 67% funded;
///   • the mirror ran seven years of phantom salary against the draw and read 78 bps
///     easier than the truth.
///
/// `Household.withDriverOverrides` had already settled this for the what-if slider — it
/// moves the person record and the spending schedule together, "otherwise
/// saveYears/human-capital would extend past a spending start that didn't move" — but the
/// intake path every client is actually onboarded through could still split them.
final class RetirementAgeTests: XCTestCase {

    private func single(adultRetiresAt: Int, salary: Usd = 300_000) -> IntakeModel {
        var m = IntakeModel()
        m.adults = [{ var a = IntakeAdult(); a.birthYear = Engine.year(Engine.planningAsOf) - 55
                      a.retirementAge = adultRetiresAt; a.salaryUsd = salary; return a }()]
        m.planToAge = 92; m.taxableUsd = 2_500_000
        m.retirementSpendingUsd = 200_000; m.annualSavingsUsd = 60_000
        return m
    }

    /// Setting either name moves both. This is the whole fix: there is no pair of values
    /// that can disagree, so no ordering of the two wheels can produce a split plan.
    func testTheTwoRetirementAgesAreOneValue() {
        var m = single(adultRetiresAt: 62)
        XCTAssertEqual(m.retirementStartAge, 62, "the household age must read the primary's")
        m.retirementStartAge = 58
        XCTAssertEqual(m.adults[0].retirementAge, 58, "writing the household age must move the primary's")
        m.adults[0].retirementAge = 70
        XCTAssertEqual(m.retirementStartAge, 70, "writing the primary's must move the household age")
    }

    /// The property that the split actually violated, asserted on the built household
    /// rather than on the intake fields: the last year the household earns a wage and the
    /// first year it draws must MEET. No unfunded gap, no overlap of salary and drawdown.
    func testWagesAndTheFirstDrawMeetWithNoGapAndNoOverlap() {
        for age in [55, 58, 62, 65, 70] {
            let h = single(adultRetiresAt: age).buildHousehold()
            let asOf = Engine.planningAsOf
            let horizon = max(1, h.goals.compactMap { $0.horizonYears }.max() ?? 30)
            let wageYears = (1...horizon).filter { Engine.wagesAtPlanYear(h, year: $0, asOf: asOf) > 0 }
            guard let firstDraw = h.goals.filter({ $0.kind == .spending })
                .flatMap(\.outflows).filter({ $0.amountUsd > 0 }).map(\.year).min() else {
                return XCTFail("retire at \(age): the plan has no spending outflow to anchor on")
            }
            let lastWage = wageYears.max() ?? 0
            XCTAssertEqual(lastWage + 1, firstDraw,
                "retire at \(age): wages run through plan year \(lastWage) and the first draw is year "
                + "\(firstDraw) — \(firstDraw - lastWage - 1) year(s) funded by nothing, or salary and "
                + "drawdown overlapping")
        }
    }

    /// And on every household in the matrix, whatever shape it has.
    func testEveryMatrixHouseholdDrawsWhenItsPrimaryRetires() {
        for c in HouseholdMatrix.built {
            let h = c.household
            guard let p = h.primary else { continue }
            let primaryAge = Engine.age(birthDate: p.birthDate, asOf: Engine.planningAsOf)
            guard let firstDraw = h.goals.filter({ $0.kind == .spending })
                .flatMap(\.outflows).filter({ $0.amountUsd > 0 }).map(\.year).min() else { continue }
            XCTAssertEqual(firstDraw, max(1, p.expectedRetirementAge - primaryAge),
                "\(c.name): the plan starts drawing in year \(firstDraw), but its primary retires at "
                + "\(p.expectedRetirementAge) (age \(primaryAge) today)")
        }
    }

    /// Economic sanity, not evidence about the collapse. Shortening the primary's career is
    /// unambiguously worse — fewer earning years, more drawing years — so the funded ratio must
    /// fall, monotonically, with no threshold needed.
    ///
    /// The docstring used to claim this caught the split ("under the split it ROSE"). It does
    /// not, and cannot: the fixture sets the age through `retirementStartAge`, which under the
    /// split leaves the household-level field at its 65 default for every arm, so the only thing
    /// varying is the wage window and the ratio falls either way. The split is covered by
    /// `testTheTwoRetirementAgesAreOneValue` and
    /// `testWagesAndTheFirstDrawMeetWithNoGapAndNoOverlap`, which do go red when it is restored.
    func testRetiringEarlierCannotImproveTheFundedRatio() {
        let ratios = [70, 65, 62, 58, 55].map { single(adultRetiresAt: $0).buildHousehold() }
            .map { Engine.evaluate($0).balanceSheet.fundedRatioBps }
        XCTAssertEqual(ratios, ratios.sorted(by: >),
            "retiring earlier improved the funded ratio (got \(ratios))")
        XCTAssertGreaterThan(ratios.first! - ratios.last!, 100,
            "fixture check: retiring fifteen years earlier barely moved the funded ratio — the comparison has no signal")
    }

    /// Migrating a plan saved before the collapse. BOTH old fields were stored with a
    /// synthesized encoder and BOTH defaulted to 65, so every legacy save carries a
    /// household-level age whether or not the client ever opened that wheel. Letting it win
    /// unconditionally let an untouched default overwrite a deliberately entered people-step
    /// age — and in the flattering direction, handing the plan seven phantom earning years.
    ///
    /// Differing from the default is the only evidence available about which field the client
    /// actually set, so that is what decides. All four combinations are asserted; a rule that
    /// picks a side unconditionally fails two of them.
    func testALegacyPlanMigratesOntoWhicheverAgeTheClientActuallySet() throws {
        let born = Engine.year(Engine.planningAsOf) - 55
        func migrate(perAdult: Int, household: Int) throws -> IntakeModel {
            let json = """
            {"adults":[{"birthYear":\(born),"retirementAge":\(perAdult),"salaryUsd":300000}],
             "retirementStartAge":\(household),"planToAge":92,"taxableUsd":2500000,"retirementSpendingUsd":200000}
            """.data(using: .utf8)!
            return try JSONDecoder().decode(IntakeModel.self, from: json)
        }
        let d = IntakeModel.legacyDefaultRetirementAge
        XCTAssertEqual(d, 65, "fixture check: the migration reasons about this default")

        // Only the people step was touched — the household age is the untouched default.
        XCTAssertEqual(try migrate(perAdult: 58, household: d).retirementStartAge, 58,
            "an untouched default overwrote the age the client entered in the people step")
        // Only the goals step was touched.
        XCTAssertEqual(try migrate(perAdult: d, household: 70).retirementStartAge, 70,
            "an untouched default overwrote the age the client entered in the goals step")
        // Both touched and disagreeing — the real defect. The age that drove the spending
        // schedule the client was shown wins.
        XCTAssertEqual(try migrate(perAdult: 58, household: 70).retirementStartAge, 70,
            "a plan whose two ages genuinely disagreed did not resolve onto its spending start")
        // Neither touched.
        XCTAssertEqual(try migrate(perAdult: d, household: d).retirementStartAge, d)
    }

    /// And whichever age wins, the migrated plan is COHERENT — which the saved one was not.
    func testAMigratedPlanHasNoGapBetweenItsLastWageAndItsFirstDraw() throws {
        let born = Engine.year(Engine.planningAsOf) - 55
        for (perAdult, household) in [(58, 65), (65, 70), (58, 70), (65, 65)] {
            let json = """
            {"adults":[{"birthYear":\(born),"retirementAge":\(perAdult),"salaryUsd":300000}],
             "retirementStartAge":\(household),"planToAge":92,"taxableUsd":2500000,"retirementSpendingUsd":200000}
            """.data(using: .utf8)!
            let h = try JSONDecoder().decode(IntakeModel.self, from: json).buildHousehold()
            let firstDraw = h.goals.filter { $0.kind == .spending }
                .flatMap(\.outflows).filter { $0.amountUsd > 0 }.map(\.year).min()
            let lastWage = (1...40).filter { Engine.wagesAtPlanYear(h, year: $0, asOf: Engine.planningAsOf) > 0 }.max() ?? 0
            XCTAssertEqual(lastWage + 1, firstDraw,
                "legacy (\(perAdult), \(household)) migrated to a plan with a gap between the last wage and the first draw")
        }
    }
}
