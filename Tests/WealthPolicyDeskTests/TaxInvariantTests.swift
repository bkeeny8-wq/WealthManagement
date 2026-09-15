import XCTest
@testable import WealthPolicyDesk

/// Properties of the tax and decumulation projection, asserted across `HouseholdMatrix`.
///
/// These paths carried several of the defects this codebase has shipped — required
/// distributions gated on the wrong person's age, a conversion window read off a firm
/// default, a tax series that arrived empty because it was computed inside a branch the
/// feeding pass never took, a Medicare surcharge multiplied by head count on a combined-MAGI
/// return — and none of them had a property test. Each was caught, eventually, by a reviewer
/// constructing the one household that exposed it. These assert the same things for every
/// household in the matrix instead.
final class TaxInvariantTests: XCTestCase {

    private var matrix: [(name: String, intake: IntakeModel, eval: Evaluation, isOverItemised: Bool)] {
        HouseholdMatrix.evaluated
    }

    // MARK: - Required distributions

    /// No account distributes before ITS OWNER reaches their own required beginning age.
    /// Pooling the household's tax-deferred money and gating it on the primary started a
    /// spouse's 401(k) on his schedule — and SECURE 2.0 makes that age a function of birth
    /// year, so an age gap moves the answer by years in either direction.
    func testNoAccountDistributesBeforeItsOwnerIsRequiredTo() {
        for c in matrix {
            let h = c.eval.household
            guard let primary = h.primary else { continue }
            let primaryAge0 = Engine.age(birthDate: primary.birthDate, asOf: c.eval.asOf)

            // The earliest any owner of a tax-deferred account is required to distribute.
            let earliest = h.accounts.filter { $0.treatment == .taxDeferred }.compactMap { a -> Int? in
                let owner = h.people.first { $0.id == a.ownership.ownerPersonId } ?? primary
                let ownerAge0 = Engine.age(birthDate: owner.birthDate, asOf: c.eval.asOf)
                let required = Engine.rmdStartAge(birthDate: owner.birthDate, default: c.eval.tax.rmdStartAge)
                return max(0, required - ownerAge0)          // plan-year that owner reaches it
            }.min()
            guard let earliestPlanYear = earliest else { continue }

            for y in c.eval.decumulation.baseline.years where y.rmdUsd > 0 {
                let planYear = y.age - primaryAge0
                XCTAssertGreaterThanOrEqual(planYear, earliestPlanYear,
                    "\(c.name): a distribution at plan-year \(planYear), before any owner is required to take one (\(earliestPlanYear))")
            }

            // The MIRROR, which matters just as much: an owner who has reached their required
            // age and still holds a balance must actually be distributing. Asserting only
            // "not too early" let the whole pool be gated on the PRIMARY — which is never too
            // early, just years too late for an older spouse.
            let row = c.eval.decumulation.baseline.years.first { $0.age - primaryAge0 >= earliestPlanYear }
            if let row, row.endDeferredUsd > 1 {
                XCTAssertGreaterThan(row.rmdUsd, 0,
                    "\(c.name): at plan-year \(row.age - primaryAge0) an owner is past their required age with \(Int(row.endDeferredUsd)) still in the account and no distribution")
            }
        }
    }

    /// A Roth conversion is never recommended in a year the household is already
    /// distributing. The optimiser was proposing six-figure conversions through years a
    /// spouse had been taking required distributions for the better part of a decade.
    func testNoConversionIsProposedOnceDistributionsHaveBegun() {
        for c in matrix {
            let firstRmdAge = c.eval.decumulation.plan.years.first { $0.rmdUsd > 0 }?.age
            guard let firstRmdAge else { continue }
            for y in c.eval.decumulation.plan.years where y.rothConversionUsd > 0.5 {
                XCTAssertLessThan(y.age, firstRmdAge,
                    "\(c.name): a conversion at age \(y.age), after distributions began at \(firstRmdAge)")
            }
        }
    }

    /// The window the Tax tab prints is the window conversions actually happen in. It used
    /// to print a firm constant written before SECURE 2.0 moved the RMD age, so it disagreed
    /// with the Decumulation tab on the same screen and truncated the two most valuable
    /// conversion years.
    /// The window ends at THIS client's own boundary — the year before their own required
    /// beginning age — not at a firm default written before SECURE 2.0 moved it. Asserting
    /// only that conversions fall inside the window passes a window that is too NARROW, which
    /// is exactly what the firm default was: it truncated the two most valuable years.
    func testTheWindowEndsAtTheClientsOwnRequiredAge() {
        for c in matrix {
            guard let primary = c.eval.household.primary,
                  let w = c.eval.policy.withdrawal.conversionWindow else { continue }
            let required = Engine.rmdStartAge(birthDate: primary.birthDate, default: c.eval.tax.rmdStartAge)
            XCTAssertEqual(w.toAge, required - 1,
                "\(c.name): the window ends at \(w.toAge) but this client's distributions begin at \(required)")
            XCTAssertEqual(w.fromAge, primary.expectedRetirementAge,
                "\(c.name): the window starts at \(w.fromAge), not this client's retirement age")
        }
    }

    /// And the window's last year is USABLE, not decorative — on a household whose balance
    /// survives that long. A window nobody can convert in the final year of is a window that
    /// has been quietly truncated.
    func testTheLastYearOfTheWindowIsUsable() {
        let deep = matrix.filter { c in
            c.eval.decumulation.plan.years.contains { $0.rothConversionUsd > 0.5 }
        }
        XCTAssertFalse(deep.isEmpty, "the matrix contains no household the optimiser converts in")
        for c in deep {
            guard let w = c.eval.policy.withdrawal.conversionWindow else { continue }
            let last = c.eval.decumulation.plan.years.filter { $0.rothConversionUsd > 0.5 }.map(\.age).max()!
            let balanceRunsOut = c.eval.decumulation.plan.years
                .first { $0.age == last }?.endDeferredUsd ?? 0
            if balanceRunsOut > 1 {
                XCTAssertEqual(last, w.toAge,
                    "\(c.name): conversions stop at \(last) with \(Int(balanceRunsOut)) left and the window open to \(w.toAge)")
            }
        }
    }

    func testThePrintedConversionWindowContainsEveryConversion() {
        for c in matrix {
            guard let w = c.eval.policy.withdrawal.conversionWindow else {
                XCTAssertTrue(c.eval.decumulation.plan.years.allSatisfy { $0.rothConversionUsd <= 0.5 },
                              "\(c.name): conversions happen but no window is reported")
                continue
            }
            for y in c.eval.decumulation.plan.years where y.rothConversionUsd > 0.5 {
                XCTAssertGreaterThanOrEqual(y.age, w.fromAge, "\(c.name): a conversion before the printed window")
                XCTAssertLessThanOrEqual(y.age, w.toAge, "\(c.name): a conversion after the printed window")
            }
        }
    }

    // MARK: - The tax the portfolio actually pays

    /// The portfolio never pays more tax than the year's bill, and never a negative amount.
    /// A working year settles its own tax out of wages first, so the portfolio's share is
    /// below the headline whenever an adult is still earning — and equal to it otherwise.
    func testThePortfolioNeverPaysMoreTaxThanIsOwed() {
        for c in matrix {
            for y in c.eval.decumulation.baseline.years {
                let owed = y.federalTaxUsd + y.irmaaUsd
                XCTAssertGreaterThanOrEqual(y.portfolioTaxUsd, -0.5, "\(c.name) age \(y.age): negative tax paid")
                XCTAssertLessThanOrEqual(y.portfolioTaxUsd, owed + 0.5,
                    "\(c.name) age \(y.age): the portfolio paid \(Int(y.portfolioTaxUsd)) against a bill of \(Int(owed))")
                if y.wagesUsd == 0 {
                    XCTAssertEqual(y.portfolioTaxUsd, owed, accuracy: 0.5,
                        "\(c.name) age \(y.age): no wages exist to absorb any of this bill")
                } else if owed > 0.5 {
                    // The mirror. Asserting only `<=` passes a model that never offsets at
                    // all — which is the defect: the wage tax was debited from the portfolio
                    // while the wages themselves were credited nowhere.
                    let spendingNeed = max(0, y.spendingNeedUsd - y.guaranteedIncomeUsd)
                    if y.wagesUsd > spendingNeed {
                        XCTAssertLessThan(y.portfolioTaxUsd, owed,
                            "\(c.name) age \(y.age): $\(Int(y.wagesUsd)) of wages against $\(Int(spendingNeed)) of need, yet the portfolio paid the whole $\(Int(owed)) bill")
                    }
                }
            }
        }
    }

    /// The two-pass after-tax solve must actually receive a tax series. Computing the
    /// portfolio's share inside the balance-debiting branch fed the second pass all zeros and
    /// silently collapsed the after-tax required return onto the pre-tax one, with nothing
    /// failing.
    func testTheAfterTaxSolveReceivesANonEmptyTaxSeries() {
        for c in matrix {
            let rr = c.eval.requiredReturn
            let paysTax = c.eval.decumulation.baseline.years.contains { $0.portfolioTaxUsd > 1 }
            guard paysTax, c.eval.isSolvable else { continue }
            XCTAssertGreaterThan(rr.requiredRealReturnBps, rr.requiredRealReturnPreTaxBps,
                "\(c.name): the after-tax and pre-tax figures agree, so the tax series arrived empty")
        }
    }

    /// Wages are ordinary income, so a year that taxes them must report them.
    func testAnyYearWithWagesReportsThemAsOrdinaryIncome() {
        for c in matrix {
            for y in c.eval.decumulation.baseline.years where y.wagesUsd > 0 {
                XCTAssertGreaterThanOrEqual(y.ordinaryIncomeUsd, y.wagesUsd - 0.5,
                    "\(c.name) age \(y.age): $\(Int(y.wagesUsd)) of wages taxed but not reported")
            }
        }
    }

    /// Lifetime totals are finite, non-negative, and equal the sum of their years — a floor
    /// under every headline tile on the Decumulation tab.
    func testLifetimeTotalsAreTheSumOfTheirYears() {
        for c in matrix {
            let plan = c.eval.decumulation.baseline
            let tax = plan.years.reduce(0) { $0 + $1.federalTaxUsd }
            let irmaa = plan.years.reduce(0) { $0 + $1.irmaaUsd }
            XCTAssertEqual(plan.lifetimeFederalTaxUsd, tax, accuracy: 1, "\(c.name)")
            XCTAssertEqual(plan.lifetimeIrmaaUsd, irmaa, accuracy: 1, "\(c.name)")
            XCTAssertGreaterThanOrEqual(plan.lifetimeFederalTaxUsd, 0, "\(c.name)")
            XCTAssertTrue(plan.lifetimeFederalTaxUsd.isFinite && plan.lifetimeIrmaaUsd.isFinite, "\(c.name)")
        }
    }

    // MARK: - Medicare surcharges

    /// IRMAA is only multiplied by head count on a JOINT return. Every other filing status
    /// has bands that apply to one person's income, so charging two adults against a
    /// combined MAGI invents a bill: a two-adult separate return at $150,000 was billed
    /// $9,768/yr where the truth is between $0 and $4,884.
    func testOnlyJointReturnsAreChargedPerPerson() {
        let tiers = Seed.tax2026.irmaaTiers
        for filing in FilingStatus.allCases {
            for magi in [50_000.0, 150_000.0, 300_000.0, 800_000.0] {
                let one = Engine.irmaaAnnual(magi: magi, medicareCount: 1, filing: filing, tiers: tiers)
                let two = Engine.irmaaAnnual(magi: magi, medicareCount: 2, filing: filing, tiers: tiers)
                if filing == .mfj {
                    XCTAssertEqual(two, one * 2, accuracy: 0.01, "\(filing) at \(Int(magi)) is per enrolled spouse")
                } else {
                    XCTAssertEqual(two, one, accuracy: 0.01, "\(filing) at \(Int(magi)) bills one person's bands twice")
                }
            }
            XCTAssertNotNil(tiers[filing], "\(filing) has no schedule and is silently borrowing another's")
        }
    }

    /// No household is charged a surcharge it cannot owe, and every charge is finite.
    func testSurchargesAreNeverNegativeOrUnbounded() {
        for c in matrix {
            for y in c.eval.decumulation.baseline.years {
                XCTAssertGreaterThanOrEqual(y.irmaaUsd, 0, "\(c.name) age \(y.age)")
                XCTAssertTrue(y.irmaaUsd.isFinite, "\(c.name) age \(y.age)")
                XCTAssertLessThan(y.irmaaUsd, 100_000, "\(c.name) age \(y.age): an implausible surcharge")
            }
        }
    }

    // MARK: - Rates

    /// A marginal rate is a real bracket rate, never a sentinel or an artifact.
    func testEveryMarginalRateIsARealBracketRate() {
        for c in matrix {
            let brackets = Set((c.eval.tax.ordinaryBrackets[c.eval.household.filingStatus] ?? []).map(\.rateBps))
            for y in c.eval.decumulation.baseline.years {
                XCTAssertTrue(brackets.contains(y.marginalRateBps) || y.marginalRateBps == 0,
                    "\(c.name) age \(y.age): marginal rate \(y.marginalRateBps) is not a bracket in this schedule")
            }
        }
    }
}
