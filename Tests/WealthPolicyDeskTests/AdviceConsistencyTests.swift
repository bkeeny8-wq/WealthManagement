import XCTest
@testable import WealthPolicyDesk

/// Advice that contradicts the numbers printed beside it. Each of these went live when a
/// fix made a previously-unreachable branch reachable, or when a measure changed meaning
/// and its narration did not follow.
final class AdviceConsistencyTests: XCTestCase {

    // MARK: - The SALT-window note must be about the HOUSEHOLD

    /// `yearsUntilSaltReversion` is a property of the tax parameter set, never of the
    /// client, so gating the "keep the mortgage through the window" advice on it alone fired
    /// for everyone. The old hardcoded state profile made every homeowner max out SALT,
    /// which kept the branch unreachable; reading the client's real state and giving made it
    /// reachable. This is the verifier's exact repro.
    func testAModestTexasHomeownerDoesNotItemize() {
        var m = IntakeModel()
        m.adults = [{ var a = IntakeAdult(); a.birthYear = 1975; a.retirementAge = 65; a.salaryUsd = 120_000; return a }()]
        m.filingStatus = .mfj
        m.state = "TX"
        m.ownsHome = true
        m.homeValueUsd = 300_000
        m.mortgageBalanceUsd = 150_000
        m.mortgageRateBps = 310
        m.annualGivingUsd = 0

        let h = m.buildHousehold()
        let it = Engine.analyzeItemization(Engine.itemizationInput(for: h, asOf: Engine.planningAsOf), tax: Seed.tax2026)
        XCTAssertFalse(it.itemizes,
                       "$\(Int(it.totalItemizedUsd)) of deductions cannot beat a $\(Int(it.standardDeductionUsd)) standard deduction")
        XCTAssertEqual(it.marginalValueOfMortgageInterestBps, 0,
                       "the next dollar of mortgage interest is worth nothing to a non-itemizer")
        XCTAssertNotNil(it.yearsUntilSaltReversion,
                        "the reversion is still scheduled — which is why gating on it alone fired for this household")
    }

    /// And the sample, which does itemize, must still get the advice.
    func testAHighTaxStateItemizerStillGetsTheSaltWindowAdvice() {
        let it = Engine.analyzeItemization(
            Engine.itemizationInput(for: Seed.sampleHousehold, asOf: Engine.planningAsOf), tax: Seed.tax2026)
        XCTAssertTrue(it.itemizes, "the New Jersey sample itemizes")
        XCTAssertGreaterThan(it.marginalValueOfMortgageInterestBps, 0)
    }

    // MARK: - The liquidity floor is cash and fixed income, everywhere it is described

    /// The measure became cash + fixed income and the rule started firing, but five strings
    /// still told the client it was "daily-liquid assets" — so the shipped sample's IPS
    /// printed that its daily-liquid assets ($2.36M) fell short of a $1.29M requirement they
    /// exceed by a million dollars. The seeded rule text and the teaching copy are both in
    /// the engine module, so they can be asserted directly.
    func testTheSeededRuleDescribesTheMeasureItActuallyUses() {
        guard let rule = Seed.policyConstraints.first(where: { $0.id == "liquidity_floor" }) else {
            return XCTFail("the liquidity_floor rule is missing")
        }
        XCTAssertFalse(rule.description.lowercased().contains("daily-liquid"),
                       "the rule still describes itself as daily-liquid: \(rule.description)")
        XCTAssertTrue(rule.description.lowercased().contains("fixed income"),
                      "the rule must name what it actually measures")
    }

    func testTheLadderTeachingCopyDoesNotPromiseEquitiesCount() {
        let help = Teach.help("ladder")
        let all = [help.what, help.moves, help.watch].joined(separator: " ").lowercased()
        XCTAssertFalse(all.contains("daily-liquid"),
                       "the ladder teaching copy still describes the old measure")
        XCTAssertTrue(all.contains("fixed income") || all.contains("cash"),
                      "it must name cash and fixed income as the funding source")
    }

    /// The finding the rule raises and the measure it is raised against must agree — this is
    /// what made the sample state both semantics on one household.
    func testTheLiquidityFindingAgreesWithTheMeasureThatRaisedIt() {
        let e = Engine.evaluate(Seed.sampleHousehold)
        let defensive = Engine.defensiveLiquidUsd(e.household)
        XCTAssertEqual(e.ladder.availableDefensiveUsd, defensive, accuracy: 0.5)
        if let finding = e.findings.first(where: { $0.ruleId == "liquidity_floor" }) {
            XCTAssertFalse(finding.detail.lowercased().contains("daily-liquid"),
                           "the finding narrates the old measure: \(finding.detail)")
        }
    }
}
