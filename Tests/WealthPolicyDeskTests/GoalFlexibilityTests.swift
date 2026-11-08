import XCTest
@testable import WealthPolicyDesk

/// PER-GOAL FLEXIBILITY — a goal the client called rigid is never scaled or deferred
/// because some OTHER goal was flexible.
///
/// The engine used to take ONE household-wide pair — `.max(deferrableYears)` and
/// `.max(scalableDownBps)` across all spending goals — and charge it to every spending
/// goal. A client who answered "No — it's fixed" about retirement had that stream cut by
/// 15–50% and pushed out anyway, because an education goal (1yr/3000bps), an extra goal
/// (0/1500) or a goal added from the IPS screen (3/5000) carried a flexible default nobody
/// asked them for. The figure is published at 27pt on the Required Return tab and asserted
/// in the signed statement.
///
/// Why this file has to exist at all: `Seed.sampleHousehold` has exactly ONE `.spending`
/// goal, so `max()`-across-goals and scale-only-your-own are arithmetically identical for
/// it. The golden master cannot move when this rule breaks, and the whole 546-test suite
/// passed the per-goal change untouched. Every test below is written so that restoring the
/// household-wide pair makes it RED.
///
/// The shape of the teeth: two households that the OLD rule could not tell apart, because
/// `max()` erased the difference. H1 has one flexible goal and one rigid one; H2 has both
/// flexible. Under the old rule both solved the same stream. Under the per-goal rule H1's
/// rigid goal keeps its full claim, so H1 must need strictly — and substantially — more
/// return than H2. No reference to deleted code is needed to state that.
final class GoalFlexibilityTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"

    // MARK: - Fixtures

    /// The sample household with the retirement goal's own flexibility set, and nothing else
    /// changed. `Seed.sampleHousehold` ships `deferrableYears: 2, scalableDownBps: 1500`.
    private func base(retirementDefer d: Int, retirementScaleBps s: Bps) -> Household {
        var h = Seed.sampleHousehold
        h.goals = h.goals.map { g in
            guard g.id == "g_spending" else { return g }
            var g = g
            g.flexibility = GoalFlexibility(deferrableYears: d, scalableDownBps: s, abandonable: false)
            return g
        }
        return h
    }

    /// A dated extra spending claim, the shape `buildHousehold` appends for an additional
    /// goal or an education ladder. Deliberately inside the retirement horizon (32 on the
    /// sample) and never at year 0, so it moves neither `horizon` nor `corpusStartT`.
    private func withExtra(_ h: Household, amount: Usd, year: Int,
                           defer d: Int, scaleBps s: Bps, id: String = "g_extra_0") -> Household {
        var h = h
        h.goals.append(Goal(id: id, label: "Extra", kind: .spending, tier: .lifestyle,
                            horizonYears: year, outflows: [Outflow(year: year, amountUsd: amount, inflationLinked: true)],
                            inflationSeries: .cpi, maxShortfallProbabilityBps: 1500, holdToStepUp: false,
                            flexibility: GoalFlexibility(deferrableYears: d, scalableDownBps: s, abandonable: false),
                            policyId: "spending-glide"))
        return h
    }

    private func flexBps(_ h: Household) -> Bps { Engine.requiredReturn(h, asOf: asOf).requiredRealReturnWithFlexibilityBps }
    private func plainBps(_ h: Household) -> Bps { Engine.requiredReturn(h, asOf: asOf).requiredRealReturnBps }

    // MARK: - The rule itself

    /// THE TEETH, scaling half. Both households carry a 50%-scalable extra goal; they differ
    /// only in whether the RETIREMENT goal is also scalable. The old `max()` rule could not
    /// see that difference — it took 5000 bps from the extra goal and applied it to the
    /// retirement stream too, so both households solved an identical, half-sized retirement
    /// spend. Per-goal, the rigid household must need materially more return.
    func testARigidRetirementGoalIsNotScaledBecauseAnotherGoalIsFlexible() {
        let rigidRetirement = withExtra(base(retirementDefer: 0, retirementScaleBps: 0),
                                        amount: 250_000, year: 6, defer: 0, scaleBps: 5000)
        let bothFlexible = withExtra(base(retirementDefer: 0, retirementScaleBps: 5000),
                                     amount: 250_000, year: 6, defer: 0, scaleBps: 5000)

        // Precondition: the two differ ONLY in the retirement goal's own flexibility.
        XCTAssertEqual(rigidRetirement.goals.count, bothFlexible.goals.count)
        XCTAssertEqual(plainBps(rigidRetirement), plainBps(bothFlexible),
                       "flexibility must not touch the un-flexed number — if it does, these two aren't comparable")

        XCTAssertGreaterThan(flexBps(rigidRetirement), flexBps(bothFlexible),
                             "a rigid retirement goal must not be scaled down because the extra goal was flexible")
        XCTAssertGreaterThan(flexBps(rigidRetirement) - flexBps(bothFlexible), 100,
                             "the difference must be material, not a rounding artifact — this is the number on the IPS")
    }

    /// THE TEETH, deferral half. Same construction one axis over: both carry a 3-year
    /// deferrable extra goal, and differ only in whether retirement also defers. `max()`
    /// made them identical.
    func testARigidRetirementGoalIsNotDeferredBecauseAnotherGoalIsDeferrable() {
        let rigidRetirement = withExtra(base(retirementDefer: 0, retirementScaleBps: 0),
                                        amount: 250_000, year: 6, defer: 3, scaleBps: 0)
        let bothDeferrable = withExtra(base(retirementDefer: 3, retirementScaleBps: 0),
                                       amount: 250_000, year: 6, defer: 3, scaleBps: 0)

        XCTAssertGreaterThan(flexBps(rigidRetirement), flexBps(bothDeferrable),
                             "a rigid retirement goal must not be pushed out because the extra goal was deferrable")
        XCTAssertGreaterThan(flexBps(rigidRetirement) - flexBps(bothDeferrable), 50,
                             "deferring 32 years of retirement spending is not a rounding difference")
    }

    /// The exact-arithmetic statement of the rule, with no deferral in play so the horizon
    /// is identical in both arms: flexing a goal by 5000 bps must produce exactly the number
    /// you get by halving that goal's own outflow by hand and flexing nothing.
    func testFlexingOneGoalEqualsHalvingThatGoalAndNothingElse() {
        let flexed = withExtra(base(retirementDefer: 0, retirementScaleBps: 0),
                               amount: 250_000, year: 6, defer: 0, scaleBps: 5000)
        let handScaled = withExtra(base(retirementDefer: 0, retirementScaleBps: 0),
                                   amount: 125_000, year: 6, defer: 0, scaleBps: 0)

        XCTAssertEqual(flexBps(flexed), plainBps(handScaled),
                       "the flex solve must scale the flexible goal's own outflows and nothing else")
        // And it is a real discount, not a no-op that happens to match.
        XCTAssertLessThan(flexBps(flexed), plainBps(flexed),
                          "a 50%-scalable $250k claim must still buy something")
    }

    /// MIRROR CASE. This project's fixes keep closing one direction and opening the other,
    /// so: the flexibility the client DID grant must still work. A household whose only
    /// spending goal is flexible has to show a discount — the per-goal rule must not have
    /// quietly become "no goal ever flexes".
    func testTheGoalThatCarriesFlexibilityStillFlexes() {
        let flexible = base(retirementDefer: 2, retirementScaleBps: 1500)
        XCTAssertLessThan(flexBps(flexible), plainBps(flexible),
                          "a flexible retirement goal must still lower the required return")
        XCTAssertGreaterThan(plainBps(flexible) - flexBps(flexible), 50,
                             "and by a material amount — the sample ships 2 years / 15%")
    }

    /// MIRROR CASE, the other direction. A household where every spending goal is rigid must
    /// get NO discount at all — not a small one. This is what the client who answered
    /// "No — it's fixed" and added an education goal was denied.
    func testAnEntirelyRigidHouseholdGetsNoFlexibilityDiscount() {
        let rigid = withExtra(base(retirementDefer: 0, retirementScaleBps: 0),
                              amount: 250_000, year: 6, defer: 0, scaleBps: 0)
        XCTAssertEqual(flexBps(rigid), plainBps(rigid),
                       "nothing is flexible, so there is nothing to discount")
    }

    /// The education ladder is the real-world instance: `buildHousehold` hard-codes
    /// 1 year / 3000 bps on it (`IntakeModel.swift:1373`) and the form never asks. A client
    /// who called retirement rigid must not have 32 years of retirement spending cut 30%
    /// because their child is going to college.
    func testAnEducationLadderDoesNotScaleARigidRetirementSpend() {
        let withEdu = withExtra(base(retirementDefer: 0, retirementScaleBps: 0),
                                amount: 60_000, year: 4, defer: 1, scaleBps: 3000, id: "g_edu_abcd1234")
        XCTAssertEqual(flexBps(withEdu), plainBps(withEdu) - (plainBps(withEdu) - flexBps(withEdu)))
        // The discount the education goal buys must be small, because the education goal is
        // small. Under the household-wide rule it was ~169 bps, because retirement scaled too.
        XCTAssertLessThan(plainBps(withEdu) - flexBps(withEdu), 40,
                          "a $60k ladder cannot ease a multi-million-dollar plan by more than a few bps")
    }

    // MARK: - What must NOT flex

    /// A `.reserve` claim never flexes, flexed or not — a reserve that can be deferred is not
    /// a reserve. Intake builds it `.rigid`, but the field is settable, so the rule is
    /// asserted rather than assumed.
    func testAReserveClaimNeverFlexesEvenCarryingFlexibility() {
        var h = base(retirementDefer: 0, retirementScaleBps: 0)
        h.goals.append(Goal(id: "g_reserve", label: "Emergency reserve", kind: .reserve, tier: .essential,
                            horizonYears: nil, outflows: [Outflow(year: 1, amountUsd: 150_000, inflationLinked: false)],
                            inflationSeries: .cpi, maxShortfallProbabilityBps: 100, holdToStepUp: false,
                            flexibility: GoalFlexibility(deferrableYears: 5, scalableDownBps: 9000, abandonable: true),
                            policyId: "legacy-perpetual"))
        XCTAssertEqual(flexBps(h), plainBps(h),
                       "a reserve must be funded in full on time whatever its flexibility field says")
    }

    /// The deferred outflow has to be FUNDED at its later year, not dropped off the end of
    /// the recursion. The horizon extension is what does that, and it is the one legitimate
    /// `max()` left in the solve — a loop bound covering the latest shifted outflow of any
    /// goal, not a flexibility charged to a goal.
    func testADeferredOutflowIsStillFundedRatherThanDropped() {
        let h = withExtra(base(retirementDefer: 0, retirementScaleBps: 0),
                          amount: 400_000, year: 30, defer: 4, scaleBps: 0)
        var removed = h
        removed.goals.removeAll { $0.id == "g_extra_0" }

        XCTAssertLessThan(flexBps(h), plainBps(h), "deferring a late claim must help")
        XCTAssertGreaterThan(flexBps(h), plainBps(removed),
                             "but it must cost more than not having the claim at all — a deferred outflow is funded, not forgiven")
    }

    // MARK: - The two engine functions, directly

    func testGoalFlexReturnsEachGoalsOwnPairAndNothingElse() {
        let spending = Goal(id: "s", label: "s", kind: .spending, tier: .essential, horizonYears: 10,
                            outflows: [], inflationSeries: .cpi, maxShortfallProbabilityBps: 300, holdToStepUp: false,
                            flexibility: GoalFlexibility(deferrableYears: 3, scalableDownBps: 2500, abandonable: false),
                            policyId: "spending-glide")

        let on = Engine.goalFlex(spending, flexed: true)
        XCTAssertEqual(on.shift, 3)
        XCTAssertEqual(on.scale, 0.75, accuracy: 1e-12)

        let off = Engine.goalFlex(spending, flexed: false)
        XCTAssertEqual(off.shift, 0)
        XCTAssertEqual(off.scale, 1.0, accuracy: 1e-12)

        var rigid = spending; rigid.flexibility = .rigid
        XCTAssertEqual(Engine.goalFlex(rigid, flexed: true).shift, 0)
        XCTAssertEqual(Engine.goalFlex(rigid, flexed: true).scale, 1.0, accuracy: 1e-12)

        var reserve = spending; reserve.kind = .reserve
        XCTAssertEqual(Engine.goalFlex(reserve, flexed: true).shift, 0, "a reserve never shifts")
        XCTAssertEqual(Engine.goalFlex(reserve, flexed: true).scale, 1.0, accuracy: 1e-12, "a reserve never scales")

        // A negative deferral would run the recursion backwards; it is clamped.
        var negative = spending
        negative.flexibility = GoalFlexibility(deferrableYears: -4, scalableDownBps: 0, abandonable: false)
        XCTAssertEqual(Engine.goalFlex(negative, flexed: true).shift, 0)
    }

    /// The captions on the Required Return tab, the signed statement and guided Lesson 3 all
    /// attributed the discount to "the spending goal", singular, and called it free. None of
    /// those files is compiled by `swift test`, so the claim could not be contradicted by any
    /// assertion. The naming is a decision, so it lives in the engine and is asserted here.
    func testTheFlexibilitySummaryNamesWhichGoalsFlexAndWhichAreHeldFixed() {
        let mixed = withExtra(base(retirementDefer: 0, retirementScaleBps: 0),
                              amount: 60_000, year: 4, defer: 1, scaleBps: 3000, id: "g_edu_x")
        let s = Engine.goalFlexibilitySummary(mixed)
        XCTAssertEqual(s.flexibleLabels, ["Extra"])
        XCTAssertEqual(s.rigidLabels, ["Retirement spending"])
        XCTAssertTrue(s.anyFlexible)
        XCTAssertEqual(s.phrase, "Extra")

        // A household that granted no flexibility must get no figure at all, not a figure
        // equal to the plain one presented as a concession.
        let allRigid = Engine.goalFlexibilitySummary(base(retirementDefer: 0, retirementScaleBps: 0))
        XCTAssertFalse(allRigid.anyFlexible)
        XCTAssertEqual(allRigid.phrase, "no goal")
        XCTAssertEqual(allRigid.rigidLabels, ["Retirement spending"])

        // Deferrable-only counts as flexible: the old caption's "deferring and scaling"
        // implied both, and a goal that only defers was still a source of the discount.
        let deferOnly = Engine.goalFlexibilitySummary(base(retirementDefer: 2, retirementScaleBps: 0))
        XCTAssertEqual(deferOnly.flexibleLabels, ["Retirement spending"])
        XCTAssertTrue(deferOnly.rigidLabels.isEmpty)

        // Three or more collapses rather than printing a sentence-long list.
        var many = base(retirementDefer: 2, retirementScaleBps: 1500)
        many = withExtra(many, amount: 10_000, year: 3, defer: 0, scaleBps: 1500, id: "g_extra_1")
        many = withExtra(many, amount: 10_000, year: 4, defer: 0, scaleBps: 1500, id: "g_extra_2")
        XCTAssertEqual(Engine.goalFlexibilitySummary(many).phrase, "Retirement spending and 2 other goals")
    }

    func testFlexHorizonExtensionIsTheLongestDeferralAndZeroWhenNotFlexed() {
        var h = base(retirementDefer: 2, retirementScaleBps: 0)
        h = withExtra(h, amount: 10_000, year: 5, defer: 7, scaleBps: 0)
        XCTAssertEqual(Engine.flexHorizonExtensionYears(h, flexed: true), 7,
                       "the loop must run far enough to fund the latest shifted outflow of ANY goal")
        XCTAssertEqual(Engine.flexHorizonExtensionYears(h, flexed: false), 0)

        let rigid = base(retirementDefer: 0, retirementScaleBps: 0)
        XCTAssertEqual(Engine.flexHorizonExtensionYears(rigid, flexed: true), 0)
    }
}
