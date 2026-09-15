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
    ///
    /// Asserted as an EQUALITY against the deceased's exact benefit. The first version
    /// asserted only `> 0`, which the reverted code also satisfied — it reverted clean with
    /// the whole suite green, making it the seventh test here that could not detect its own
    /// subject's absence.
    func testASurvivorIsPaidBeforeReachingTheirOwnClaimingAge() {
        // Ada is 68 and already claiming (claimed at 62); she dies at 70, plan-year 2.
        // Ben is 64 and does not claim until 70, plan-year 7. Years 3-6 are the gap.
        let h = couple(claimAges: (62, 70), benefits: (3_000, 4_000), longevity: (70, 95))
        let adasBenefit = 3_000.0 * 12 * (1 - 0.06 * 5)      // claimed five years before FRA
        for t in 3...6 {
            XCTAssertEqual(Engine.socialSecurityAnnual(h, year: t, asOf: asOf), adasBenefit, accuracy: 1,
                           "year \(t): a widower with no benefit of his own yet must still receive hers")
        }
        XCTAssertEqual(Engine.socialSecurityAnnual(h, year: 8, asOf: asOf),
                       4_000.0 * 12 * (1 + 0.08 * 3), accuracy: 1,
                       "and his own, larger benefit takes over once it begins")
    }

    /// A survivor under 60 is not yet eligible for a widow(er)'s benefit and keeps only their
    /// own record — the max rule has to stop somewhere.
    func testASurvivorUnderSixtyKeepsOnlyTheirOwnRecord() {
        var m = IntakeModel()
        var old = IntakeAdult(); old.name = "Old"; old.birthYear = 1958; old.retirementAge = 62
        old.salaryUsd = 0; old.socialSecurityMonthlyUsd = 4_000; old.ssClaimAge = 67
        var young = IntakeAdult(); young.name = "Young"; young.birthYear = 1985; young.retirementAge = 65
        young.salaryUsd = 120_000; young.socialSecurityMonthlyUsd = 0; young.ssClaimAge = 67
        m.adults = [old, young]; m.taxableUsd = 900_000; m.retirementSpendingUsd = 120_000
        var h = m.buildHousehold()
        h.people = h.people.map { p in
            var q = p
            if q.role == .primary { q.longevityPercentileTarget = 72 }
            if q.role == .spouse  { q.longevityPercentileTarget = 95 }
            return q
        }
        XCTAssertEqual(Engine.socialSecurityAnnual(h, year: 6, asOf: asOf), 0, accuracy: 1,
                       "a widow in her forties is not yet eligible for a widow's benefit")
        XCTAssertGreaterThan(Engine.socialSecurityAnnual(h, year: 20, asOf: asOf), 0,
                             "and receives one once she reaches 60")
    }

    /// A living client whose longevity ESTIMATE is already behind them must still be paid.
    /// An unfloored death year made `firstDeath` negative, so every plan year fell into the
    /// survivor branch with nobody "alive" — zeroing Social Security for the entire plan for
    /// an 85-year-old in poor health and moving the required real return 402 bps.
    func testAClientPastTheirLongevityEstimateStillCollects() {
        var m = IntakeModel()
        var a = IntakeAdult(); a.birthYear = 1941; a.retirementAge = 62      // 85 at the plan date
        a.salaryUsd = 0; a.socialSecurityMonthlyUsd = 3_000; a.ssClaimAge = 62
        a.health = .poor
        m.adults = [a]; m.taxableUsd = 800_000; m.retirementSpendingUsd = 90_000
        let h = m.buildHousehold()
        XCTAssertLessThan(h.people[0].longevityPercentileTarget, 85, "fixture check: the estimate is behind them")
        XCTAssertGreaterThan(Engine.socialSecurityAnnual(h, year: 1, asOf: asOf), 0,
                             "a living client on the roster cannot be treated as already deceased")
        XCTAssertGreaterThan(Engine.socialSecurityAnnual(h, year: 5, asOf: asOf), 0)
    }

    /// The death-year FLOOR matters for a COUPLE, not a single filer — the single-filer path
    /// returns before consulting it at all, which is why the first test written for this
    /// reverted clean. Both adults are on the roster, so both are alive on the plan date;
    /// leaving the year unfloored made an adult already past their longevity estimate read as
    /// dead from plan-year zero, so the household stepped straight down to one benefit
    /// instead of collecting both.
    func testACoupleBothAliveCollectBothBenefitsEvenPastAnEstimate() {
        var m = IntakeModel()
        var old = IntakeAdult(); old.name = "Old"; old.birthYear = 1941; old.retirementAge = 62
        old.salaryUsd = 0; old.socialSecurityMonthlyUsd = 4_000; old.ssClaimAge = 62
        old.health = .poor                                   // longevity target already behind them
        var young = IntakeAdult(); young.name = "Young"; young.birthYear = 1950; young.retirementAge = 62
        young.salaryUsd = 0; young.socialSecurityMonthlyUsd = 2_000; young.ssClaimAge = 62
        m.adults = [old, young]; m.taxableUsd = 900_000; m.retirementSpendingUsd = 120_000
        let h = m.buildHousehold()

        let oldest = h.people.first { $0.role == .primary }!
        XCTAssertLessThan(oldest.longevityPercentileTarget,
                          Engine.age(birthDate: oldest.birthDate, asOf: asOf),
                          "fixture check: the estimate is already behind them")

        // Both claimed at 62, five years before FRA, so both are collecting now.
        let both = (4_000.0 + 2_000.0) * 12 * (1 - 0.06 * 5)
        XCTAssertEqual(Engine.socialSecurityAnnual(h, year: 0, asOf: asOf), both, accuracy: 1,
                       "two living people on the roster collect two benefits")
        XCTAssertEqual(Engine.socialSecurityAnnual(h, year: 1, asOf: asOf), both, accuracy: 1)
    }

    /// A single filer has no survivor economics and collects for the WHOLE plan.
    ///
    /// The longevity target drives the survivor step-down; it is not a stop on income. Gating
    /// income on it modelled a household that is dead for income and alive for spending — on
    /// a default configuration (poor health, plan to 92) that deleted about $288,000 of
    /// benefit while the projection kept showing $120,000/yr of spending against it.
    func testASingleFilerCollectsForTheWholePlan() {
        var m = IntakeModel()
        var a = IntakeAdult(); a.birthYear = 1958; a.retirementAge = 62
        a.salaryUsd = 0; a.socialSecurityMonthlyUsd = 3_000; a.ssClaimAge = 67
        m.adults = [a]; m.taxableUsd = 800_000; m.retirementSpendingUsd = 90_000
        var h = m.buildHousehold()
        h.people = h.people.map { p in var q = p; q.longevityPercentileTarget = 80; return q }
        XCTAssertEqual(Engine.socialSecurityAnnual(h, year: 12, asOf: asOf), 36_000, accuracy: 1)
        XCTAssertEqual(Engine.socialSecurityAnnual(h, year: 25, asOf: asOf), 36_000, accuracy: 1,
                       "income must not stop at a longevity ESTIMATE while the spending it funds runs on")
    }
}
