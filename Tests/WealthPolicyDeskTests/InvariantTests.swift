import XCTest
@testable import WealthPolicyDesk

/// Properties that must hold for EVERY household, asserted across `HouseholdMatrix`.
///
/// The one-off tests in this suite each pin a specific number for a specific fixture, which
/// is why eight of them turned out to be unable to detect their own subject's absence: they
/// asserted on a shape that did not exercise the branch, or on an aggregate that hid the
/// defect, or with a bound the bug's own output satisfied.
///
/// These are different in kind. Each asserts something that must be true of every legal
/// intake — money is conserved, income does not terminate while the spending it funds runs
/// on, a plan is deterministic — and runs it across a matrix built to be hostile rather than
/// representative. A fix that closes one direction and opens its mirror fails here, because
/// the mirror is in the matrix.
final class InvariantTests: XCTestCase {

    private var matrix: [(name: String, intake: IntakeModel, eval: Evaluation, isOverItemised: Bool)] {
        HouseholdMatrix.evaluated
    }

    // MARK: - Money

    /// Every account holds exactly the greater of what was stated for it and what was
    /// itemized in it. No arrangement of holdings may move money between owners — the defect
    /// that shipped three times, in three different places.
    func testEveryAccountHoldsWhatItWasGiven() {
        for c in HouseholdMatrix.built {
            let byAccount = Dictionary(grouping: c.household.positions, by: \.accountId)
                .mapValues { $0.reduce(0) { $0 + $1.marketValueUsd } }
            for (i, adult) in c.intake.adults.enumerated() {
                for (stem, stated, treatment) in [("acct_trad", adult.traditionalUsd, AccountTaxTreatment.taxDeferred),
                                                  ("acct_roth", adult.rothUsd, AccountTaxTreatment.taxFree)] {
                    let id = i == 0 ? stem : "\(stem)_\(i)"
                    let itemized = c.intake.heldAwayPositions
                        .filter { $0.marketValueUsd > 0 && $0.treatment == treatment
                                  && (($0.ownerIndex >= 0 && $0.ownerIndex < c.intake.adults.count) ? $0.ownerIndex : 0) == i }
                        .reduce(0) { $0 + $1.marketValueUsd }
                    let expected = max(stated, itemized)
                    guard expected > 0 else { continue }
                    XCTAssertEqual(byAccount[id] ?? 0, expected, accuracy: 1,
                                   "\(c.name): \(id) holds \(Int(byAccount[id] ?? 0)), expected \(Int(expected))")
                }
            }
        }
    }

    /// The form's headline figure and the plan it builds must agree, always.
    func testTheStatedTotalMatchesTheBuiltPortfolio() {
        for c in HouseholdMatrix.built {
            XCTAssertEqual(c.intake.totalInvestableUsd, c.household.portfolioValueUsd, accuracy: 1,
                           "\(c.name): the form says \(Int(c.intake.totalInvestableUsd)), the plan holds \(Int(c.household.portfolioValueUsd))")
        }
    }

    /// A contradiction is flagged exactly when one exists — never silently resolved, never
    /// warned about when the inputs agree.
    func testOverItemisationIsFlaggedExactlyWhenItHappens() {
        for c in HouseholdMatrix.built {
            XCTAssertEqual(!c.intake.overItemisedAccounts.isEmpty, c.isOverItemised,
                           "\(c.name): over-itemisation \(c.isOverItemised ? "was not" : "was wrongly") reported")
        }
    }

    /// No projected balance may go negative in any year, on any household.
    func testNoBucketEverGoesNegative() {
        for c in matrix {
            for y in c.eval.decumulation.plan.years {
                XCTAssertGreaterThanOrEqual(y.endTaxableUsd, -0.5, "\(c.name) age \(y.age): taxable")
                XCTAssertGreaterThanOrEqual(y.endDeferredUsd, -0.5, "\(c.name) age \(y.age): deferred")
                XCTAssertGreaterThanOrEqual(y.endRothUsd, -0.5, "\(c.name) age \(y.age): Roth")
            }
        }
    }

    // MARK: - Income

    /// Income must not terminate while the spending it funds runs on. Gating Social Security
    /// on a longevity ESTIMATE modelled a household that is dead for income and alive for
    /// spending, deleting about $288,000 on a default configuration.
    func testIncomeDoesNotStopWhileSpendingContinues() {
        for c in matrix {
            let entitled = c.intake.adults.contains { $0.socialSecurityMonthlyUsd > 0 || $0.salaryUsd > 0 }
            guard entitled else { continue }
            guard let lastSpendingYear = c.eval.household.goals
                .filter({ $0.kind == .spending }).flatMap(\.outflows)
                .filter({ $0.amountUsd > 0 }).map(\.year).max() else { continue }
            let atEnd = Engine.socialSecurityAnnual(c.eval.household, year: lastSpendingYear, asOf: c.eval.asOf)
            XCTAssertGreaterThan(atEnd, 0,
                                 "\(c.name): spending runs to plan-year \(lastSpendingYear) with $0 of Social Security against it")
        }
    }

    /// Social Security is monotonically non-increasing once everyone has claimed: benefits
    /// step DOWN at a death and never recover. A rise after the last claim means a component
    /// began paying that should not have.
    func testSocialSecurityNeverRisesAfterEveryoneHasClaimed() {
        for c in matrix {
            let ents = Engine.socialSecurityEntitlements(c.eval.household, asOf: c.eval.asOf)
            guard !ents.isEmpty else { continue }
            let allClaimed = ents.map { max($0.ownStartYear, $0.topUpStartYear) }.max() ?? 0
            var previous = Usd.greatestFiniteMagnitude
            for t in allClaimed...(allClaimed + 30) {
                let now = Engine.socialSecurityAnnual(c.eval.household, year: t, asOf: c.eval.asOf)
                XCTAssertLessThanOrEqual(now, previous + 1,
                                         "\(c.name): benefit rose at plan-year \(t) after everyone had claimed")
                previous = now
            }
        }
    }

    /// A household with a stated benefit and a living member is never paid nothing. An
    /// unfloored death year zeroed a living 85-year-old's benefit for the entire plan.
    func testAHouseholdWithAStatedBenefitIsNeverPaidNothing() {
        for c in matrix where c.intake.adults.contains(where: { $0.socialSecurityMonthlyUsd > 0 }) {
            let claimed = Engine.socialSecurityEntitlements(c.eval.household, asOf: c.eval.asOf)
                .map { max($0.ownStartYear, $0.topUpStartYear) }.min() ?? 0
            XCTAssertGreaterThan(Engine.socialSecurityAnnual(c.eval.household, year: claimed + 1, asOf: c.eval.asOf), 0,
                                 "\(c.name): a household holding SSA statements collects nothing")
        }
    }

    /// A person's OWN benefit begins on their own claim year, whatever anyone else does. The
    /// spousal top-up may wait for the worker to file; the own record never does.
    ///
    /// This invariant exists because the historical defect it describes — clamping the whole
    /// entitlement to the top-up's start, which deleted nine years of a spouse's earned
    /// benefit — slipped through every OTHER invariant here. The household was still paid
    /// eventually, just not in the gap, so "never paid nothing" and "does not stop early"
    /// both held. Aggregate properties cannot see a component that starts late.
    func testAnOwnBenefitIsNeverHeldBackByAnotherPersonsFiling() {
        for c in matrix {
            for e in Engine.socialSecurityEntitlements(c.eval.household, asOf: c.eval.asOf)
            where e.ownAnnualUsd > 0 {
                XCTAssertGreaterThanOrEqual(e.amount(inYear: e.ownStartYear), e.ownAnnualUsd - 0.5,
                    "\(c.name): an own benefit of \(Int(e.ownAnnualUsd)) does not pay at its own claim year \(e.ownStartYear)")
            }
        }
    }

    /// And at the household level: a couple where one claims years before the other must
    /// collect something in between. The gap is where the component-level defect showed up.
    func testAHouseholdCollectsInTheGapBetweenTwoClaimingAges() {
        for c in matrix {
            let ents = Engine.socialSecurityEntitlements(c.eval.household, asOf: c.eval.asOf)
                .filter { $0.ownAnnualUsd > 0 }
            guard ents.count > 1 else { continue }
            let starts = ents.map(\.ownStartYear).sorted()
            guard let first = starts.first, let last = starts.last, last > first + 1 else { continue }
            for t in (first + 1)..<last {
                XCTAssertGreaterThan(Engine.socialSecurityAnnual(c.eval.household, year: t, asOf: c.eval.asOf), 0,
                    "\(c.name): nothing is collected at plan-year \(t), between claims at \(first) and \(last)")
            }
        }
    }

    // MARK: - The plan

    /// Two evaluations of the same inputs must agree exactly. This is a trade ticket.
    func testEvaluationIsDeterministic() {
        for c in HouseholdMatrix.built {
            let a = Engine.evaluate(c.household), b = Engine.evaluate(c.household)
            XCTAssertEqual(a.requiredReturn.requiredRealReturnBps, b.requiredReturn.requiredRealReturnBps, "\(c.name)")
            XCTAssertEqual(a.balanceSheet.fundedRatioBps, b.balanceSheet.fundedRatioBps, "\(c.name)")
            XCTAssertEqual(a.findings.map(\.ruleId).sorted(), b.findings.map(\.ruleId).sorted(), "\(c.name)")
        }
    }

    /// A figure that is a solver sentinel is never presented as a solved rate.
    func testSentinelsAreNeverReportedAsSolved() {
        for c in matrix {
            let rr = c.eval.requiredReturn.requiredRealReturnBps
            if rr >= Engine.requiredReturnCeilingBps || rr <= Engine.requiredReturnFloorBps
                || c.eval.balanceSheet.fundedRatioBps >= Engine.fundedRatioCeilingBps {
                XCTAssertFalse(c.eval.isSolvable, "\(c.name): a bracket sentinel is being reported as a solved figure")
            }
        }
    }

    /// Persistence: no stored field may be write-only, on any household in the matrix.
    func testEveryIntakeRoundTrips() throws {
        for c in HouseholdMatrix.built {
            let back = try JSONDecoder().decode(IntakeModel.self, from: try JSONEncoder().encode(c.intake))
            XCTAssertEqual(back, c.intake, "\(c.name): a field is encoded but not decoded")
        }
    }

    // MARK: - Rebalance

    /// Money cannot move between accounts, and the held-to-maturity ladder is never a
    /// funding source — on any household, not just the two these were written against.
    func testRebalanceRespectsAccountBoundariesAndTheLadder() {
        for c in matrix {
            var policy = c.eval.legacyPolicy
            policy.sleeves = policy.sleeves.map { s in
                var s = s
                if let row = c.eval.allocation.first(where: { $0.sleeveId == s.id }) { s.targetBps = row.targetBps }
                return s
            }
            let plan = Engine.rebalancePlan(c.eval.household, policy: policy, tax: c.eval.tax, asOf: c.eval.asOf)

            var net: [String: (sold: Usd, bought: Usd)] = [:]
            for t in plan.trades {
                var e = net[t.accountId] ?? (0, 0)
                if t.side == .sell { e.sold += t.amountUsd } else { e.bought += t.amountUsd }
                net[t.accountId] = e
            }
            for (accountId, e) in net {
                XCTAssertLessThanOrEqual(e.bought, e.sold + 0.5,
                                         "\(c.name): \(accountId) spent \(Int(e.bought)) having raised \(Int(e.sold))")
            }
            for t in plan.trades where t.side == .sell {
                let sold = c.eval.household.positions.first { $0.ticker == t.ticker && $0.accountId == t.accountId }
                XCTAssertNotEqual(sold?.layer, .ladder, "\(c.name): sold a ladder rung (\(t.ticker))")
            }
            XCTAssertFalse(plan.trades.contains { $0.side == .buy && $0.ticker.isEmpty },
                           "\(c.name): a buy with no instrument reached the ticket")
        }
    }

    // MARK: - The matrix itself

    /// The matrix must actually contain the hostile shapes it claims to, or every invariant
    /// above passes for the wrong reason. This is the guard on the guard.
    func testTheMatrixCoversTheShapesTheDefectsLivedIn() {
        let m = HouseholdMatrix.cases
        let asOf = Engine.planningAsOf
        func age(_ a: IntakeAdult) -> Int { Engine.year(asOf) - a.birthYear }

        XCTAssertTrue(m.contains { $0.intake.adults.count == 1 }, "a single filer")
        XCTAssertTrue(m.contains { $0.intake.adults.count == 2 }, "a couple")
        XCTAssertTrue(m.contains { $0.intake.adults.count >= 3 }, "three or more adults")
        XCTAssertTrue(m.contains { $0.intake.adults.contains { age($0) >= 75 } }, "someone past their required beginning date")
        XCTAssertTrue(m.contains { $0.intake.adults.contains { $0.health == .poor && age($0) > 80 } },
                      "someone past their own longevity estimate")
        XCTAssertTrue(m.contains { $0.intake.adults.contains { $0.ssClaimAge > 0 && age($0) > $0.ssClaimAge } },
                      "a claim already in the past")
        XCTAssertTrue(m.contains { c in
            guard c.intake.adults.count > 1 else { return false }
            return abs(age(c.intake.adults[0]) - age(c.intake.adults[1])) >= 20
        }, "a wide age gap")
        XCTAssertTrue(m.contains { $0.intake.adults.contains { $0.traditionalUsd == 0 } && $0.intake.adults.count > 1 },
                      "a blank balance on one side")
        XCTAssertTrue(m.contains { $0.isOverItemised }, "an over-itemised account")
        XCTAssertTrue(m.contains { c in c.intake.heldAwayPositions.contains { $0.ownerIndex >= c.intake.adults.count } },
                      "an owner index off the roster")
        XCTAssertTrue(m.contains { $0.intake.totalInvestableUsd == 0 }, "a household with nothing entered")
        XCTAssertGreaterThanOrEqual(m.count, 20, "the matrix has been thinned out")
    }
}
