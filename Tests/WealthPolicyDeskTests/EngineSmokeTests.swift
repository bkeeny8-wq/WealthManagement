import XCTest
@testable import WealthPolicyDesk

/// Smoke + characterization: confirms the engine compiles and evaluates, prints the
/// sample household's headline figures (to seed golden-master assertions), and checks
/// the engine is deterministic.
final class EngineSmokeTests: XCTestCase {

    func testSampleEvaluatesAndPrintsHeadlines() {
        let e = Engine.evaluate(Seed.sampleHousehold)
        print("""
        --- Harrisons (Seed.sampleHousehold) headline figures ---
        requiredRealReturnBps      = \(e.requiredReturn.requiredRealReturnBps)
        requiredRealReturnPreTaxBps= \(e.requiredReturn.requiredRealReturnPreTaxBps)
        fundedRatioBps             = \(e.balanceSheet.fundedRatioBps)
        afterTaxNetWorthUsd        = \(e.balanceSheet.afterTaxNetWorthUsd)
        grossNetWorthUsd           = \(e.balanceSheet.grossNetWorthUsd)
        netFixedIncomeUsd          = \(e.netFixedIncomeUsd)
        bindingEquityBps           = \(e.riskProfile?.bindingEquityBps ?? -1)
        capacityEquityBps          = \(e.riskProfile?.capacityEquityBps ?? -1)
        toleranceImpliedEquityBps  = \(e.riskProfile?.toleranceImpliedEquityBps ?? -1)
        allocation rows            = \(e.allocation.count)
        allocation targetBps sum   = \(e.allocation.reduce(0) { $0 + $1.targetBps })
        findings (hard/soft)       = \(e.findings.filter { $0.severity == .hard }.count)/\(e.findings.filter { $0.severity == .soft }.count)
        spending goals             = \(e.household.goals.filter { $0.kind == .spending }.count)
        ---------------------------------------------------------
        """)
        XCTAssertGreaterThan(e.household.portfolioValueUsd, 0)
    }

    func testEngineIsDeterministic() {
        let a = Engine.evaluate(Seed.sampleHousehold)
        let b = Engine.evaluate(Seed.sampleHousehold)
        XCTAssertEqual(a.requiredReturn.requiredRealReturnBps, b.requiredReturn.requiredRealReturnBps)
        XCTAssertEqual(a.balanceSheet.fundedRatioBps, b.balanceSheet.fundedRatioBps)
        XCTAssertEqual(a.balanceSheet.afterTaxNetWorthUsd, b.balanceSheet.afterTaxNetWorthUsd)
        XCTAssertEqual(a.riskProfile?.bindingEquityBps, b.riskProfile?.bindingEquityBps)
        XCTAssertEqual(a.allocation.map(\.targetBps), b.allocation.map(\.targetBps))
    }
}
