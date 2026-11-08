import XCTest
@testable import WealthPolicyDesk

/// AN UNREACHABLE DRAWDOWN LIMIT IS REPORTED, NOT SILENTLY SUBSTITUTED.
///
/// `Engine.toleranceEquityBps` filters the swept menu to portfolios inside the client's
/// stated limit and, when none qualify, returns the most defensive rung. That arithmetic is
/// right — nothing lower can be built — but it returned a bare `Bps`, so the substitution was
/// invisible from there on. `RiskProfile` carried no flag; the Risk Scale tab badged the rung
/// "YOU" and captioned it with the drawdown the client ASKED for; the balance sheet printed
/// "tolerance-bound"; the signed IPS said a stated limit "supports up to" that ceiling; and
/// `IPSReview` froze it into the client's permanent history where a substituted 15% and an
/// honoured 15% are byte-identical.
///
/// Measured on the committed tree: 51 of the intake's 160 answer combinations (31.9%) land
/// below the sample's 1572 bps menu floor, including EVERY combination of the 10% chip — the
/// default behavioural answers included. So the plainest "I can lose 10%" client was already
/// being overridden in silence.
///
/// Why none of the 557 existing tests caught it: the fallback returns `curve.first.ceilingBps`
/// (1500), the same number the function returns when the lowest rung legitimately qualifies.
/// The substitution is numerically invisible, so every existing assertion — monotone,
/// step ≤ 500, ≤ plateau, tight < loose, exposure ≤ ceiling — is satisfied by it just as well
/// as by a real answer. It was not merely untested; it was heavily exercised and silently
/// consumed, and `ResilienceAndLiquidityTests.testStatedDrawdownBindsTheEquityCeiling` reads
/// its entire `tight` value out of it.
final class ToleranceBandTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"

    // MARK: - Fixtures

    private func sample(statedBps: Bps) -> Household {
        var h = Seed.sampleHousehold
        h.statedToleranceMaxDrawdownBps = statedBps
        return h
    }

    private func profile(_ h: Household) -> RiskProfile {
        let e = Engine.evaluate(h, asOf: asOf)
        return Engine.riskProfile(h, fundedRatioBps: e.balanceSheet.fundedRatioBps, ladder: e.ladder)!
    }

    private func curve(_ h: Household) -> [(ceilingBps: Bps, drawdownBps: Bps)] {
        Engine.drawdownByCeiling(h, ladder: Engine.evaluate(h, asOf: asOf).ladder)
    }

    // MARK: - The menu has a floor, and it is above some answers the intake accepts

    /// The precondition everything else rests on. If this moves, the other fixtures need
    /// re-picking rather than the rule being wrong.
    func testTheSampleMenuHasADrawdownFloorAboveTheLowestOfferedChip() {
        let c = curve(Seed.sampleHousehold)
        let floor = c.map { $0.drawdownBps }.min()!
        XCTAssertGreaterThan(floor, 1000, "the 10% intake chip is below the floor — that is the defect's whole premise")
        XCTAssertEqual(c.first!.ceilingBps, 1500, "the sweep starts at the most defensive ceiling")
        XCTAssertEqual(floor, c.first!.drawdownBps, "the floor IS the most defensive rung — the fallback's own drawdown")
    }

    // MARK: - The resolution reports all three facts

    func testResolveToleranceReportsNoBandWhenNothingFits() {
        let c = curve(Seed.sampleHousehold)
        let floor = c.map { $0.drawdownBps }.min()!
        let r = Engine.resolveTolerance(fromCurve: c, maxDrawdownBps: 500)

        XCTAssertFalse(r.hasTolerableBand)
        XCTAssertNil(r.frontierToleranceEquityBps, "no ceiling implies a limit nothing meets")
        XCTAssertEqual(r.minDrawdownBps, floor)
        // The ceiling to BUILD at is unchanged — the fix adds knowledge, it does not change
        // what gets built. Anything else would move the golden master and every allocation.
        XCTAssertEqual(r.equityBps, c.first!.ceilingBps)
        XCTAssertEqual(r.equityBps, Engine.toleranceEquityBps(fromCurve: c, maxDrawdownBps: 500),
                       "the old accessor must still return exactly what it used to")
    }

    /// MIRROR CASE. The rule must not have become "nothing is ever tolerable".
    func testResolveToleranceReportsABandWhenSomethingFits() {
        let c = curve(Seed.sampleHousehold)
        let r = Engine.resolveTolerance(fromCurve: c, maxDrawdownBps: 3000)

        XCTAssertTrue(r.hasTolerableBand)
        XCTAssertEqual(r.frontierToleranceEquityBps, r.equityBps, "with a band, the nil-able twin is the ceiling")
        XCTAssertEqual(r.equityBps, Engine.toleranceEquityBps(fromCurve: c, maxDrawdownBps: 3000))
        XCTAssertGreaterThan(r.equityBps, c.first!.ceilingBps, "a real answer, not the floor")
    }

    /// The boundary. A limit exactly AT the floor is met — `<=`, not `<`.
    func testALimitExactlyAtTheMenuFloorIsTolerable() {
        let c = curve(Seed.sampleHousehold)
        let floor = c.map { $0.drawdownBps }.min()!
        XCTAssertTrue(Engine.resolveTolerance(fromCurve: c, maxDrawdownBps: floor).hasTolerableBand)
        XCTAssertFalse(Engine.resolveTolerance(fromCurve: c, maxDrawdownBps: floor - 1).hasTolerableBand)
    }

    // MARK: - RiskProfile carries it

    func testRiskProfileReportsAnUnachievableToleranceAsUnachievable() {
        let rp = profile(sample(statedBps: 1000))
        XCTAssertFalse(rp.hasTolerableBand)
        XCTAssertNil(rp.frontierToleranceEquityBps)
        XCTAssertEqual(rp.statedMaxDrawdownBps, 1000)
        XCTAssertGreaterThan(rp.minDrawdownBps, 1000, "the floor really is above what they said")
        XCTAssertEqual(rp.toleranceShortfallBps, rp.minDrawdownBps - 1000,
                       "the shortfall is the menu floor over the stated limit")
        // The signal must not be inferable from the numbers alone — that is why it is a field.
        // bindingIsCapacity is FALSE here (the floor sits below the capacity clamp), which is
        // exactly how every caption came to print "tolerance-bound" in the one case where the
        // tolerance had been discarded.
        XCTAssertFalse(rp.bindingIsCapacity,
                       "fixture check: the old code's only signal says 'tolerance-bound' here")
    }

    /// MIRROR CASE, and the golden master's own state: the sample states 3000 against a 1572
    /// floor, so it has a band and none of its pinned figures may move.
    func testTheGoldenMasterHouseholdHasATolerableBandAndIsUnmoved() {
        let rp = profile(Seed.sampleHousehold)
        XCTAssertTrue(rp.hasTolerableBand)
        XCTAssertEqual(rp.frontierToleranceEquityBps, rp.toleranceImpliedEquityBps)
        XCTAssertEqual(rp.toleranceShortfallBps, 0)
        XCTAssertEqual(rp.capacityEquityBps, 6700)
        XCTAssertEqual(rp.toleranceImpliedEquityBps, 6000)
        XCTAssertEqual(rp.bindingEquityBps, 6000)
    }

    // MARK: - The ladder states what each rung actually models

    /// THE FINDING, exactly as reported: the tab printed "≤ 10.0% drawdown" on a rung whose
    /// own portfolio models 15.7%. The ladder now carries both numbers, so the two can be
    /// compared in a test instead of only by eye on a screen `swift test` cannot compile.
    func testALadderRungBelowTheMenuFloorAdmitsWhatItActuallyModels() {
        let e = Engine.evaluate(Seed.sampleHousehold, asOf: asOf)
        let ladder = Engine.riskLadder(Seed.sampleHousehold, fundedRatioBps: e.balanceSheet.fundedRatioBps, ladder: e.ladder)

        // The shipped ladder's standard "Defensive" rung is 1500 bps, below the sample's own
        // 1572 bps floor — so the golden-master household's ladder already contains a rung
        // the desk cannot deliver.
        let defensive = ladder.first { $0.label == "Defensive" }!
        XCTAssertEqual(defensive.maxDrawdownBps, 1500)
        XCTAssertFalse(defensive.hasTolerableBand, "fixture check: this rung is below the menu floor")
        XCTAssertGreaterThan(defensive.modeledDrawdownBps, defensive.maxDrawdownBps,
                             "a rung that cannot be met must say what it does carry, not repeat the request")

        // Every rung with a band must honour its own label, which is the claim the tab's Note
        // makes about all of them ("priced as if the plan actually held that much equity").
        for rung in ladder where rung.hasTolerableBand {
            XCTAssertLessThanOrEqual(rung.modeledDrawdownBps, rung.maxDrawdownBps + 150,
                                     "\(rung.label): claims ≤ \(rung.maxDrawdownBps), models \(rung.modeledDrawdownBps)")
        }
        XCTAssertTrue(ladder.contains { $0.hasTolerableBand }, "mirror: not every rung is unreachable")
    }

    // MARK: - The desk says so

    func testTheDeskRaisesAHardFindingWhenNoPortfolioMeetsTheStatedLimit() {
        let bad = Engine.evaluate(sample(statedBps: 1000), asOf: asOf)
        let f = bad.findings.first { $0.ruleId == "tolerance_below_menu_floor" }
        XCTAssertNotNil(f, "the advisor has no other way to learn the tolerance was discarded")
        XCTAssertEqual(f?.severity, .hard)

        // MIRROR: an achievable tolerance must not raise it.
        let good = Engine.evaluate(sample(statedBps: 3000), asOf: asOf)
        XCTAssertFalse(good.findings.contains { $0.ruleId == "tolerance_below_menu_floor" })
    }

    /// An untouched intake defaults to a limit nobody typed (2100 bps) that is below its own
    /// menu floor. Firing there would put "Must resolve 1" on a blank client over an answer
    /// they never gave — the fabricated-assertion shape `Evaluation.isSolvable` exists to
    /// prevent. There is no plan of record to misreport until there is something to build.
    func testABlankIntakeHasNoBandButIsNotAccusedOfOne() {
        let h = IntakeModel().buildHousehold()
        let e = Engine.evaluate(h, asOf: asOf)
        XCTAssertEqual(h.portfolioValueUsd, 0, accuracy: 0.5, "fixture check: nothing entered yet")
        XCTAssertEqual(e.riskProfile?.hasTolerableBand, false, "the state is still reported on the profile")
        XCTAssertFalse(e.findings.contains { $0.ruleId == "tolerance_below_menu_floor" },
                       "but it is not raised against a client who has entered nothing")
    }

    /// The finding that inverted the fact: with no band the ceiling is the LEAST equity the
    /// menu can build, and `underfunded_at_risk_ceiling` called it "the most equity your
    /// tolerance allows". Its condition is also self-fulfilling there, since the target is
    /// built at that very floor.
    func testTheAtTheCeilingFindingIsSuppressedWhenTheCeilingIsTheMenuFloor() {
        var h = sample(statedBps: 1000)
        h.goals = h.goals.map { g in     // force underfunding so the rule is otherwise live
            guard g.kind == .spending else { return g }
            var g = g
            g.outflows = g.outflows.map { Outflow(year: $0.year, amountUsd: $0.amountUsd * 6, inflationLinked: $0.inflationLinked) }
            return g
        }
        let e = Engine.evaluate(h, asOf: asOf)
        XCTAssertLessThan(e.balanceSheet.fundedRatioBps, 9_800, "fixture check: underfunded")
        XCTAssertEqual(e.riskProfile?.hasTolerableBand, false, "fixture check: no band")
        XCTAssertFalse(e.findings.contains { $0.ruleId == "underfunded_at_risk_ceiling" },
                       "it would call the menu's floor 'the most equity your tolerance allows'")
        XCTAssertTrue(e.findings.contains { $0.ruleId == "tolerance_below_menu_floor" },
                      "replaced by the honest statement, not by silence")
    }

    // MARK: - The two surfaces cannot disagree

    /// `FrontierModel` and `Engine.riskProfile` each used to decide "is there a tolerable
    /// band" from a DIFFERENT sweep — 1500…9000 step 500 against 1500…9500 step 250 — and
    /// agreed only by luck. The ceiling now comes from one place; this asserts the verdict
    /// does too, across every matrix household at a limit below the floor and one above it.
    func testTheFrontierAndTheRiskProfileAgreeAboutWhetherABandExists() {
        var sawEmptyBand = false, sawRealBand = false
        for c in HouseholdMatrix.cases {
            for stated in [800, 1000, 2500, 4000] {
                var h = c.intake.buildHousehold()
                h.statedToleranceMaxDrawdownBps = stated
                let e = Engine.evaluate(h, asOf: asOf)
                guard e.isSolvable, let rp = e.riskProfile else { continue }
                let cme = Engine.capitalMarketExpectations(Seed.macroIndicators, regime: Engine.macroRegime(Seed.macroIndicators))
                let f = Engine.frontier(e, cme: cme)
                XCTAssertEqual(f.hasTolerableBand, rp.hasTolerableBand,
                               "\(c.name) at \(stated): chart says \(f.hasTolerableBand), profile says \(rp.hasTolerableBand)")
                XCTAssertEqual(f.frontierToleranceEquityBps, rp.frontierToleranceEquityBps,
                               "\(c.name) at \(stated): the ceiling must come from one place")
                if rp.hasTolerableBand { sawRealBand = true } else { sawEmptyBand = true }
            }
        }
        // Coverage guard: an agreement test that never met a disagreement-prone state proves
        // nothing. The matrix ships every case at the same 2100 bps default, so without the
        // sweep above this assertion would be vacuous.
        XCTAssertTrue(sawEmptyBand, "the sweep must actually reach the empty-band state")
        XCTAssertTrue(sawRealBand, "and the ordinary one")
    }

    // MARK: - It survives being saved

    /// Without this the signal dies at the persistence boundary: `PolicyStatementTab` deltas
    /// two reviews' equity ceilings, so a substituted 15% and an honoured 15% compare equal
    /// and a client who lowers their limit below the floor shows a 0 bps "change".
    func testTheIpsSnapshotRecordsWhetherTheCeilingWasSubstituted() throws {
        let bad = IPSReview.from(Engine.evaluate(sample(statedBps: 1000), asOf: asOf),
                                 overrides: HouseholdOverrides(), at: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertFalse(bad.toleranceHadTolerableBand)

        let good = IPSReview.from(Engine.evaluate(sample(statedBps: 3000), asOf: asOf),
                                  overrides: HouseholdOverrides(), at: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertTrue(good.toleranceHadTolerableBand)

        // Round-trips, and an older record with no such key reads as `true` — an admission
        // that history cannot say, not a claim the tolerance was honoured.
        let back = try JSONDecoder().decode(IPSReview.self, from: JSONEncoder().encode(bad))
        XCTAssertFalse(back.toleranceHadTolerableBand)
        XCTAssertEqual(back.equityCeilingBps, bad.equityCeilingBps)

        let legacy = try JSONDecoder().decode(IPSReview.self, from: Data(#"{"equityCeilingBps":6000}"#.utf8))
        XCTAssertTrue(legacy.toleranceHadTolerableBand)
    }

    /// The model-divergence finding told the advisor to close the gap by "moving the stated
    /// drawdown tolerance" — an instruction that cannot work below the floor, where every
    /// value resolves to the same ceiling. It reached that branch by falling through
    /// `toleranceElicited` and `bindingIsCapacity`, both of which look normal here.
    func testTheModelComparisonDoesNotBlameAToleranceThatWasDiscarded() {
        let e = Engine.evaluate(sample(statedBps: 1000), asOf: asOf)
        XCTAssertEqual(e.riskProfile?.hasTolerableBand, false)
        XCTAssertEqual(e.riskProfile?.bindingIsCapacity, false,
                       "fixture check: the branch that would have been taken")
    }
}
