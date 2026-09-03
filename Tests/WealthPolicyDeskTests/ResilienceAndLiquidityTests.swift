import XCTest
@testable import WealthPolicyDesk

/// Guards the second batch of audit fixes: three places where the engine reached a
/// misleading CONCLUSION — "resilient", "covered", "95% equity" — rather than a wrong
/// number. Each was verified by adversarial review before being fixed here.
final class ResilienceAndLiquidityTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"

    // MARK: - The tolerance curve must not be flattened by funded status

    /// The bug: the drawdown sweep ran at the household's ACTUAL funded ratio, so an
    /// overfunded household glided to the 30% derisk floor at every ceiling. The curve
    /// went flat, every rung came in under any stated limit, and the mapping returned
    /// the top of the sweep — 95% equity for someone who said they could stomach 15%.
    func testToleranceCurveRisesWithTheEquityCeiling() {
        let e = Engine.evaluate(Seed.sampleHousehold)
        let curve = Engine.drawdownByCeiling(Seed.sampleHousehold, ladder: e.ladder)
        XCTAssertGreaterThan(curve.count, 5)
        guard let lo = curve.first, let hi = curve.last else { return XCTFail("expected a curve") }
        XCTAssertGreaterThan(hi.drawdownBps, lo.drawdownBps,
                             "a higher equity ceiling must model a deeper drawdown, or the mapping is meaningless")
        // Monotone non-decreasing across the whole sweep.
        for (a, b) in zip(curve, curve.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.drawdownBps, a.drawdownBps, "curve dips at ceiling \(b.ceilingBps)")
        }
    }

    /// A stated tolerance must bind: less stomach for loss must buy less equity.
    func testStatedDrawdownBindsTheEquityCeiling() {
        let h = Seed.sampleHousehold
        let ladder = Engine.evaluate(h).ladder
        let tight = Engine.toleranceEquityBps(h, ladder: ladder, maxDrawdownBps: 1500)
        let loose = Engine.toleranceEquityBps(h, ladder: ladder, maxDrawdownBps: 4000)
        XCTAssertLessThan(tight, loose, "a 15% tolerance must allow less equity than a 40% tolerance")
        XCTAssertLessThan(tight, 9500, "a tight tolerance must never map to the top of the sweep")
    }

    /// The mapping answers "how much equity may this tolerance hold". Being WELL FUNDED
    /// must not buy a bigger allowance — that was the bug: an overfunded household glided
    /// to the derisk floor at every ceiling, flattening the curve, and any stated tolerance
    /// returned 95%. A modest difference remains legitimate, because a larger portfolio
    /// carries a smaller forced cash floor as a SHARE and can hold a slightly different mix.
    func testBeingOverfundedDoesNotBuyMoreEquity() {
        var rich = Seed.sampleHousehold
        rich.positions = rich.positions.map { var p = $0; p.marketValueUsd *= 10; p.costBasisUsd *= 10; return p }
        let poorLadder = Engine.evaluate(Seed.sampleHousehold).ladder
        let richLadder = Engine.evaluate(rich).ladder
        XCTAssertGreaterThan(Engine.evaluate(rich).balanceSheet.fundedRatioBps, Engine.fundedFloorBps,
                             "fixture check: the scaled household is overfunded, which used to flatten the curve")

        let a = Engine.toleranceEquityBps(Seed.sampleHousehold, ladder: poorLadder, maxDrawdownBps: 2000)
        let b = Engine.toleranceEquityBps(rich, ladder: richLadder, maxDrawdownBps: 2000)
        XCTAssertLessThan(b, 9500, "an overfunded household must not read as 95% equity")
        XCTAssertLessThanOrEqual(abs(a - b), 500,
                                 "funded status must not move the tolerance ceiling more than the cash-floor effect (got \(a) vs \(b))")
    }

    // MARK: - The spending ladder is defensive assets, not everything

    /// Equities cannot satisfy a near-term spending ladder — selling them into a drawdown
    /// is the sequence risk the ladder exists to avoid. The rule was previously unfireable.
    func testLadderIsMeasuredAgainstCashAndFixedIncomeOnly() {
        let h = Seed.sampleHousehold
        let e = Engine.evaluate(h)
        let defensive = Engine.defensiveLiquidUsd(h)
        let everything = Engine.dailyLiquidUsd(h)
        XCTAssertLessThan(defensive, everything, "fixture check: the sample holds equities too")
        XCTAssertEqual(e.ladder.availableDefensiveUsd, defensive, accuracy: 0.5,
                       "the ladder must count only cash + fixed income")
        XCTAssertFalse(e.ladder.covered, "the sample's ladder is not funded by its defensive assets")
        XCTAssertTrue(e.findings.contains { $0.ruleId == "liquidity_floor" && $0.severity == .hard })
    }

    /// Capital calls are a different question — there, "could this be raised on demand"
    /// genuinely includes equities, so that measure must stay broad.
    func testCapitalCallLiquidityStillCountsEquities() {
        let h = Seed.sampleHousehold
        let equityValue = h.positions.filter { Engine.isEquity($0) }.reduce(0) { $0 + $1.marketValueUsd }
        XCTAssertGreaterThan(equityValue, 0, "fixture check")
        XCTAssertGreaterThanOrEqual(Engine.dailyLiquidUsd(h), equityValue)
    }

    // MARK: - Sequence stress starts at retirement, at the plan's equity share

    /// "Retire into 2008" must apply its drawdown at RETIREMENT. Applying the pattern from
    /// plan year 1 spent the bad years during accumulation — while the household was still
    /// saving and not yet spending — which is not the risk the card names.
    func testStressPatternIsOffsetToRetirement() {
        let h = Seed.sampleHousehold
        let saveYears = Engine.householdSaveYears(h, asOf: asOf)
        XCTAssertGreaterThan(saveYears, 0, "fixture check: the sample is still accumulating")

        let rr = Engine.requiredReturn(h, asOf: asOf)
        let policy = Engine.evaluate(h).legacyPolicy
        let a = Engine.resilience(h, tax: Seed.tax2026, rr: rr, asOf: asOf, policy: policy, annualTaxUsd: [:])

        // Retiring immediately must be strictly harsher than retiring years from now: the
        // same shock lands on a corpus that has had no time to grow and is already paying out.
        var now = h
        now.people = now.people.map { var p = $0; p.expectedRetirementAge = Engine.age(birthDate: p.birthDate, asOf: asOf); return p }
        let b = Engine.resilience(now, tax: Seed.tax2026, rr: rr, asOf: asOf, policy: policy, annualTaxUsd: [:])
        XCTAssertLessThanOrEqual(b.maxSafeSpendUsd, a.maxSafeSpendUsd,
                                 "a shock at an immediate retirement cannot be gentler than one years away")
    }

    /// Severity must come from the plan's equity share, not from where the money happens
    /// to be sitting today. An all-cash household previously "survived 3 of 3".
    func testStressSeverityIgnoresCurrentHoldingsMix() {
        let h = Seed.sampleHousehold
        let rr = Engine.requiredReturn(h, asOf: asOf)
        let policy = Engine.evaluate(h).legacyPolicy
        let asIs = Engine.resilience(h, tax: Seed.tax2026, rr: rr, asOf: asOf, policy: policy, annualTaxUsd: [:])

        // Same plan, same policy — but the client is sitting entirely in cash today.
        var allCash = h
        allCash.positions = allCash.positions.map { var p = $0; p.ticker = "SGOV"; p.sleeveId = "cash"; return p }
        let cashed = Engine.resilience(allCash, tax: Seed.tax2026, rr: rr, asOf: asOf, policy: policy, annualTaxUsd: [:])

        XCTAssertEqual(cashed.stressesSurvived, asIs.stressesSurvived,
                       "the stress prices the POLICY, so today's cash pile must not change the verdict")
        XCTAssertEqual(cashed.maxSafeSpendUsd, asIs.maxSafeSpendUsd, accuracy: 1.0)
    }
}
