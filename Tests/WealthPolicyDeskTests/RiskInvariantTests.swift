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

    /// Max safe spend and the stress table are solved by different code — the first by bisecting
    /// a spending multiplier, the second by running the pattern at mult = 1 — so they can be
    /// checked against each other. The bisection accepts a multiplier only when the worst stress
    /// both survives AND ends at or above the legacy floor, so a household that already clears
    /// that bar at its CURRENT spending must have non-negative headroom, and one that does not
    /// must have negative headroom. Neither side is derived from the other.
    ///
    /// This replaces an assertion that recomputed `(maxSafe - current) / current` and compared it
    /// to `spendHeadroomBps` — which Resilience.swift computes as exactly that expression from
    /// exactly those two published Doubles. It was an algebraic identity: true for every possible
    /// value, unfalsifiable by any behaviour of the solve.
    func testMaxSafeSpendAgreesWithTheStressTableAboutWhetherThePlanClears() {
        var clearing = 0, failing = 0
        // Deliberately NOT filtered to solvable households. The required return is solved to
        // exhaust the corpus down to the legacy floor, so a solvable plan sits on the edge by
        // construction and a bad sequence always pushes it under — every solvable household in
        // this matrix has negative headroom. The positive branch exists only where the plan is
        // so overfunded that the bisection runs off its floor sentinel, which is exactly the
        // case `isSolvable` excludes. Filtering it out left half this assertion vacuous.
        for c in matrix {
            let r = c.eval.resilience
            XCTAssertTrue(r.maxSafeSpendUsd.isFinite, "\(c.name): max safe spend is not a number")
            XCTAssertGreaterThanOrEqual(r.maxSafeSpendUsd, 0, "\(c.name)")
            guard r.currentSpendUsd > 0, !r.stresses.isEmpty else { continue }

            let clearsToday = r.stresses.allSatisfy { $0.survives && $0.terminalBalanceUsd >= r.legacyFloorUsd }
            if clearsToday {
                clearing += 1
                XCTAssertGreaterThanOrEqual(r.maxSafeSpendUsd, r.currentSpendUsd * 0.999,
                    "\(c.name): every stress survives at the current \(r.currentSpendUsd) and still ends above the "
                    + "floor, yet the safe-spend solve says the most this plan can afford is \(r.maxSafeSpendUsd)")
            } else {
                failing += 1
                XCTAssertLessThanOrEqual(r.maxSafeSpendUsd, r.currentSpendUsd * 1.001,
                    "\(c.name): a stress depletes or lands below the floor at the current \(r.currentSpendUsd), "
                    + "yet the safe-spend solve says \(r.maxSafeSpendUsd) is affordable")
            }
        }
        // Both sides of the comparison must occur, or one branch is never exercised.
        XCTAssertGreaterThan(clearing, 0, "no household clears every stress — the non-negative-headroom branch is vacuous")
        XCTAssertGreaterThan(failing, 0, "no household fails a stress — the negative-headroom branch is vacuous")
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

    /// The anchor, asserted directly rather than inferred. Three definitions were plausible —
    /// the first retirement draw, the savings window (the LATER of two retirements), and any year
    /// with a net outflow — and they produce the same SHAPE of output, differing only in where
    /// the pattern lands.
    ///
    /// An earlier version of this test tried to separate them through terminal balances, on the
    /// ground that funding a reserve is a cost and so can only leave a stressed plan the same or
    /// worse. That is NOT an invariant of this engine: adding the reserve re-solves the required
    /// return upward and `stressPath` re-centres the whole pattern on the higher rate, so the
    /// corpus compounds faster for the entire horizon. A sweep of 81 households found 10 where a
    /// $300k reserve RAISED the stressed terminal. The old test passed only because its one
    /// fixture happened to sit on the other side of that line.
    func testTheShockLandsOnTheFirstRetirementDraw() {
        for c in matrix where c.eval.isSolvable {
            let h = c.eval.household
            let horizon = max(1, h.goals.compactMap { $0.horizonYears }.max() ?? 30)
            let firstSpend = h.goals.filter { $0.kind == .spending }
                .flatMap(\.outflows).filter { $0.amountUsd > 0 }.map(\.year).min()
            let expected = min(max(1, firstSpend ?? 1), horizon)
            XCTAssertEqual(c.eval.resilience.shockStartsAtPlanYear, expected,
                "\(c.name): the bad-return pattern starts in plan year "
                + "\(c.eval.resilience.shockStartsAtPlanYear), but the plan's first retirement draw is "
                + "year \(String(describing: firstSpend))")
        }
    }

    /// And the state that separates the first-draw anchor from the other two must be REACHABLE,
    /// or the assertion above holds for every household by coincidence.
    func testTheMatrixSeparatesTheThreeCandidateAnchors() {
        var drawAfterAnOutflow = 0, drawBeforeTheSavingsWindowEnds = 0
        for c in matrix {
            let h = c.eval.household
            let anyOut = h.goals.flatMap(\.outflows).filter { $0.amountUsd > 0 }.map(\.year).min()
            let firstSpend = h.goals.filter { $0.kind == .spending }
                .flatMap(\.outflows).filter { $0.amountUsd > 0 }.map(\.year).min()
            if let a = anyOut, let f = firstSpend, a != f { drawAfterAnOutflow += 1 }
            if let f = firstSpend, Engine.householdSaveYears(h, asOf: c.eval.asOf) > f { drawBeforeTheSavingsWindowEnds += 1 }
        }
        XCTAssertGreaterThan(drawAfterAnOutflow, 0,
            "no household holds a non-spending outflow before its first draw — the any-outflow anchor is unreachable")
        XCTAssertGreaterThan(drawBeforeTheSavingsWindowEnds, 0,
            "no household's savings window outlasts its first draw — the savings-window anchor is unreachable")
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
