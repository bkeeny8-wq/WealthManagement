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

    /// A household cannot be made to report a funded ratio that assumes income it does not
    /// earn. Held as a comparison so it needs no threshold: shortening the primary's career
    /// is unambiguously worse — fewer earning years, more drawing years — so the funded
    /// ratio must fall. Under the split it ROSE, because the spending schedule stayed put
    /// while the wages retreated.
    func testRetiringEarlierCannotImproveTheFundedRatio() {
        let ratios = [70, 65, 62, 58, 55].map { single(adultRetiresAt: $0).buildHousehold() }
            .map { Engine.evaluate($0).balanceSheet.fundedRatioBps }
        XCTAssertEqual(ratios, ratios.sorted(by: >),
            "retiring earlier improved the funded ratio (got \(ratios))")
        XCTAssertGreaterThan(ratios.first! - ratios.last!, 100,
            "fixture check: retiring fifteen years earlier barely moved the funded ratio — the comparison has no signal")
    }

    /// A plan saved before the collapse carries the old household-level key, and it is the
    /// one that drove the schedule the client was shown. It has to survive the round trip
    /// and pull the wage window onto itself, not be silently dropped in favour of a
    /// per-adult age the client may never have touched.
    func testALegacyPlanWithTwoDisagreeingAgesCollapsesOntoTheSpendingStart() throws {
        let json = """
        {"adults":[{"birthYear":\(Engine.year(Engine.planningAsOf) - 55),"retirementAge":58,"salaryUsd":300000}],
         "retirementStartAge":65,"planToAge":92,"taxableUsd":2500000,"retirementSpendingUsd":200000}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(IntakeModel.self, from: json)
        XCTAssertEqual(m.retirementStartAge, 65, "the saved spending start was dropped")
        XCTAssertEqual(m.adults[0].retirementAge, 65, "the wage window did not follow the saved spending start")

        // And the plan it builds is coherent, which the saved one was not.
        let h = m.buildHousehold()
        let firstDraw = h.goals.filter { $0.kind == .spending }
            .flatMap(\.outflows).filter { $0.amountUsd > 0 }.map(\.year).min()
        let lastWage = (1...40).filter { Engine.wagesAtPlanYear(h, year: $0, asOf: Engine.planningAsOf) > 0 }.max() ?? 0
        XCTAssertEqual(lastWage + 1, firstDraw, "the migrated plan still has a gap between the last wage and the first draw")
    }
}
