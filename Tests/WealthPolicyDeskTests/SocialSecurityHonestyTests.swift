import XCTest
@testable import WealthPolicyDesk

/// Social Security is guaranteed income, so it flows straight into the funded ratio and the
/// required return. The model derived it from salary with a rough bend-point approximation
/// and presented the result as the client's benefit — a guess shown as fact, for a number
/// the client is holding a statement of. Claiming age was one household-wide value, which
/// cannot express a couple claiming years apart to maximise the survivor benefit.
final class SocialSecurityHonestyTests: XCTestCase {

    private func couple(entered: (Usd, Usd) = (0, 0), claimAges: (Int, Int) = (0, 0)) -> IntakeModel {
        var m = IntakeModel()
        var a = IntakeAdult(); a.name = "Ada"; a.birthYear = 1965; a.retirementAge = 65
        a.salaryUsd = 250_000; a.socialSecurityMonthlyUsd = entered.0; a.ssClaimAge = claimAges.0
        var b = IntakeAdult(); b.name = "Ben"; b.birthYear = 1967; b.retirementAge = 65
        b.salaryUsd = 90_000; b.socialSecurityMonthlyUsd = entered.1; b.ssClaimAge = claimAges.1
        m.adults = [a, b]
        m.ssClaimAge = 67
        // A real portfolio and a real spending goal: an empty plan is degenerate and would
        // not move at all, which would make this suite pass for the wrong reason.
        m.adults[0].traditionalUsd = 900_000
        m.adults[1].traditionalUsd = 400_000
        m.taxableUsd = 1_100_000
        m.retirementSpendingUsd = 180_000
        m.annualSavingsUsd = 60_000
        return m
    }

    private func profile(_ m: IntakeModel, _ personId: String) -> SocialSecurityProfile? {
        m.buildHousehold().socialSecurity.first { $0.personId == personId }
    }

    /// The entered figure must win over the estimate — that is the whole point.
    func testAnEnteredBenefitBeatsTheSalaryEstimate() {
        let estimated = profile(couple(), "p_0")?.estimatedPIAUsd ?? 0
        XCTAssertGreaterThan(estimated, 0, "fixture check: the estimate is non-zero")

        let entered = profile(couple(entered: (4_100, 2_300)), "p_0")?.estimatedPIAUsd ?? 0
        XCTAssertEqual(entered, 4_100, accuracy: 0.5, "the SSA statement figure must be used verbatim")
        XCTAssertNotEqual(entered, estimated, accuracy: 0.5)
    }

    /// Each adult's own figure is used — not the primary's applied to both.
    func testEachAdultGetsTheirOwnBenefit() {
        let m = couple(entered: (4_100, 2_300))
        XCTAssertEqual(profile(m, "p_0")?.estimatedPIAUsd ?? 0, 4_100, accuracy: 0.5)
        XCTAssertEqual(profile(m, "p_1")?.estimatedPIAUsd ?? 0, 2_300, accuracy: 0.5)
    }

    /// A blank benefit still estimates, so nothing already saved changes.
    func testABlankBenefitStillFallsBackToTheEstimate() {
        let m = couple(entered: (4_100, 0))
        XCTAssertEqual(profile(m, "p_0")?.estimatedPIAUsd ?? 0, 4_100, accuracy: 0.5)
        XCTAssertEqual(profile(m, "p_1")?.estimatedPIAUsd ?? 0,
                       IntakeModel.estimatedMonthlyPIA(90_000), accuracy: 0.5,
                       "an unanswered benefit falls back to the estimate, exactly as before")
    }

    /// And the form must be able to SAY it is guessing.
    func testTheModelKnowsWhenItIsStillGuessing() {
        XCTAssertTrue(couple().socialSecurityIsEstimated)
        XCTAssertTrue(couple(entered: (4_100, 0)).socialSecurityIsEstimated, "one blank is still a guess")
        XCTAssertFalse(couple(entered: (4_100, 2_300)).socialSecurityIsEstimated)
    }

    /// Claiming is individual. A couple claiming years apart is the standard survivor-benefit
    /// play and a single household age could not express it.
    func testEachAdultClaimsOnTheirOwnSchedule() {
        let m = couple(entered: (4_100, 2_300), claimAges: (70, 62))
        XCTAssertEqual(profile(m, "p_0")?.plannedClaimingAge, 70)
        XCTAssertEqual(profile(m, "p_1")?.plannedClaimingAge, 62)
    }

    /// An adult who names no claiming age follows the household default, so existing plans
    /// keep their meaning.
    func testAnUnsetClaimingAgeFollowsTheHouseholdDefault() {
        let m = couple(claimAges: (0, 0))
        XCTAssertEqual(profile(m, "p_0")?.plannedClaimingAge, 67)
        XCTAssertEqual(profile(m, "p_1")?.plannedClaimingAge, 67)
    }

    /// The benefit reaches the plan: a bigger guaranteed income must lower the required
    /// return. If it did not, the field would be decorative.
    func testAnEnteredBenefitMovesTheRequiredReturn() {
        let low = Engine.evaluate(couple(entered: (1_000, 800)).buildHousehold())
        let high = Engine.evaluate(couple(entered: (4_500, 3_500)).buildHousehold())
        XCTAssertLessThan(high.requiredReturn.requiredRealReturnBps, low.requiredReturn.requiredRealReturnBps,
                          "more guaranteed income must lower the return the portfolio has to earn")
    }

    /// Both new fields must survive a save and reload, or the advisor's entry silently
    /// reverts to the estimate the next time the book is opened.
    func testTheEnteredFiguresRoundTrip() throws {
        let m = couple(entered: (4_100, 2_300), claimAges: (70, 62))
        let back = try JSONDecoder().decode(IntakeModel.self, from: try JSONEncoder().encode(m))
        XCTAssertEqual(back.adults[0].socialSecurityMonthlyUsd, 4_100, accuracy: 0.5)
        XCTAssertEqual(back.adults[1].socialSecurityMonthlyUsd, 2_300, accuracy: 0.5)
        XCTAssertEqual(back.adults[0].ssClaimAge, 70)
        XCTAssertEqual(back.adults[1].ssClaimAge, 62)
    }
}

/// A pre-filled dollar amount is a fabricated answer. Nobody re-reads a field that already
/// looks filled in, so $120,000 of invented salary and $300,000 of invented IRA survived
/// intake and reached the plan as if the client had said them. Amounts are facts about a
/// specific client; ages and horizons are conventions and keep their defaults.
final class IntakeDefaultHonestyTests: XCTestCase {

    func testNoDollarAmountIsInventedForANewClient() {
        let m = IntakeModel()
        let amounts: [(String, Usd)] = [
            ("salary", m.adults.first?.salaryUsd ?? 0),
            ("annual savings", m.annualSavingsUsd),
            ("emergency reserve", m.emergencyReserveUsd),
            ("taxable", m.taxableUsd),
            ("traditional", m.traditionalUsd),
            ("Roth", m.rothUsd),
            ("retirement spending", m.retirementSpendingUsd),
            ("pension", m.pensionAnnualUsd),
            ("Social Security", m.adults.first?.socialSecurityMonthlyUsd ?? 0),
        ]
        for (label, value) in amounts {
            XCTAssertEqual(value, 0, accuracy: 0.5, "a new client starts with no \(label) entered, not an invented figure")
        }
        XCTAssertEqual(m.totalInvestableUsd, 0, accuracy: 0.5, "an untouched intake has no portfolio")
    }

    /// State of residence is a client fact too, and an expensive one: it sets the income
    /// rate feeding SALT, the itemization verdict and the muni crossover. A pre-filled
    /// California taxed a Texan at 9.30% if nobody noticed the wheel.
    func testStateOfResidenceIsNotPreFilled() {
        XCTAssertEqual(IntakeModel().state, "", "a new client has not told us where they live")
        XCTAssertEqual(Seed.stateTaxProfile(for: IntakeModel().state).code, "US",
                       "an unset state resolves to the generic profile, not to a specific one")
        // The generic profile carries a documented national-average rate rather than zero —
        // SALT needs SOME rate, and "unspecified" is the honest label for it. What matters is
        // that it is not a specific state's rate quietly standing in for the client's.
        XCTAssertNotEqual(Seed.stateTaxProfile(for: IntakeModel().state).incomeRate,
                          Seed.stateTaxProfile(for: "CA").incomeRate,
                          "an unset state must not be taxed at California's rate")
    }

    /// Conventions are not fabrications, and must survive — blanking them would just move
    /// the dishonesty from "invented answer" to "impossible plan".
    func testConventionalDefaultsAreKept() {
        let m = IntakeModel()
        XCTAssertEqual(m.ssClaimAge, 67, "full retirement age is a convention, not a client fact")
        XCTAssertEqual(m.planToAge, 92, "planning horizon is a convention (a high longevity percentile), not a client fact")
        XCTAssertGreaterThan(m.adults.first?.retirementAge ?? 0, 0)
        XCTAssertGreaterThan(m.adults.first?.birthYear ?? 0, 1900)
    }
}
