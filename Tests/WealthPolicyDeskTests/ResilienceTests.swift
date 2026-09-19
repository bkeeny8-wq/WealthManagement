import XCTest
@testable import WealthPolicyDesk

/// The resilience engine — return-sensitivity and sequence-of-returns stresses, plus the
/// bisected max-safe-spend. No market forecasts, so these lock shape, not levels:
/// sensitivities rise with the realized return, survivors are bounded, headroom is signed
/// consistently with the safe-spend solve.
final class ResilienceTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"
    private func analysis() -> ResilienceAnalysis {
        let h = Seed.sampleHousehold
        let rr = Engine.requiredReturn(h, asOf: asOf)
        // Stress severity is scaled by the DERIVED policy's equity share, so use the same
        // policy `evaluate` does rather than the seed base.
        let policy = Engine.evaluate(h).legacyPolicy
        return Engine.resilience(h, tax: Seed.tax2026, rr: rr, asOf: asOf, policy: policy, annualTaxUsd: [:])
    }

    func testTerminalBalanceRisesWithTheRealizedReturn() {
        let s = analysis().sensitivities.sorted { $0.realReturnBps < $1.realReturnBps }
        XCTAssertGreaterThan(s.count, 1)
        for (lo, hi) in zip(s, s.dropFirst()) {
            XCTAssertLessThanOrEqual(lo.terminalBalanceUsd, hi.terminalBalanceUsd + 0.5,
                                     "a higher realized return cannot leave a smaller terminal balance")
        }
    }

    func testRequiredReturnIsOneOfTheSensitivityPoints() {
        let a = analysis()
        XCTAssertTrue(a.sensitivities.contains { $0.realReturnBps == a.requiredRealReturnBps },
                      "the required return itself must be a sampled point")
    }

    func testSurvivorCountIsBoundedAndConsistent() {
        let a = analysis()
        XCTAssertEqual(a.stressCount, a.stresses.count)
        XCTAssertEqual(a.stressCount, 3, "three historical bad-order stresses")
        XCTAssertEqual(a.stressesSurvived, a.stresses.filter { $0.survives }.count)
        XCTAssertTrue((0...a.stressCount).contains(a.stressesSurvived))
        // A stress that depletes cannot also be recorded as surviving.
        for s in a.stresses { if s.depletionAge != nil { XCTAssertFalse(s.survives) } }
    }

    func testMaxSafeSpendAndHeadroomAreSignConsistent() {
        let a = analysis()
        XCTAssertGreaterThanOrEqual(a.maxSafeSpendUsd, 0)
        if a.currentSpendUsd > 0 {
            if a.maxSafeSpendUsd > a.currentSpendUsd + 1 {
                XCTAssertGreaterThan(a.spendHeadroomBps, 0)
            } else if a.maxSafeSpendUsd < a.currentSpendUsd - 1 {
                XCTAssertLessThan(a.spendHeadroomBps, 0)
            }
        }
    }

    func testResilienceIsDeterministic() {
        let a = analysis(), b = analysis()
        XCTAssertEqual(a.maxSafeSpendUsd, b.maxSafeSpendUsd, accuracy: 0.0001)
        XCTAssertEqual(a.stressesSurvived, b.stressesSurvived)
        XCTAssertEqual(a.sensitivities.map(\.terminalBalanceUsd), b.sensitivities.map(\.terminalBalanceUsd))
    }

    /// Year-0 retiree spending used to sit outside the stress corpus (the loop started at
    /// plan year 1, so index 0 was next year's draw — the same dollar for a level
    /// schedule, which would not fail). A household whose ONLY spending is today's draw
    /// must still book that outflow; the old 1-based loop saw an empty path.
    func testRetireeResilienceBooksTodaysDraw() {
        var m = IntakeModel()
        var a = IntakeAdult(); a.birthYear = Engine.year(asOf) - 70; a.retirementAge = 62
        a.traditionalUsd = 900_000; a.socialSecurityMonthlyUsd = 0
        m.adults = [a]
        m.taxableUsd = 800_000
        m.retirementSpendingUsd = 110_000
        m.legacyFloorUsd = 0
        var h = m.buildHousehold(asOf: asOf)
        let horizon = max(1, h.goals.compactMap { $0.horizonYears }.max() ?? 30)
        let (full, _) = Engine.outflowComponents(h, asOf: asOf, annualTaxUsd: [:])
        XCTAssertEqual(full.count, horizon + 1, "index 0 is plan year 0, not year 1")
        XCTAssertGreaterThan(full[0], 50_000, "plan year 0 is today's spending, not an empty slot")

        h.goals = h.goals.map { g in
            guard g.kind == .spending else { return g }
            var g = g
            g.outflows = g.outflows.filter { $0.year == 0 }
            return g
        }
        let (onlyToday, _) = Engine.outflowComponents(h, asOf: asOf, annualTaxUsd: [:])
        XCTAssertGreaterThan(onlyToday[0], 50_000)
        XCTAssertEqual(onlyToday.dropFirst().reduce(0, +), 0, accuracy: 1,
                       "later years must be empty so a 1-based loop cannot fake a pass")
        let withYear0 = Engine.resilience(h, tax: Seed.tax2026,
                                          rr: Engine.requiredReturn(h, asOf: asOf),
                                          asOf: asOf, policy: Engine.evaluate(h).legacyPolicy,
                                          annualTaxUsd: [:])
        XCTAssertGreaterThan(withYear0.currentSpendUsd, 50_000,
                             "today's-only draw must still be the spend the stress corpus scales")
    }

    /// A worker's extra claim dated this year used to sit in outflowComponents[0] and
    /// then get skipped by `run` (retiree-only gate). Resilience must book it the same
    /// way requiredReturn does.
    func testAccumulatorResilienceBooksAThisYearExtraClaim() {
        var m = IntakeModel()
        var a = IntakeAdult(); a.birthYear = Engine.year(asOf) - 45; a.retirementAge = 65
        m.adults = [a]
        m.taxableUsd = 800_000
        m.retirementSpendingUsd = 90_000
        var g = IntakeGoal(); g.label = "Home"; g.amountUsd = 200_000
        g.targetYear = Engine.year(asOf); g.spanYears = 1
        m.additionalGoals = [g]
        let h = m.buildHousehold(asOf: asOf)
        XCTAssertEqual(Engine.corpusStartT(h, asOf: asOf), 0)
        let (spend, _) = Engine.outflowComponents(h, asOf: asOf, annualTaxUsd: [:])
        XCTAssertGreaterThan(spend[0], 100_000, "this-year extra claim is plan year 0")
        let res = Engine.resilience(h, tax: Seed.tax2026,
                                    rr: Engine.requiredReturn(h, asOf: asOf),
                                    asOf: asOf, policy: Engine.evaluate(h).legacyPolicy,
                                    annualTaxUsd: [:])
        XCTAssertGreaterThan(res.currentSpendUsd, 100_000,
                             "the stress corpus must scale today's extra claim, not skip it")
    }
}
