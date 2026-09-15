import XCTest
@testable import WealthPolicyDesk

/// `socialSecurityAnnual` produced three of one verification round's high findings on its
/// own. It mixed two concerns — what one PERSON is entitled to, and how a HOUSEHOLD
/// aggregates that across a death — and gated the two components of an entitlement in two
/// different places: the top-up checked its own start date while the own benefit was gated by
/// an external "who is claiming" filter. Every defect came out of that seam.
///
/// It is now one type that gates itself and two aggregation rules. These tests pin both
/// halves separately, so a future change to one cannot quietly alter the other.
final class SocialSecurityStructureTests: XCTestCase {

    private let asOf = Engine.planningAsOf

    // MARK: - The entitlement gates itself

    func testEachComponentBeginsOnItsOwnSchedule() {
        let e = Engine.SocialSecurityEntitlement(
            ownAnnualUsd: 20_000, ownStartYear: 2,
            topUpAnnualUsd: 5_000, topUpStartYear: 6, deathYear: 30)
        XCTAssertEqual(e.amount(inYear: 1), 0, accuracy: 0.5, "nothing before either starts")
        XCTAssertEqual(e.amount(inYear: 2), 20_000, accuracy: 0.5, "own benefit alone")
        XCTAssertEqual(e.amount(inYear: 5), 20_000, accuracy: 0.5, "still waiting on the worker")
        XCTAssertEqual(e.amount(inYear: 6), 25_000, accuracy: 0.5, "top-up joins it")
    }

    /// The defect this shape prevents: clamping the whole entitlement to the top-up's start
    /// deleted the spouse's own earned benefit for every year before the worker filed.
    func testTheOwnBenefitIsNeverHeldBackByTheTopUp() {
        let e = Engine.SocialSecurityEntitlement(
            ownAnnualUsd: 12_000, ownStartYear: 0,
            topUpAnnualUsd: 8_000, topUpStartYear: 9, deathYear: 30)
        for t in 0...8 {
            XCTAssertEqual(e.amount(inYear: t), 12_000, accuracy: 0.5,
                           "year \(t): the spouse's own record pays from their own claim age")
        }
    }

    // MARK: - Household aggregation, in isolation

    private func couple(claimAges: (Int, Int), benefits: (Usd, Usd),
                        longevity: (Int, Int) = (95, 95)) -> Household {
        var m = IntakeModel()
        var a = IntakeAdult(); a.name = "Ada"; a.birthYear = 1958; a.retirementAge = 62
        a.salaryUsd = 0; a.socialSecurityMonthlyUsd = benefits.0; a.ssClaimAge = claimAges.0
        var b = IntakeAdult(); b.name = "Ben"; b.birthYear = 1962; b.retirementAge = 62
        b.salaryUsd = 0; b.socialSecurityMonthlyUsd = benefits.1; b.ssClaimAge = claimAges.1
        m.adults = [a, b]; m.taxableUsd = 900_000; m.retirementSpendingUsd = 120_000
        var h = m.buildHousehold()
        h.people = h.people.map { p in
            var q = p
            if q.role == .primary { q.longevityPercentileTarget = longevity.0 }
            if q.role == .spouse  { q.longevityPercentileTarget = longevity.1 }
            return q
        }
        return h
    }

    /// While both are alive, the household collects both.
    func testBothBenefitsAreCollectedWhileBothAreAlive() {
        let h = couple(claimAges: (67, 67), benefits: (4_000, 3_000))
        let total = Engine.socialSecurityAnnual(h, year: 6, asOf: asOf)
        XCTAssertEqual(total, (4_000 + 3_000) * 12, accuracy: 1)
    }

    /// From the first death the survivor keeps only the greater — the income cliff.
    func testTheSurvivorKeepsOnlyTheGreaterBenefit() {
        // Ada is 68 at the plan date and dies at 80 (plan-year 12); Ben is 64 and claims at
        // 67 (plan-year 4). So both are collecting and alive from year 4 to year 12.
        let h = couple(claimAges: (67, 67), benefits: (4_000, 3_000), longevity: (80, 95))
        let before = Engine.socialSecurityAnnual(h, year: 6, asOf: asOf)
        let after  = Engine.socialSecurityAnnual(h, year: 20, asOf: asOf)
        XCTAssertEqual(before, 84_000, accuracy: 1)
        XCTAssertEqual(after, 48_000, accuracy: 1, "the survivor keeps the larger of the two, not the sum")
    }

    /// A widow(er) receives the survivor benefit in the GAP before their own claiming age.
    /// The old "who is claiming" filter dropped the deceased's record and the survivor had
    /// not started, so the household collected nothing at all in those years.
    func testASurvivorIsPaidBeforeReachingTheirOwnClaimingAge() {
        let h = couple(claimAges: (62, 70), benefits: (3_000, 4_000), longevity: (70, 95))
        // Ada claims at 62 and dies at 70; Ben does not claim until 70, four years later.
        let inTheGap = Engine.socialSecurityAnnual(h, year: 8, asOf: asOf)
        XCTAssertGreaterThan(inTheGap, 0,
                             "a widower with no benefit of his own yet still receives hers")
    }

    /// A single filer collects to their own death and nothing after it.
    func testASingleFilerCollectsUntilTheirOwnDeath() {
        var m = IntakeModel()
        var a = IntakeAdult(); a.birthYear = 1958; a.retirementAge = 62
        a.salaryUsd = 0; a.socialSecurityMonthlyUsd = 3_000; a.ssClaimAge = 67
        m.adults = [a]; m.taxableUsd = 800_000; m.retirementSpendingUsd = 90_000
        var h = m.buildHousehold()
        h.people = h.people.map { p in var q = p; q.longevityPercentileTarget = 80; return q }
        XCTAssertEqual(Engine.socialSecurityAnnual(h, year: 12, asOf: asOf), 36_000, accuracy: 1)
        XCTAssertEqual(Engine.socialSecurityAnnual(h, year: 25, asOf: asOf), 0, accuracy: 1,
                       "nothing is paid after the only claimant has died")
    }
}
