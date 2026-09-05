import XCTest
@testable import WealthPolicyDesk

/// Sequence-of-returns risk is the risk that bad returns arrive WHILE YOU ARE WITHDRAWING.
/// The stress pattern was anchored on `householdSaveYears` — the LATER of two retirements —
/// which is not the same year the plan starts drawing. For a couple with a much younger
/// working spouse the two differ by many years, so the shock landed long after withdrawals
/// began while the card described "a drawdown in the very first year of retirement".
///
/// The same anchor hid a silent no-op: when the savings window ran past the horizon, every
/// stress path fell off the end of the plan and returned the UNSHOCKED corpus, reporting
/// "survives 3 of 3" for a household that does not.
final class SequenceStressAnchorTests: XCTestCase {

    private let asOf = Engine.planningAsOf

    /// A retired primary with a much younger, still-earning spouse: `householdSaveYears`
    /// says saving continues for decades, while the corpus is being drawn on today.
    private func retiredPrimaryYoungWorkingSpouse() -> Household {
        var h = Seed.sampleHousehold
        h.people = h.people.map { p in
            var q = p
            if q.role == .primary { q.birthDate = "1955-01-01"; q.expectedRetirementAge = 62 }   // long retired
            if q.role == .spouse  { q.birthDate = "1990-01-01"; q.expectedRetirementAge = 67 }   // 36, decades to go
            return q
        }
        return h
    }

    /// The shock must land in the first year the plan actually draws on the corpus.
    func testTheShockLandsOnTheFirstDrawdownYear() {
        let h = retiredPrimaryYoungWorkingSpouse()
        let e = Engine.evaluate(h)
        let saveYears = Engine.householdSaveYears(h, asOf: asOf)
        XCTAssertGreaterThan(saveYears, 20, "fixture check: the savings window runs decades past the first draw")

        // The unshocked corpus is the control. If the pattern were still anchored on
        // `saveYears` it would fall outside the horizon entirely and every stress would
        // reproduce this number exactly.
        let flat = e.resilience.sensitivities.first { $0.realReturnBps == e.requiredReturn.requiredRealReturnBps }
        XCTAssertNotNil(flat)
        for s in e.resilience.stresses {
            XCTAssertNotEqual(s.terminalBalanceUsd, flat!.terminalBalanceUsd, accuracy: 1,
                              "\(s.name): a stress that reproduces the unshocked corpus never applied its shock")
        }
    }

    /// The headline consequence: an unshocked stress set reports a verdict the plan has not
    /// earned. With the shock actually landing, this household must not sail through.
    func testAnUnshockedStressSetCannotReportSurvival() {
        let e = Engine.evaluate(retiredPrimaryYoungWorkingSpouse())
        let survived = e.resilience.stresses.filter(\.survives).count
        XCTAssertLessThan(survived, e.resilience.stresses.count,
                          "a household drawing today, shocked from today, cannot survive every historical sequence")
    }

    /// A household still years from retiring must NOT be shocked in plan year 1 — that is
    /// the failure the offset exists to prevent. The anchor is the first RETIREMENT-spending
    /// year specifically: anchoring on any net outflow pulled the shock back to year 1 for
    /// the sample, because its emergency reserve funds in year 1 and that is not a drawdown.
    func testAOneOffReserveGoalDoesNotPullTheShockForward() {
        let h = Seed.sampleHousehold
        let reserveYear1 = h.goals.filter { $0.kind == .reserve }
            .flatMap(\.outflows).contains { $0.year == 1 && $0.amountUsd > 0 }
        XCTAssertTrue(reserveYear1, "fixture check: the sample funds a reserve in plan year 1")

        // With the shock correctly anchored on retirement (plan year 3), the corpus gets two
        // growth years first. A year-1 anchor compounds the worst returns against the largest
        // balance and depletes materially sooner.
        let depletions = Engine.evaluate(h).resilience.stresses.compactMap(\.depletionAge)
        XCTAssertEqual(depletions.count, 3, "fixture check: the sample's spend exceeds its safe level")
        XCTAssertGreaterThanOrEqual(depletions.min() ?? 0, 84,
                                    "a shock landing before retirement would deplete this plan far earlier")
    }

    /// The anchor must track RETIREMENT, not the savings window. Two otherwise identical
    /// households differing only in when they retire must be shocked at different times.
    func testTheShockFollowsRetirementNotTheSavingsWindow() {
        func depletion(retiringAt age: Int) -> Int? {
            var m = IntakeModel()
            m.adults = [{ var a = IntakeAdult(); a.birthYear = 1975; a.retirementAge = age
                          a.salaryUsd = 250_000; return a }()]
            m.retirementStartAge = age
            m.planToAge = 95
            m.taxableUsd = 1_500_000
            m.retirementSpendingUsd = 300_000
            m.annualSavingsUsd = 50_000
            return Engine.evaluate(m.buildHousehold()).resilience.stresses.compactMap(\.depletionAge).min()
        }
        let ages = [58, 63, 68].compactMap { depletion(retiringAt: $0) }
        XCTAssertEqual(ages.count, 3, "fixture check: all three plans deplete under stress")
        XCTAssertEqual(ages, ages.sorted(),
                       "depletion must move later as retirement moves later — the shock tracks retirement (got \(ages))")
        XCTAssertLessThan(ages[0], ages[2],
                          "retiring ten years sooner must bring the sequence shock, and the depletion, forward")
    }

    /// Max safe spend is solved on the same path the stresses report, so it moves with the
    /// anchor. Pinned, because the previous suite let the whole anchor change silently.
    func testMaxSafeSpendIsPinnedToTheShippedSample() {
        let r = Engine.evaluate(Seed.sampleHousehold).resilience
        XCTAssertEqual(r.maxSafeSpendUsd, 182_201, accuracy: 250,
                       "the safe-spend solve rides on the stress path; a moved anchor moves this")
        XCTAssertLessThan(r.maxSafeSpendUsd, r.currentSpendUsd,
                          "the sample deliberately spends above its stress-safe level — that is the teaching point")
    }
}
