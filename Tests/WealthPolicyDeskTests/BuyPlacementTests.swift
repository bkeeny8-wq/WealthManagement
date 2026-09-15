import XCTest
@testable import WealthPolicyDesk

/// Which sleeve an account's cash funds, and what the ticket says about where it landed.
/// Money cannot cross an account boundary, so a second-best location is a real and often
/// unavoidable outcome — the ordering has to be defensible and the ticket has to be honest
/// about it.
final class BuyPlacementTests: XCTestCase {

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

    /// A sleeve that does not list an account's treatment AT ALL must rank behind every
    /// sleeve that does, however far down that sleeve's list the treatment appears. Ranking
    /// a miss as `locationPreference.count` inverted that: a sleeve permitting only
    /// tax-deferred scored 1 for a taxable account, beating a sleeve that permits taxable
    /// but ranks it third (score 2) — so the account funded the holding it is the WORST home
    /// for, ahead of one it is a legitimate home for.
    ///
    /// Driven through the real allocator, not a local re-implementation of the rank: with
    /// only enough cash for one of them, the permitted sleeve must be the one funded.
    func testTheAllocatorFundsTheSleeveThisAccountCanActuallyHold() {
        func sleeve(_ id: String, _ prefs: [AccountTaxTreatment], _ ticker: String, target: Bps) -> Sleeve {
            Sleeve(id: id, label: id, tier: .satellite, role: .growth, targetBps: target,
                   bandBps: 50, maxBps: 10000, taxEfficiency: .moderate,
                   locationPreference: prefs, liquidityClass: .daily,
                   instruments: [.init(ticker: ticker, role: .primary)], rationale: "")
        }
        var policy = Seed.legacyPolicy
        policy.sleeves = [
            sleeve("zz_sell", [.taxable], "SELLME", target: 0),          // fully overweight -> raises cash
            sleeve("aa_forbids", [.taxDeferred], "AAA", target: 5000),   // sorts FIRST alphabetically
            sleeve("bb_permits", [.taxDeferred, .taxFree, .taxable], "BBB", target: 5000),
        ]
        policy.altBudgets = []

        var h = Seed.sampleHousehold
        h.accounts = [Account(id: "acct_taxable", label: "Brokerage", treatment: .taxable)]
        // Most of the overweight is held out, so the cash raised cannot fund both underweight
        // sleeves. Which one gets it is then decided purely by the location ranking — and the
        // forbidden sleeve sorts FIRST alphabetically, so a correct ranking is the only thing
        // that can put the permitted one ahead of it.
        h.positions = [
            Position(id: "p_sellable", accountId: "acct_taxable", ticker: "SELLME", sleeveId: "zz_sell",
                     marketValueUsd: 300_000, costBasisUsd: 300_000, layer: .strategic,
                     disposition: .consume, holdToStepUp: false),
            Position(id: "p_locked", accountId: "acct_taxable", ticker: "SELLME", sleeveId: "zz_sell",
                     marketValueUsd: 700_000, costBasisUsd: 700_000, layer: .strategic,
                     disposition: .holdToStepUp, holdToStepUp: true),
        ]
        h.tacticalTilts = []

        let plan = Engine.rebalancePlan(h, policy: policy, tax: Seed.tax2026, asOf: Engine.planningAsOf)
        let buys = plan.trades.filter { $0.side == TradeSide.buy }
        XCTAssertFalse(buys.isEmpty, "fixture check: the sale funds something")
        let permitted = buys.first { $0.sleeveId == "bb_permits" }?.amountUsd ?? 0
        let forbidden = buys.first { $0.sleeveId == "aa_forbids" }?.amountUsd ?? 0
        XCTAssertGreaterThan(permitted, forbidden,
                             "the taxable account put \(Int(forbidden)) into a sleeve it cannot hold and only \(Int(permitted)) into one it can")
    }

    /// The ticket must name the account the trade actually lands in. It used to print
    /// "best held tax-deferred" on a ticket placing the buy in a taxable account.
    func testTheTicketNamesTheAccountItActuallyLandsIn() {
        let plan = makePlan(Seed.sampleHousehold)
        let buys = plan.trades.filter { $0.side == .buy }
        XCTAssertFalse(buys.isEmpty, "fixture check: the sample buys something")
        for t in buys {
            XCTAssertTrue(t.rationale.lowercased().contains(t.treatment.short.lowercased()),
                          "\(t.ticker): the ticket does not say it is landing in \(t.treatment.short) — \(t.rationale)")
        }
    }

    /// And when that is not the sleeve's preferred home, the ticket says so rather than
    /// claiming the opposite.
    func testASecondBestLocationIsDisclosedNotPapedOver() {
        let eval = Engine.evaluate(Seed.sampleHousehold)
        let plan = makePlan(Seed.sampleHousehold)
        for t in plan.trades.filter({ $0.side == .buy }) {
            guard let sleeve = eval.legacyPolicy.sleeve(t.sleeveId),
                  let preferred = sleeve.locationPreference.first, preferred != t.treatment else { continue }
            let r = t.rationale.lowercased()
            XCTAssertTrue(r.contains("second-best") || r.contains("not its preferred"),
                          "\(t.ticker) landed in \(t.treatment.short) but its preferred home is \(preferred.short): \(t.rationale)")
        }
    }

    /// Ordering must be deterministic — the plan is a trade ticket, and the same inputs must
    /// produce the same tickets.
    func testTheBuyAllocationIsDeterministic() {
        let a = makePlan(Seed.sampleHousehold).trades.map { "\($0.side)|\($0.ticker)|\($0.accountId)|\(Int($0.amountUsd))" }
        let b = makePlan(Seed.sampleHousehold).trades.map { "\($0.side)|\($0.ticker)|\($0.accountId)|\(Int($0.amountUsd))" }
        XCTAssertEqual(a, b)
    }

    /// An outer-band breach is funded before an inner one at the same location rank —
    /// spending an account's cash alphabetically could exhaust it on a marginal inner breach
    /// while an outer breach went unfunded.
    func testOuterBandBreachesAreFundedBeforeInnerOnes() {
        let eval = Engine.evaluate(Seed.sampleHousehold)
        let plan = makePlan(Seed.sampleHousehold)
        let bought = Set(plan.trades.filter { $0.side == .buy }.map(\.sleeveId))
        let unfundedOuter = plan.sleeveGaps.filter {
            $0.traded && $0.gapUsd > 0 && $0.status == .outerBreach && !bought.contains($0.sleeveId)
        }
        let fundedInner = plan.sleeveGaps.filter {
            $0.traded && $0.gapUsd > 0 && $0.status == .innerBreach && bought.contains($0.sleeveId)
        }
        // If an outer breach went unfunded while an inner one was funded, the only defensible
        // reason is location: the inner one was fundable from the account that had the cash.
        for outer in unfundedOuter {
            guard let sleeve = eval.legacyPolicy.sleeve(outer.sleeveId) else { continue }
            let fundedFromSomewhereItCouldLive = fundedInner.contains { inner in
                plan.trades.contains { $0.side == .buy && $0.sleeveId == inner.sleeveId
                    && sleeve.locationPreference.contains($0.treatment) }
            }
            XCTAssertFalse(fundedFromSomewhereItCouldLive,
                           "\(outer.sleeveId) is an outer-band breach left unfunded while an inner breach was funded from an account it could have lived in")
        }
    }
}

/// An untouched intake used to report a required real return of 20.0% beside a funded ratio
/// of 999.0% — one figure saying the plan is hopeless, the other that it is nine times
/// over-funded. Both are clamp artifacts of a plan with nothing in it, and neither describes
/// the client. A signed policy document must not state a return objective for nobody.
final class PlanSolvabilityTests: XCTestCase {

    func testAnUntouchedIntakeIsNotSolvable() {
        let e = Engine.evaluate(IntakeModel().buildHousehold())
        XCTAssertFalse(e.isSolvable, "no portfolio and no spending goal means nothing to solve")
        // The clamps are still there; the point is that nothing presents them as answers.
        XCTAssertEqual(e.household.portfolioValueUsd, 0, accuracy: 0.5)
    }

    func testAPortfolioWithNoSpendingGoalIsNotSolvable() {
        var m = IntakeModel()
        m.taxableUsd = 1_000_000
        m.retirementSpendingUsd = 0
        XCTAssertFalse(Engine.evaluate(m.buildHousehold()).isSolvable,
                       "assets with nothing to fund do not imply a required return")
    }

    func testASpendingGoalWithNoPortfolioIsNotSolvable() {
        var m = IntakeModel()
        m.retirementSpendingUsd = 120_000
        XCTAssertFalse(Engine.evaluate(m.buildHousehold()).isSolvable,
                       "a goal with no corpus has no return that funds it")
    }

    /// And a real plan must still be solvable, or the gate would hide every client's numbers.
    func testARealPlanIsSolvable() {
        var m = IntakeModel()
        m.adults = [{ var a = IntakeAdult(); a.birthYear = 1975; a.retirementAge = 65
                      a.salaryUsd = 200_000; a.traditionalUsd = 600_000; return a }()]
        m.taxableUsd = 900_000
        m.retirementSpendingUsd = 150_000
        XCTAssertTrue(Engine.evaluate(m.buildHousehold()).isSolvable)
        XCTAssertTrue(Engine.evaluate(Seed.sampleHousehold).isSolvable, "the shipped sample is a real plan")
    }
}
