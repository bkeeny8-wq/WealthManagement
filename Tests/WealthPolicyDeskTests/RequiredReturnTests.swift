import XCTest
@testable import WealthPolicyDesk

/// Edge segments of the two-pass after-tax required return that the sample households
/// (both pre-retirement) don't exercise, so the golden master can't see them.
final class RequiredReturnTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"

    /// A retired primary, with one extra spending outflow at the given plan-year.
    private func retiree(extraOutflowAtYear year: Int, amount: Usd) -> Household {
        var h = Seed.sampleHousehold
        h.people = h.people.map { p in
            var p = p
            if p.role == .primary { p.expectedRetirementAge = 55 }   // already retired at asOf
            return p
        }
        h.goals = h.goals.map { g in
            guard g.id == "g_spending" else { return g }
            var g = g
            g.outflows = g.outflows + [Outflow(year: year, amountUsd: amount, inflationLinked: true)]
            return g
        }
        return h
    }

    /// A retiree draws THIS year off the top of the corpus — no growth year cushions it —
    /// so funding a year-0 outflow needs a strictly higher return than the same dollar a
    /// year later. This is the segment where the old loop (t=1…) silently dropped year 0.
    func testRetireeCurrentYearOutflowIsFundedOffTheTop() {
        let rNow = Engine.requiredReturn(retiree(extraOutflowAtYear: 0, amount: 500_000), asOf: asOf)
        let rLater = Engine.requiredReturn(retiree(extraOutflowAtYear: 1, amount: 500_000), asOf: asOf)
        XCTAssertGreaterThan(rNow.requiredRealReturnBps, rLater.requiredRealReturnBps,
                             "a retiree's current-year draw must be funded, not dropped")
    }

    /// An accumulator (primary not yet retired) has no year-0 drawdown slot by design, so a
    /// year-0 outflow is ignored — the fix stays surgical and never touches accumulators.
    func testAccumulatorHasNoYearZeroSlot() {
        var withYear0 = Seed.sampleHousehold      // primary retires at 65, not retired at asOf
        withYear0.goals = withYear0.goals.map { g in
            guard g.id == "g_spending" else { return g }
            var g = g
            g.outflows = g.outflows + [Outflow(year: 0, amountUsd: 500_000, inflationLinked: true)]
            return g
        }
        XCTAssertEqual(Engine.requiredReturn(withYear0, asOf: asOf).requiredRealReturnBps,
                       Engine.requiredReturn(Seed.sampleHousehold, asOf: asOf).requiredRealReturnBps,
                       "an accumulator's year-0 outflow is not part of the corpus math")
    }
}
