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
        XCTAssertLessThan(rNow.projection.first!.balanceUsd, rNow.currentAssetsUsd - 1,
                          "the required-return chart must start after today's draw, matching the solve")
    }

    /// An accumulator with no year-0 extra claim keeps the historical frame: the chart
    /// starts at today's corpus and a stray year-0 on the retirement schedule is ignored
    /// only when retirement itself hasn't started. Extra / education claims dated THIS
    /// year are a different slot — see `testAccumulatorThisYearClaimIsFundedOffTheTop`.
    func testAccumulatorWithoutAThisYearClaimStartsAtTodaysCorpus() {
        let sample = Engine.requiredReturn(Seed.sampleHousehold, asOf: asOf)
        XCTAssertEqual(Engine.corpusStartT(Seed.sampleHousehold, asOf: asOf), 1)
        XCTAssertEqual(sample.projection.first!.balanceUsd, sample.currentAssetsUsd, accuracy: 0.5,
                       "an accumulator's chart starts at today's corpus — no year-0 subtract")
    }

    /// Batch 6 dated a worker's extra goal "this year" as plan year 0, but the solve
    /// still started at t=1, so a home purchase this calendar year never entered the
    /// required return. Same dollar next year must be cheaper — no growth year cushions
    /// today's claim.
    func testAccumulatorThisYearClaimIsFundedOffTheTop() {
        func withExtra(atYear year: Int) -> Household {
            var h = Seed.sampleHousehold
            h.goals.append(Goal(id: "g_extra_now", label: "Home", kind: .spending, tier: .lifestyle,
                                horizonYears: year, outflows: [Outflow(year: year, amountUsd: 200_000, inflationLinked: false)],
                                inflationSeries: .cpi, maxShortfallProbabilityBps: 1500, holdToStepUp: false,
                                flexibility: .rigid, policyId: "spending-glide"))
            return h
        }
        let now = withExtra(atYear: 0)
        let later = withExtra(atYear: 1)
        XCTAssertEqual(Engine.corpusStartT(now, asOf: asOf), 0)
        XCTAssertEqual(Engine.corpusStartT(later, asOf: asOf), 1)
        let rNow = Engine.requiredReturn(now, asOf: asOf)
        let rLater = Engine.requiredReturn(later, asOf: asOf)
        XCTAssertGreaterThan(rNow.requiredRealReturnBps, rLater.requiredRealReturnBps,
                             "a worker's this-year extra claim must be funded, not dropped")
        XCTAssertLessThan(rNow.projection.first!.balanceUsd, rNow.currentAssetsUsd - 1,
                          "the chart must start after today's extra claim, matching the solve")
    }
}
