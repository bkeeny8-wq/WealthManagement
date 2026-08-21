import XCTest
@testable import WealthPolicyDesk

/// The couples-spending model: a household keeps saving until the LATER of the two
/// adults' retirements, and retirement spending steps down to a survivor share after
/// the first death. Both feed the required-return corpus recursion, so they change the
/// headline figures (see the golden master). These lock the mechanics that move them.
final class CouplesTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"

    /// The Harrisons: Robert retires in 2y, Susan in 3y. The household saves until the
    /// LATER of the two — so save-years follows Susan, not the primary.
    func testSaveYearsTracksTheLaterRetirement() {
        let h = Seed.sampleHousehold
        let adults = h.people.filter { $0.role == .primary || $0.role == .spouse }
        XCTAssertGreaterThan(adults.count, 1, "sample household is a couple")

        let perAdult = adults.map { max(0, $0.expectedRetirementAge - Engine.age(birthDate: $0.birthDate, asOf: asOf)) }
        let saveYears = Engine.householdSaveYears(h, asOf: asOf)
        XCTAssertEqual(saveYears, perAdult.max())

        // The primary is the earlier retiree here, so the household saves strictly longer
        // than a primary-only window would allow.
        let primaryYears = h.primary.map { max(0, $0.expectedRetirementAge - Engine.age(birthDate: $0.birthDate, asOf: asOf)) } ?? 0
        XCTAssertGreaterThan(saveYears, primaryYears)
    }

    /// After the first death, the joint spending line steps down to the survivor share.
    func testSpendingStepsDownToSurvivorShareAfterFirstDeath() {
        let h = Seed.sampleHousehold
        guard let firstDeath = h.firstDeathYearFromNow(asOf: asOf) else {
            return XCTFail("a couple must have a first-death year")
        }
        let adjusted = h.withSurvivorSpending(asOf: asOf)
        guard let g = adjusted.goals.first(where: { $0.id == "g_spending" }),
              let g0 = h.goals.first(where: { $0.id == "g_spending" }) else {
            return XCTFail("sample household must have a spending goal")
        }

        // Every retirement-year outflow at/after the first death is scaled by the factor;
        // earlier years are untouched.
        for o0 in g0.outflows {
            guard let o = g.outflows.first(where: { $0.year == o0.year }) else { continue }
            if o0.year >= firstDeath {
                XCTAssertEqual(o.amountUsd, o0.amountUsd * Engine.survivorSpendingFactor, accuracy: 0.5)
            } else {
                XCTAssertEqual(o.amountUsd, o0.amountUsd, accuracy: 0.5)
            }
        }
        // And the step-down is real: the last year sits below the first funded year.
        let amounts = g.outflows.sorted { $0.year < $1.year }.map(\.amountUsd)
        XCTAssertLessThan(amounts.last ?? 0, amounts.first ?? 0)
    }

    /// A single filer has no first death to survive — the survivor adjustment is a no-op.
    func testSingleFilerHasNoSurvivorDrop() {
        let h = IntakeModel().buildHousehold()   // default intake is one adult
        XCTAssertNil(h.firstDeathYearFromNow(asOf: asOf))

        let adjusted = h.withSurvivorSpending(asOf: asOf)
        let before = h.goals.first { $0.id == "g_spending" }?.outflows ?? []
        let after = adjusted.goals.first { $0.id == "g_spending" }?.outflows ?? []
        XCTAssertEqual(before.count, after.count)
        for (b, a) in zip(before.sorted { $0.year < $1.year }, after.sorted { $0.year < $1.year }) {
            XCTAssertEqual(a.amountUsd, b.amountUsd, accuracy: 0.5)
        }
    }

    /// The survivor drop lowers the liability, so the couple's required return sits below
    /// what the same plan would need with the joint budget carried to the end.
    func testSurvivorDropLowersRequiredReturn() {
        let couple = Seed.sampleHousehold
        let withDrop = Engine.evaluate(couple, asOf: asOf).requiredReturn.requiredRealReturnBps

        // A hypothetical where nobody dies within the horizon: push both longevity
        // targets far past the spending horizon so the first death lands beyond every
        // outflow and the survivor scaling touches nothing.
        var immortal = couple
        immortal.people = couple.people.map { p in
            guard p.role == .primary || p.role == .spouse else { return p }
            var np = p
            np.longevityPercentileTarget = 200
            return np
        }
        let g0 = immortal.goals.first { $0.id == "g_spending" }?.outflows ?? []
        let g1 = immortal.withSurvivorSpending(asOf: asOf).goals.first { $0.id == "g_spending" }?.outflows ?? []
        for (a, b) in zip(g0.sorted { $0.year < $1.year }, g1.sorted { $0.year < $1.year }) {
            XCTAssertEqual(a.amountUsd, b.amountUsd, accuracy: 0.5, "no death within horizon ⇒ no scaling")
        }
        let noDrop = Engine.evaluate(immortal, asOf: asOf).requiredReturn.requiredRealReturnBps

        XCTAssertLessThan(withDrop, noDrop, "surviving on the survivor share needs a lower return")
    }
}
