import XCTest
@testable import WealthPolicyDesk

/// Money cannot move between accounts. Proceeds from a sale in one spouse's IRA cannot buy
/// anything in the other's, and nothing inside a retirement account can fund a taxable
/// purchase without a distribution. The rebalancer raised one POOLED figure and then placed
/// each buy wherever the sleeve's location preference pointed, so on the shipped sample it
/// proposed selling $233,950 in the taxable brokerage and spending $119,332 of it inside the
/// IRA — a trade no custodian can execute.
final class RebalanceAccountBoundaryTests: XCTestCase {

    private func makePlan(_ h: Household) -> RebalancePlan {
        let eval = Engine.evaluate(h)
        var p = eval.legacyPolicy
        p.sleeves = p.sleeves.map { s in
            var s = s
            if let row = eval.allocation.first(where: { $0.sleeveId == s.id }) { s.targetBps = row.targetBps }
            return s
        }
        return Engine.rebalancePlan(eval.household, policy: p, tax: eval.tax, asOf: eval.asOf)
    }

    private func netByAccount(_ plan: RebalancePlan) -> [String: (sold: Usd, bought: Usd)] {
        var out: [String: (sold: Usd, bought: Usd)] = [:]
        for t in plan.trades {
            var e = out[t.accountId] ?? (0, 0)
            if t.side == .sell { e.sold += t.amountUsd } else { e.bought += t.amountUsd }
            out[t.accountId] = e
        }
        return out
    }

    /// The invariant: no account may spend more than it raised.
    func testNoAccountSpendsMoreThanItRaised() {
        for h in [Seed.sampleHousehold, twoOwnerHousehold()] {
            for (accountId, net) in netByAccount(makePlan(h)) {
                XCTAssertLessThanOrEqual(net.bought, net.sold + 0.5,
                    "\(accountId) buys \(Int(net.bought)) having raised only \(Int(net.sold)) — that money has to come from somewhere")
            }
        }
    }

    /// And an account that sold nothing may buy nothing.
    func testAnAccountThatSoldNothingBuysNothing() {
        for h in [Seed.sampleHousehold, twoOwnerHousehold()] {
            for (accountId, net) in netByAccount(makePlan(h)) where net.sold == 0 {
                XCTAssertEqual(net.bought, 0, accuracy: 0.5,
                               "\(accountId) buys \(Int(net.bought)) with no proceeds of its own")
            }
        }
    }

    /// A couple with a separate IRA each: cash raised in one spouse's account must never be
    /// spent in the other's. This is the case the lump-sum account model could not even
    /// express before retirement balances gained an owner.
    private func twoOwnerHousehold() -> Household {
        var m = IntakeModel()
        var a = IntakeAdult(); a.name = "Ada"; a.birthYear = 1968; a.retirementAge = 65
        a.salaryUsd = 250_000; a.traditionalUsd = 900_000; a.rothUsd = 120_000
        var b = IntakeAdult(); b.name = "Ben"; b.birthYear = 1970; b.retirementAge = 65
        b.salaryUsd = 180_000; b.traditionalUsd = 700_000; b.rothUsd = 80_000
        m.adults = [a, b]
        m.taxableUsd = 1_100_000
        m.currentEquityPct = 0.95        // heavily overweight equity, so there is real work to do
        m.retirementSpendingUsd = 200_000
        return m.buildHousehold()
    }

    func testOneSpousesIraNeverFundsTheOthers() {
        let h = twoOwnerHousehold()
        XCTAssertNotNil(h.account("acct_trad"), "fixture check: Ada has an IRA")
        XCTAssertNotNil(h.account("acct_trad_1"), "fixture check: Ben has his own")

        let net = netByAccount(makePlan(h))
        for (accountId, e) in net {
            XCTAssertLessThanOrEqual(e.bought, e.sold + 0.5,
                "\(accountId) spent money raised in another account")
        }
    }

    /// Totals must still reconcile, and the household-level identity must hold.
    func testTotalsStillReconcile() {
        for h in [Seed.sampleHousehold, twoOwnerHousehold()] {
            let plan = makePlan(h)
            let buys = plan.trades.filter { $0.side == .buy }.reduce(0) { $0 + $1.amountUsd }
            let sells = plan.trades.filter { $0.side == .sell }.reduce(0) { $0 + $1.amountUsd }
            XCTAssertEqual(plan.totalBuysUsd, buys, accuracy: 0.5)
            XCTAssertEqual(plan.totalSellsUsd, sells, accuracy: 0.5)
            XCTAssertLessThanOrEqual(plan.totalBuysUsd, plan.totalSellsUsd + 0.5,
                                     "the plan cannot buy more than it sold in aggregate either")
        }
    }

    /// What cannot be funded is reported, not silently dropped. A sleeve best held in an
    /// account with nothing to sell stays underweight until a contribution lands there.
    func testUnfundableBuysAreReportedAsAFundingGap() {
        let plan = makePlan(Seed.sampleHousehold)
        XCTAssertGreaterThan(plan.fundingGapUsd, 0, "fixture check: the sample cannot fund every underweight")
        XCTAssertTrue(plan.warnings.contains { $0.contains("could be funded") },
                      "the advisor has to be told the rebalance is partial")
    }

    /// The warning must not assert a cause that is false. On the shipped sample exactly ONE
    /// account trades and spends everything it raised — nothing is stranded by an account
    /// boundary there, the sells simply do not raise enough. Naming the wrong reason is worse
    /// than naming none, and this test previously demanded the wrong one.
    func testTheShortfallNamesTheCauseThatIsActuallyTrue() {
        let plan = makePlan(Seed.sampleHousehold)
        let accountsTrading = Set(plan.trades.map(\.accountId))
        XCTAssertEqual(accountsTrading.count, 1, "fixture check: one account does all the trading")
        XCTAssertEqual(plan.excessCashUsd, 0, accuracy: 1, "fixture check: it spends everything it raised")

        let shortfall = plan.warnings.first { $0.contains("could be funded") }
        XCTAssertNotNil(shortfall)
        XCTAssertFalse(shortfall?.contains("Money cannot move between accounts") ?? true,
                       "no money was stranded by an account boundary here — the sells just did not raise enough")
        XCTAssertTrue(shortfall?.contains("do not raise enough") ?? false)
    }

    /// And when a boundary IS the cause, it says so.
    ///
    /// The previous version was vacuous: it bailed on `guard let shortfall … else { return }`
    /// because its fixture had no funding gap at all, so deleting the entire "name the
    /// boundary cause" branch left 305 tests green. Location preference is only a PREFERENCE,
    /// so cash never strands for want of a willing sleeve — it strands below the minimum
    /// trade size, which is what this builds.
    func testTheBoundaryCauseIsNamedWhenItIsTheRealOne() {
        func sleeve(_ id: String, _ ticker: String, target: Bps, prefs: [AccountTaxTreatment]) -> Sleeve {
            Sleeve(id: id, label: id, tier: .satellite, role: .growth, targetBps: target,
                   bandBps: 50, maxBps: 10000, taxEfficiency: .moderate,
                   locationPreference: prefs, liquidityClass: .daily,
                   instruments: [.init(ticker: ticker, role: .primary)], rationale: "")
        }
        var policy = Seed.legacyPolicy
        policy.sleeves = [sleeve("zz_over", "OVER", target: 0, prefs: [.taxable, .taxDeferred]),
                          sleeve("aa_under", "UNDER", target: 9960, prefs: [.taxable])]
        policy.altBudgets = []

        var h = Seed.sampleHousehold
        h.accounts = [Account(id: "acct_taxable", label: "Brokerage", treatment: .taxable),
                      Account(id: "acct_ira", label: "IRA", treatment: .taxDeferred)]
        // The IRA's slice sells first (sheltered lots rank ahead) but is below minTradeUsd,
        // so its proceeds strand in an account whose cash cannot reach the taxable buy.
        h.positions = [
            Position(id: "ira", accountId: "acct_ira", ticker: "OVER", sleeveId: "zz_over",
                     marketValueUsd: 800, costBasisUsd: 800, layer: .strategic,
                     disposition: .consume, holdToStepUp: false),
            Position(id: "tax", accountId: "acct_taxable", ticker: "OVER", sleeveId: "zz_over",
                     marketValueUsd: 200_000, costBasisUsd: 200_000, layer: .strategic,
                     disposition: .consume, holdToStepUp: false),
        ]
        h.tacticalTilts = []

        let plan = Engine.rebalancePlan(h, policy: policy, tax: Seed.tax2026, asOf: Engine.planningAsOf)
        XCTAssertGreaterThan(plan.excessCashUsd, 0, "fixture check: the IRA's slice strands")
        guard let shortfall = plan.warnings.first(where: { $0.contains("could be funded") }) else {
            return XCTFail("a shortfall must be reported when cash strands")
        }
        XCTAssertTrue(shortfall.contains("Money cannot move between accounts"),
                      "stranded cash must be explained as an account boundary, not as insufficient sells")
    }
}
