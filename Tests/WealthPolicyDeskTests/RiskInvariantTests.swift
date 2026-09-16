import XCTest
@testable import WealthPolicyDesk

/// Properties of the resilience stress and the frontier, asserted across `HouseholdMatrix`.
///
/// Both have shipped defects that a green suite could not see. The sequence shock was
/// anchored on the savings window rather than the first drawdown, so it landed years after
/// withdrawals began — and when the savings window ran past the horizon it fell off the end
/// entirely, returning the UNSHOCKED corpus three times and reporting "survives 3 of 3" for a
/// plan that does not. The frontier curve was swept at the household's actual funded ratio,
/// so an overfunded household's glide pinned every point at the derisk floor and the chart
/// drew a menu topping out at 30% equity underneath a caption quoting 60%.
///
/// Written with both failure modes of the earlier invariant batches in mind: every assertion
/// has a mirror (the tax batch caught two of six because it only ever checked one direction),
/// and the coverage guard at the bottom asserts the matrix can actually reach these states
/// (the rebalance batch missed three because no fixture held a ladder, a tilt, or idle cash).
final class RiskInvariantTests: XCTestCase {

    private var matrix: [(name: String, intake: IntakeModel, eval: Evaluation, isOverItemised: Bool)] {
        HouseholdMatrix.evaluated
    }

    private var cme: CapitalMarketSet {
        Engine.capitalMarketExpectations(Seed.macroIndicators, regime: Engine.macroRegime(Seed.macroIndicators))
    }

    // MARK: - Sequence stress

    /// A stress must actually shock something. When the pattern falls outside the horizon
    /// every run reproduces the unshocked corpus, and three identical numbers are reported as
    /// "survives 3 of 3" — a verdict the plan has not earned, indistinguishable from a real one.
    func testEveryStressActuallyShocksThePlan() {
        for c in matrix where c.eval.isSolvable {
            let stresses = c.eval.resilience.stresses
            guard !stresses.isEmpty else { continue }
            guard let flat = c.eval.resilience.sensitivities
                .first(where: { $0.realReturnBps == c.eval.requiredReturn.requiredRealReturnBps }) else { continue }
            let identical = stresses.filter { abs($0.terminalBalanceUsd - flat.terminalBalanceUsd) < 1 }
            XCTAssertTrue(identical.isEmpty,
                "\(c.name): \(identical.map(\.name)) reproduce the unshocked corpus exactly — the pattern never landed")
        }
    }

    /// And the mirror: a stress must not be so severe that it is indistinguishable from
    /// total loss on every household. A pattern anchored at plan-year 1 compounds the worst
    /// returns against the largest balance, which is the failure the anchor exists to prevent.
    func testNotEveryHouseholdIsWipedOutByEveryStress() {
        let solvable = matrix.filter { $0.eval.isSolvable && !$0.eval.resilience.stresses.isEmpty }
        XCTAssertFalse(solvable.isEmpty, "no solvable household produces stresses")
        let anySurvives = solvable.contains { $0.eval.resilience.stresses.contains(where: \.survives) }
        XCTAssertTrue(anySurvives,
            "every stress on every household depletes — the shock is landing before the plan draws")
    }

    /// The reported survival count is the stresses. A headline that disagrees with the rows
    /// beneath it is how "survives 3 of 3" sat above three depleting sequences.
    func testTheSurvivalCountMatchesTheStresses() {
        for c in matrix {
            let r = c.eval.resilience
            XCTAssertEqual(r.stressCount, r.stresses.count, "\(c.name)")
            XCTAssertEqual(r.stressesSurvived, r.stresses.filter(\.survives).count, "\(c.name)")
            for s in r.stresses {
                XCTAssertEqual(s.survives, s.depletionAge == nil,
                    "\(c.name): \(s.name) reports survives=\(s.survives) with depletionAge \(String(describing: s.depletionAge))")
            }
        }
    }

    /// Max safe spend is solved on the same path the stresses report, so it must be finite,
    /// non-negative, and consistent with the headroom figure shown beside it.
    func testMaxSafeSpendIsCoherentWithWhatIsShownBesideIt() {
        for c in matrix where c.eval.isSolvable {
            let r = c.eval.resilience
            XCTAssertGreaterThanOrEqual(r.maxSafeSpendUsd, 0, "\(c.name)")
            XCTAssertTrue(r.maxSafeSpendUsd.isFinite, "\(c.name)")
            guard r.currentSpendUsd > 0 else { continue }
            let implied = ((r.maxSafeSpendUsd - r.currentSpendUsd) / r.currentSpendUsd).bps
            XCTAssertEqual(r.spendHeadroomBps, implied, accuracy: 2,
                "\(c.name): headroom \(r.spendHeadroomBps) bps disagrees with the spend figures it is derived from")
        }
    }

    /// Retiring later moves the shock later, because the shock tracks the first RETIREMENT
    /// draw. Anchoring it on the savings window (the LATER of two retirements) or on any net
    /// outflow (a reserve funded in plan-year 1 is not a drawdown) both break this.
    func testTheShockTracksRetirementNotTheSavingsWindow() {
        let born = Engine.year(Engine.planningAsOf) - 51

        // Positive control: moving the PRIMARY's retirement moves the first draw, so the
        // shock must move with it.
        func depletion(retiringAt age: Int) -> Int? {
            var m = IntakeModel()
            m.adults = [{ var a = IntakeAdult(); a.birthYear = born
                          a.retirementAge = age; a.salaryUsd = 250_000; return a }()]
            m.retirementStartAge = age
            m.planToAge = 95; m.taxableUsd = 1_500_000
            m.retirementSpendingUsd = 300_000; m.annualSavingsUsd = 50_000
            return Engine.evaluate(m.buildHousehold()).resilience.stresses.compactMap(\.depletionAge).min()
        }
        let byRetirement = [58, 63, 68].compactMap { depletion(retiringAt: $0) }
        XCTAssertEqual(byRetirement.count, 3, "fixture check: all three plans deplete under stress")
        XCTAssertEqual(byRetirement, byRetirement.sorted(),
            "depletion must move later as retirement moves later (got \(byRetirement))")
        XCTAssertLessThan(byRetirement[0], byRetirement[2], "retiring ten years sooner must bring the shock forward")

        /// The discriminating case. The two candidate anchors coincide for a single adult
        /// whose retirement age IS the spending start, which is why the first version of
        /// this test passed a replay of the savings-window anchor.
        ///
        /// `householdSaveYears` is the LATER of the two retirements, and it gates exactly
        /// one term — `min(annualSavingsUsd, wages)`. With household savings AND the
        /// spouse's salary at zero it is economically inert, so moving the spouse's
        /// retirement age thirteen years changes the savings window and NOTHING else:
        /// same corpus, same goals, same filing status, same Medicare count, same required
        /// return. Any difference in the stressed outcome is the anchor moving.
        func stressed(spouseRetiresAt age: Int) -> [SequenceStress] {
            var m = IntakeModel()
            m.adults = [
                { var a = IntakeAdult(); a.name = "P"; a.birthYear = born
                  a.retirementAge = 62; a.salaryUsd = 250_000; return a }(),
                { var b = IntakeAdult(); b.name = "S"; b.birthYear = born
                  b.retirementAge = age; b.salaryUsd = 0; return b }(),
            ]
            m.retirementStartAge = 62
            m.planToAge = 95; m.taxableUsd = 4_000_000
            m.retirementSpendingUsd = 300_000
            m.annualSavingsUsd = 0                  // makes the savings window inert
            return Engine.evaluate(m.buildHousehold()).resilience.stresses
        }
        let windowShort = stressed(spouseRetiresAt: 62)   // saveYears == the first draw
        let windowLong  = stressed(spouseRetiresAt: 75)   // saveYears thirteen years later

        // Fixture check. Comparing only terminal balances would be vacuous here — a
        // household that depletes reports 0 under every anchor, so 0 == 0 proves nothing.
        // The arms must carry a signal that CAN differ: a mix of outcomes, not a wipeout.
        XCTAssertEqual(windowShort.count, Engine.stressSequences.count, "fixture check: the stresses ran")
        XCTAssertTrue(windowShort.contains { $0.depletionAge != nil },
                      "fixture check: no stress depletes, so depletion age cannot discriminate")
        XCTAssertTrue(windowShort.contains { $0.terminalBalanceUsd > 0 },
                      "fixture check: every arm is wiped out, so the terminal balance cannot discriminate")

        for (short, long) in zip(windowShort, windowLong) {
            XCTAssertEqual(short.depletionAge, long.depletionAge,
                "\(short.name): the spouse retiring thirteen years later moved depletion "
                + "\(String(describing: short.depletionAge)) → \(String(describing: long.depletionAge)) while "
                + "changing nothing economic — the shock is anchored on the savings window, not the first drawdown")
            XCTAssertEqual(short.terminalBalanceUsd, long.terminalBalanceUsd, accuracy: 1,
                "\(short.name): the spouse retiring thirteen years later moved the stressed terminal balance "
                + "\(short.terminalBalanceUsd) → \(long.terminalBalanceUsd) while changing nothing economic")
        }
    }

    /// And the other candidate anchor: ANY year with a net outflow. A reserve funded in
    /// plan year 1 is not the household drawing down, but it is an outflow — anchoring on
    /// it drops the shock onto an accumulator at peak balance, thirteen years before the
    /// first withdrawal.
    ///
    /// Isolated without a magic threshold by asking which DIRECTION the reserve moves the
    /// answer. Funding a reserve is a cost: money leaves in year 1 and never comes back, so
    /// under stress the plan can only end up the same or worse. Under the outflow anchor it
    /// ends up dramatically BETTER — the shock lands during accumulation and the plan has a
    /// decade to recover before it draws, so a household that adds an expense reports a
    /// stronger stressed balance than one that does not.
    func testFundingAReserveCannotImproveTheStressedOutcome() {
        func stressed(reserve: Usd) -> [SequenceStress] {
            var m = IntakeModel()
            m.adults = [{ var a = IntakeAdult(); a.birthYear = Engine.year(Engine.planningAsOf) - 51
                          a.retirementAge = 65; a.salaryUsd = 400_000; return a }()]
            m.retirementStartAge = 65; m.planToAge = 92
            m.taxableUsd = 5_000_000; m.retirementSpendingUsd = 260_000; m.annualSavingsUsd = 120_000
            m.emergencyReserveUsd = reserve
            return Engine.evaluate(m.buildHousehold()).resilience.stresses
        }
        let without = stressed(reserve: 0), with = stressed(reserve: 300_000)

        // Fixture check: the reserve has to actually move the anchor's input, or the two
        // arms are the same plan and the comparison is vacuous.
        let h = { var m = IntakeModel()
                  m.adults = [{ var a = IntakeAdult(); a.birthYear = Engine.year(Engine.planningAsOf) - 51
                                a.retirementAge = 65; a.salaryUsd = 400_000; return a }()]
                  m.retirementStartAge = 65; m.planToAge = 92
                  m.taxableUsd = 5_000_000; m.retirementSpendingUsd = 260_000
                  m.annualSavingsUsd = 120_000; m.emergencyReserveUsd = 300_000
                  return m.buildHousehold() }()
        let anyOutflow = h.goals.flatMap(\.outflows).filter { $0.amountUsd > 0 }.map(\.year).min()
        let firstSpend = h.goals.filter { $0.kind == .spending }
            .flatMap(\.outflows).filter { $0.amountUsd > 0 }.map(\.year).min()
        XCTAssertNotEqual(anyOutflow, firstSpend,
            "fixture check: the reserve must fall in a different year from the first draw, or the two anchors coincide")
        XCTAssertTrue(without.contains { $0.terminalBalanceUsd > 0 },
                      "fixture check: the plan must survive far enough for the comparison to carry a signal")

        for (bare, funded) in zip(without, with) {
            XCTAssertLessThanOrEqual(funded.terminalBalanceUsd, bare.terminalBalanceUsd + 1,
                "\(bare.name): funding a 300k reserve RAISED the stressed terminal "
                + "\(bare.terminalBalanceUsd) → \(funded.terminalBalanceUsd) — spending money cannot improve the "
                + "plan, so the shock moved onto the reserve year instead of the first drawdown")
        }
    }

    // MARK: - The frontier

    /// The plotted menu must be able to reach the ceiling the same chart quotes over it.
    /// Sweeping the curve at the household's ACTUAL funded ratio pinned an overfunded
    /// household's every point at the derisk floor, so the chart drew a 30% menu under a 60%
    /// caption — and `minDrawdownBps`, `hasTolerableBand` and the reachable-vs-needed verdict
    /// were all read off that degenerate curve.
    func testTheCurveReachesTheCeilingTheChartQuotes() {
        for c in matrix where c.eval.isSolvable {
            let f = Engine.frontier(c.eval, cme: cme)
            guard let quoted = f.frontierToleranceEquityBps else { continue }
            let top = f.curve.map(\.equityBps).max() ?? 0
            XCTAssertGreaterThanOrEqual(top, quoted,
                "\(c.name): the chart quotes \(quoted) bps over a menu topping out at \(top)")
        }
    }

    /// The curve spans a real range of risk on every household. A flat curve makes every
    /// figure derived from it meaningless while looking perfectly well-formed.
    func testTheCurveSpansARealRangeOfRisk() {
        for c in matrix where c.eval.isSolvable {
            let f = Engine.frontier(c.eval, cme: cme)
            let equities = f.curve.map(\.equityBps), drawdowns = f.curve.map(\.drawdownBps)
            XCTAssertGreaterThan((equities.max() ?? 0) - (equities.min() ?? 0), 3000,
                "\(c.name): the menu spans almost no equity range")
            XCTAssertGreaterThan((drawdowns.max() ?? 0) - (drawdowns.min() ?? 0), 500,
                "\(c.name): every portfolio on the menu carries the same risk")
        }
    }

    /// The stated-tolerance mapping is monotonic with no cliff. The solver clamps realized
    /// equity at `sleeveBudget − cashFloor`, so the sweep plateaus; taking the highest
    /// qualifying ceiling turned that flat tail into a jump — 3600 bps of stated tolerance
    /// mapped to 7500 while 3700 mapped to 9500, printing "95% equity" in the client's IPS.
    func testStatedToleranceMapsSmoothlyWithNoCliff() {
        for c in matrix where c.eval.isSolvable {
            let curve = Engine.drawdownByCeiling(c.eval.household, ladder: c.eval.ladder)
            guard let plateauTop = curve.filter({ $0.drawdownBps == curve.map(\.drawdownBps).max()! })
                .map(\.ceilingBps).min() else { continue }
            var previous: Bps? = nil
            for level in stride(from: 1500, through: 6000, by: 100) {
                let e = Engine.toleranceEquityBps(fromCurve: curve, maxDrawdownBps: level)
                XCTAssertLessThanOrEqual(e, plateauTop,
                    "\(c.name): \(level) bps of tolerance reports \(e), beyond the \(plateauTop) the solver can build")
                defer { previous = e }
                guard let previous else { continue }
                XCTAssertGreaterThanOrEqual(e, previous, "\(c.name): the mapping is not monotonic at \(level)")
                XCTAssertLessThanOrEqual(e - previous, 500,
                    "\(c.name): a 100 bps change in tolerance jumped the ceiling \(previous) → \(e)")
            }
        }
    }

    // MARK: - Coverage

    /// The states these invariants are about must be reachable, or they pass over households
    /// where the question never arises. The rebalance batch missed three replayed defects for
    /// exactly this reason — no fixture held a ladder, a tilt, or idle cash.
    func testTheMatrixReachesTheStatesTheseInvariantsAreAbout() {
        let solvable = matrix.filter { $0.eval.isSolvable }
        XCTAssertGreaterThanOrEqual(solvable.count, 8, "too few solvable households to stress")
        XCTAssertTrue(solvable.contains { !$0.eval.resilience.stresses.isEmpty }, "no household is stressed at all")
        XCTAssertTrue(solvable.contains { $0.eval.resilience.stresses.contains { !$0.survives } },
                      "no household depletes under any stress — the survival assertions are vacuous")
        XCTAssertTrue(solvable.contains { $0.eval.balanceSheet.fundedRatioBps > Engine.fundedFloorBps },
                      "no OVERFUNDED household — the frontier glide defect is unreachable")
        XCTAssertTrue(solvable.contains { $0.eval.balanceSheet.fundedRatioBps < Engine.fundedFloorBps },
                      "no underfunded household")
        // The sequence anchor has three candidates (first draw / savings window / any net
        // outflow) and they only differ where a household's first outflow of ANY kind is
        // not its first retirement draw. Every original matrix household had them equal.
        XCTAssertTrue(matrix.contains { c in
            let h = c.eval.household
            let anyOut = h.goals.flatMap(\.outflows).filter { $0.amountUsd > 0 }.map(\.year).min()
            let firstSpend = h.goals.filter { $0.kind == .spending }
                .flatMap(\.outflows).filter { $0.amountUsd > 0 }.map(\.year).min()
            return anyOut != nil && anyOut != firstSpend
        }, "no household holds a non-spending outflow before its first draw — the outflow anchor is unreachable")
    }
}
