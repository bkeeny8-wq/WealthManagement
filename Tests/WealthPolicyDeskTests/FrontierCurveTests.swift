import XCTest
@testable import WealthPolicyDesk

/// The frontier chart plots the MENU of portfolios a household could choose from, and
/// quotes a tolerance-implied ceiling over it. The two came off different bases: the curve
/// was swept at the household's ACTUAL funded ratio, so an overfunded household's glide
/// pinned every point at the derisk floor, while the quoted ceiling was read from the
/// (correctly floor-swept) risk profile. The chart drew a menu topping out at 30% equity
/// underneath a caption saying the highest tolerable portfolio is 60% equity — and
/// `minDrawdownBps`, `hasTolerableBand` and the reachable-vs-needed verdict were all read
/// off that degenerate curve.
final class FrontierCurveTests: XCTestCase {

    private var cme: CapitalMarketSet {
        Engine.capitalMarketExpectations(Seed.macroIndicators, regime: Engine.macroRegime(Seed.macroIndicators))
    }

    private func chart(scaledBy mult: Double) -> (FrontierChart, Evaluation) {
        var h = Seed.sampleHousehold
        h.positions = h.positions.map { var p = $0; p.marketValueUsd *= mult; p.costBasisUsd *= mult; return p }
        let e = Engine.evaluate(h)
        return (Engine.frontier(e, cme: cme), e)
    }

    /// The headline contradiction: the plotted menu must be able to reach the ceiling the
    /// same chart quotes over it.
    func testTheCurveReachesTheCeilingTheChartQuotes() {
        for mult in [1.0, 2.5, 5.0] {
            let (f, _) = chart(scaledBy: mult)
            guard let quoted = f.frontierToleranceEquityBps else { continue }
            let top = f.curve.map(\.equityBps).max() ?? 0
            XCTAssertGreaterThanOrEqual(top, quoted,
                                        "at \(mult)x the chart quotes \(quoted) bps over a menu topping out at \(top)")
        }
    }

    /// Being overfunded must not shrink the MENU. The glide decides how much of the ceiling
    /// to use; it is not a statement about what could be built.
    func testBeingOverfundedDoesNotCollapseTheMenu() {
        let (poor, poorEval) = chart(scaledBy: 1.0)
        let (rich, richEval) = chart(scaledBy: 2.5)
        XCTAssertGreaterThan(richEval.balanceSheet.fundedRatioBps, Engine.fundedFloorBps,
                             "fixture check: the scaled household is overfunded")
        XCTAssertLessThan(poorEval.balanceSheet.fundedRatioBps, richEval.balanceSheet.fundedRatioBps)

        let poorTop = poor.curve.map(\.equityBps).max() ?? 0
        let richTop = rich.curve.map(\.equityBps).max() ?? 0
        XCTAssertGreaterThan(richTop, 5000,
                             "an overfunded household's menu collapsed to the derisk floor (top \(richTop) bps)")
        XCTAssertLessThanOrEqual(abs(poorTop - richTop), 1000,
                                 "funded status moved the menu, not just the recommendation (\(poorTop) vs \(richTop))")
    }

    /// A flat curve makes every downstream read — minimum drawdown, tolerable band,
    /// reachable return — meaningless, so the menu must span real risk at any funded level.
    func testTheCurveSpansARangeOfRiskAtEveryFundedLevel() {
        for mult in [1.0, 2.5, 5.0] {
            let (f, _) = chart(scaledBy: mult)
            let equities = f.curve.map(\.equityBps), drawdowns = f.curve.map(\.drawdownBps)
            XCTAssertGreaterThan((equities.max() ?? 0) - (equities.min() ?? 0), 3000,
                                 "at \(mult)x the menu spans almost no equity range")
            XCTAssertGreaterThan((drawdowns.max() ?? 0) - (drawdowns.min() ?? 0), 500,
                                 "at \(mult)x every portfolio on the menu carries the same risk")
        }
    }
}
