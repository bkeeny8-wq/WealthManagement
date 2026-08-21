import XCTest
@testable import WealthPolicyDesk

/// Tactical-tilt application — `applyTacticalTilts` deviates sleeve targets within a
/// governed budget, funding each tilt PRO-RATA from the same role so the equity/bond
/// risk split the forecast-free solver set is never changed, only composition. Seed
/// omits committed tilts, so these build synthetic ones and lock the budget invariants.
final class TacticalTiltTests: XCTestCase {

    private var policy: InvestmentPolicy { Seed.legacyPolicy }
    private var budget: TiltPolicy { Seed.tiltPolicy }

    private func total(_ p: InvestmentPolicy) -> Bps { p.sleeves.reduce(0) { $0 + $1.targetBps } }
    private func roleTotals(_ p: InvestmentPolicy) -> [AssetRole: Bps] {
        Dictionary(grouping: p.sleeves, by: { $0.role }).mapValues { $0.reduce(0) { $0 + $1.targetBps } }
    }
    private func target(_ p: InvestmentPolicy, _ id: String) -> Bps { p.sleeves.first { $0.id == id }?.targetBps ?? -1 }
    private func tilt(_ sleeve: String, _ dev: Bps, status: TacticalTiltAction.Status = .committed) -> TacticalTiltAction {
        TacticalTiltAction(sleeveId: sleeve, deviationBps: dev, sourceName: "test", thesis: "test thesis", status: status)
    }

    // MARK: - Identity

    func testNoCommittedTiltsLeavesThePolicyUnchanged() {
        XCTAssertEqual(Engine.applyTacticalTilts(policy, tilts: []).sleeves, policy.sleeves)
        // A merely-staged tilt is not yet in force.
        XCTAssertEqual(Engine.applyTacticalTilts(policy, tilts: [tilt("us_sector_tilt", 300, status: .staged)]).sleeves,
                       policy.sleeves)
    }

    // MARK: - The core invariant: composition changes, risk split does not

    func testTotalAndRoleSumsArePreserved() {
        let out = Engine.applyTacticalTilts(policy, tilts: [tilt("us_sector_tilt", 300)])
        XCTAssertEqual(total(out), 8000, "the sleeve budget is conserved")
        XCTAssertNotEqual(target(out, "us_sector_tilt"), target(policy, "us_sector_tilt"),
                          "the tilted sleeve must actually move")
        // Every role's total is untouched — the tilt is funded within the role.
        let before = roleTotals(policy), after = roleTotals(out)
        for (role, sum) in before {
            XCTAssertEqual(after[role], sum, "role \(role) sum drifted")
        }
    }

    func testNoSleeveGoesNegative() {
        // An underweight larger than a small sleeve is clamped at zero, never negative.
        let out = Engine.applyTacticalTilts(policy, tilts: [tilt("em_debt", -400)])  // em_debt is 200bp
        XCTAssertEqual(target(out, "em_debt"), 0, "the underweight is clamped to the sleeve's own size")
        for s in out.sleeves { XCTAssertGreaterThanOrEqual(s.targetBps, 0, "\(s.id) went negative") }
        XCTAssertEqual(total(out), 8000)
    }

    // MARK: - Budget clamps

    func testSingleTiltIsCappedAtTheSingleBudget() {
        // Request +900 on a no-max growth sleeve; only the single cap should land.
        let out = Engine.applyTacticalTilts(policy, tilts: [tilt("us_mid_small", 900)])
        let moved = target(out, "us_mid_small") - target(policy, "us_mid_small")
        XCTAssertEqual(moved, budget.maxSingleSectorDeviationBps,
                       "a single tilt cannot exceed the single-sector budget")
        XCTAssertEqual(total(out), 8000)
    }

    func testOverBudgetSetIsScaledToTheTotalBudget() {
        // Three +400 tilts request 1200bp of deviation against a smaller total budget.
        let tilts = [tilt("us_mid_small", 400), tilt("intl_developed", 400), tilt("intl_small", 400)]
        let out = Engine.applyTacticalTilts(policy, tilts: tilts)
        // Conservation forces total |change| = 2 × the net overweight applied; the total
        // budget caps that overweight, so |change| ≤ 2×budget. Unscaled (1200bp) would be
        // 2400 — well over the bound — so passing here proves the scaling engaged.
        let absChange = zip(out.sleeves, policy.sleeves).reduce(0) { $0 + abs($1.0.targetBps - $1.1.targetBps) }
        XCTAssertGreaterThan(absChange, 0, "the tilts must apply, not be dropped")
        XCTAssertLessThanOrEqual(absChange, 2 * budget.maxTotalAbsoluteDeviationBps + 50,
                                 "the set is scaled to fit the total budget")
        XCTAssertEqual(total(out), 8000)
        let before = roleTotals(policy), after = roleTotals(out)
        for (role, sum) in before { XCTAssertEqual(after[role], sum) }
    }

    // MARK: - Determinism

    func testApplicationIsDeterministic() {
        let tilts = [tilt("us_sector_tilt", 300), tilt("intl_developed", -200)]
        XCTAssertEqual(Engine.applyTacticalTilts(policy, tilts: tilts).sleeves,
                       Engine.applyTacticalTilts(policy, tilts: tilts).sleeves)
    }
}
