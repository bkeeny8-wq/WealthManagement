import XCTest
@testable import WealthPolicyDesk

/// DERIVED CASH FLOW — "we need to be able to model potential income and funds".
///
/// `annualSavingsUsd` asked the client for a conclusion. This engine asks for facts — income,
/// deferrals, tax, today's outlay — and derives the conclusion, which means it can now
/// CONTRADICT what the client said. Most of what follows is about making that contradiction,
/// and the ways it can be faked, impossible to ship green.
///
/// The one structural claim: THERE IS ONE WAGE PATH. An earlier draft of this engine carried
/// its own `WageStep` list beside `HumanCapital.compensationSchedule`, which would have been
/// two source lists for one quantity. `testGrossWagesEqualsWagesAtPlanYear...` is what makes
/// re-growing that a failure rather than a discovery.
final class CashFlowTests: XCTestCase {

    private let asOf: IsoDate = "2026-11-01"
    private var planYear: Int { Engine.year(asOf) }

    // MARK: - Fixtures

    /// The case study: single filer in NJ, $225,000 base, bonus prorated to $50,000 this year
    /// against $200,000 from next year, 6% deferral with a 4% match, $4,400 HSA, $1,709/mo of
    /// pre-tax premiums, spending $11,000/mo.
    private func intake() -> IntakeModel {
        var a = IntakeAdult()
        a.name = "A"; a.birthYear = planYear - 36; a.retirementAge = 65
        a.salaryUsd = 225_000; a.bonusUsd = 50_000
        a.incomeCharacter = .equityLike; a.sector = .financials
        a.socialSecurityMonthlyUsd = 4_200
        a.compYears = [
            IntakeCompYear(calendarYear: planYear, salaryUsd: 225_000, cashBonusUsd: 50_000),
            IntakeCompYear(calendarYear: planYear + 1, salaryUsd: 225_000, cashBonusUsd: 200_000),
        ]
        a.retirementDeferralBps = 600
        a.employerMatchBps = 400
        a.hsaAnnualContributionUsd = 4_400
        a.benefitPremiumsUsd = 1_700 * 12
        var m = IntakeModel()
        m.adults = [a]
        m.state = "NJ"; m.planToAge = 92
        m.taxableUsd = 300_000; m.emergencyReserveUsd = 25_000
        m.retirementSpendingUsd = 140_000
        m.annualSavingsUsd = 30_000
        m.currentFixedSpendingUsd = 96_000
        m.currentVariableSpendingUsd = 36_000
        return m
    }

    /// A household with the paystub answered but NO outlay — the "not asked" case, which must
    /// keep running on the stated figure.
    private func noSpendingIntake() -> IntakeModel {
        var m = intake(); m.currentFixedSpendingUsd = 0; m.currentVariableSpendingUsd = 0
        return m
    }

    private func built(_ m: IntakeModel) -> Household { m.buildHousehold(asOf: asOf) }
    private func cf(_ h: Household) -> CashFlowProfile {
        guard let p = h.cashFlow else { XCTFail("fixture has no cash-flow profile"); return .init() }
        return p
    }
    private func yr(_ h: Household, _ t: Int) -> CashFlowYear {
        CashFlow.year(h, cf(h), year: t, asOf: asOf)
    }
    private func humanCapitalPv(_ h: Household) -> Usd {
        Engine.evaluate(h, asOf: asOf).balanceSheet.assets.humanCapitalPvUsd
    }
    /// Total portfolio at the end of the FIRST retirement year — the quantity the accumulation
    /// block feeds, and the only place a mis-credited accumulation shows up.
    private func firstRetirementYearEndBalance(_ h: Household) -> Usd {
        let rr = Engine.requiredReturn(h, asOf: asOf)
        let plan = Engine.decumulation(h, tax: Seed.tax2026, rr: rr, asOf: asOf)
        guard let y = plan.years.first else { XCTFail("no decumulation years"); return 0 }
        return y.endTaxableUsd + y.endDeferredUsd + y.endRothUsd
    }

    // MARK: - Fixture preconditions
    //
    // Every comparison below is vacuous if the fixture cannot reach the state it probes. These
    // assert the signals are LIVE before anything is concluded from them.

    func testFixtureCarriesTheSignalsEveryOtherTestReadsFrom() {
        let h = built(intake())
        XCTAssertNotNil(h.cashFlow, "spending answered ⇒ a profile must be attached")
        let y0 = yr(h, 0)
        XCTAssertGreaterThan(y0.grossWagesUsd, 0)
        XCTAssertGreaterThan(y0.retirementDeferralUsd, 0, "no deferral ⇒ the FICA-base split is untestable")
        XCTAssertGreaterThan(y0.hsaDeferralUsd, 0)
        XCTAssertGreaterThan(y0.benefitPremiumsUsd, 0)
        XCTAssertGreaterThan(y0.employerMatchUsd, 0)
        XCTAssertGreaterThan(y0.stateIncomeTaxUsd, 0, "NJ taxes wages ⇒ the state proxy can bite")
        XCTAssertGreaterThan(y0.spendingUsd, 0)
        // The schedule must actually step, or every stepped-income assertion is a tautology.
        XCTAssertNotEqual(h.humanCapital[0].statedIncomeUsd(planYear: 0),
                          h.humanCapital[0].statedIncomeUsd(planYear: 1))
    }

    func testNoSpendingMeansNoProfileAndTheStatedFigureStillGoverns() {
        let h = built(noSpendingIntake())
        XCTAssertNil(h.cashFlow, "no outlay ⇒ nothing to derive")
        for t in 1...5 {
            XCTAssertEqual(Engine.investableSurplusAtPlanYear(h, year: t, asOf: asOf),
                           min(h.annualSavingsUsd, Engine.wagesAtPlanYear(h, year: t, asOf: asOf)),
                           accuracy: 0.01,
                           "the legacy expression, term for term, in plan year \(t)")
        }
    }

    // MARK: - ONE wage path
    //
    // The reason this file does not define a wage schedule.

    /// Gross wages in the waterfall are `Engine.wagesAtPlanYear`, in EVERY year, including the
    /// years either side of the step and the year the earner retires.
    ///
    /// This is the test a second wage model cannot pass. A `WageStep` list with its own growth
    /// basis would diverge from `statedIncomeUsd` the moment either side was edited; carrying
    /// its own flat `baseSalaryUsd` would diverge at the step.
    func testGrossWagesEqualsWagesAtPlanYearInEveryYear() {
        let h = built(intake())
        for t in 0...35 {
            XCTAssertEqual(Engine.cashFlowWageAgreementUsd(h, year: t, asOf: asOf), 0, accuracy: 0.01,
                           "the two wage paths disagree in plan year \(t)")
        }
    }

    /// And it holds when the step moves, which is what proves the agreement is structural
    /// rather than a coincidence of this fixture's numbers.
    func testWageAgreementSurvivesEditingTheSchedule() {
        var m = intake()
        m.adults[0].compYears = [
            IntakeCompYear(calendarYear: planYear, salaryUsd: 100_000, cashBonusUsd: 0),
            IntakeCompYear(calendarYear: planYear + 3, salaryUsd: 400_000, cashBonusUsd: 150_000),
            IntakeCompYear(calendarYear: planYear + 9, salaryUsd: 250_000, cashBonusUsd: 0),
        ]
        let h = built(m)
        for t in 0...15 {
            XCTAssertEqual(Engine.cashFlowWageAgreementUsd(h, year: t, asOf: asOf), 0, accuracy: 0.01,
                           "plan year \(t)")
        }
        // The signal is live: the schedule really does move wages in both directions.
        XCTAssertGreaterThan(yr(h, 3).grossWagesUsd, yr(h, 2).grossWagesUsd)
        XCTAssertLessThan(yr(h, 9).grossWagesUsd, yr(h, 8).grossWagesUsd)
    }

    /// The waterfall reads the SCHEDULE, not the single number: year 0 is the prorated bonus
    /// and year 1 is the target, and the difference is exactly the stated bonus step.
    func testTheWaterfallReadsTheSteppedSchedule() {
        let h = built(intake())
        XCTAssertEqual(yr(h, 0).grossWagesUsd, 275_000, accuracy: 0.01)
        XCTAssertEqual(yr(h, 1).grossWagesUsd, 425_000, accuracy: 0.01)
        XCTAssertEqual(yr(h, 1).grossWagesUsd - yr(h, 0).grossWagesUsd, 150_000, accuracy: 0.01)
    }

    /// Retirement gating is `wagesAtPlanYear`'s, to the year. An off-by-one here would put the
    /// surplus and the decumulation tax base in different years.
    func testEarningStopsTheYearTheEarnerRetires() {
        let h = built(intake())
        let retireT = 65 - 36
        XCTAssertGreaterThan(yr(h, retireT - 1).grossWagesUsd, 0, "still working the year before")
        XCTAssertEqual(yr(h, retireT).grossWagesUsd, 0, accuracy: 0.01, "stops at the retirement age")
        XCTAssertEqual(Engine.wagesAtPlanYear(h, year: retireT, asOf: asOf), 0, accuracy: 0.01)
    }

    /// An earner with no `EarnerCashFlow` entry is still counted at FULL wages with zero
    /// deductions. The rival implementation — skip anyone without an entry — would silently
    /// erase a half-completed intake's entire income, and `grossWagesUsd` would read zero while
    /// `wagesAtPlanYear` read $275,000.
    func testAnEarnerWithNoPaystubEntryStillEarns() {
        let h = built(intake())
        var stripped = h
        stripped.cashFlow = CashFlowProfile(earners: [], spending: cf(h).spending)
        let y = CashFlow.year(stripped, stripped.cashFlow!, year: 0, asOf: asOf)
        XCTAssertEqual(y.grossWagesUsd, Engine.wagesAtPlanYear(h, year: 0, asOf: asOf), accuracy: 0.01)
        XCTAssertEqual(y.retirementDeferralUsd, 0, accuracy: 0.01)
        XCTAssertEqual(y.employerMatchUsd, 0, accuracy: 0.01)
    }

    // MARK: - The deferral split
    //
    // The doctrine of this file: a 401(k) deferral is SAVINGS, a medical premium is SPENDING,
    // and they reduce DIFFERENT tax bases. Each assertion below fails under the lumped model.

    /// A 401(k) deferral cuts federal taxable wages and leaves FICA wages alone; an HSA cuts
    /// both. Asserted as payroll tax, which is the quantity the lumped model gets wrong.
    func testElectiveDeferralDoesNotReduceFicaWagesButTheHsaDoes() {
        let h = built(intake())
        let base = yr(h, 0)

        var noDeferral = h
        noDeferral.cashFlow!.earners[0].deductions.retirementBps = 0
        let nd = CashFlow.year(noDeferral, noDeferral.cashFlow!, year: 0, asOf: asOf)

        XCTAssertEqual(nd.payrollTaxUsd, base.payrollTaxUsd, accuracy: 0.01,
                       "a 401(k) deferral is FICA-taxable: payroll tax must not move")
        XCTAssertGreaterThan(nd.federalIncomeTaxUsd, base.federalIncomeTaxUsd,
                            "but it does cut federal taxable wages")

        var noHsa = h
        noHsa.cashFlow!.earners[0].deductions.hsaUsd = 0
        let nh = CashFlow.year(noHsa, noHsa.cashFlow!, year: 0, asOf: asOf)
        XCTAssertGreaterThan(nh.payrollTaxUsd, base.payrollTaxUsd,
                            "a cafeteria-plan HSA cuts the FICA base, so removing it raises payroll tax")
        XCTAssertGreaterThan(nh.federalIncomeTaxUsd, base.federalIncomeTaxUsd)

        // The SIZE of the lumping error, which depends on where the earner sits relative to the
        // OASDI wage base — and that is the whole reason payroll tax cannot be a single rate.
        // This earner's FICA wages are above the base and above the single surtax threshold, so
        // the marginal payroll rate on the deferral is Medicare plus the surtax, 2.35%, NOT the
        // 7.65% that applies lower down.
        let p = Seed.payroll2026
        let deferral = base.retirementDeferralUsd
        XCTAssertGreaterThan(base.ficaTaxableWagesUsd,
                             p.additionalMedicareThresholdUsd[.single] ?? 0,
                             "this earner must be above the surtax threshold for the rate below")
        var lumped = h
        lumped.cashFlow!.earners[0].deductions.retirementBps = 0
        lumped.cashFlow!.earners[0].deductions.benefitPremiumsUsd
            = h.cashFlow!.earners[0].deductions.benefitPremiumsUsd + deferral
        let lm = CashFlow.year(lumped, lumped.cashFlow!, year: 0, asOf: asOf)
        XCTAssertEqual(base.payrollTaxUsd - lm.payrollTaxUsd,
                       deferral * (p.medicareRateBps.frac + p.additionalMedicareRateBps.frac),
                       accuracy: 1.0,
                       "above the wage base, lumping costs Medicare + surtax on the deferral")

        // And the mirror, which is what proves the regime matters: an earner BELOW the wage
        // base loses the full 7.65%. Same code, a different place on the curve.
        var low = intake()
        low.adults[0].salaryUsd = 90_000; low.adults[0].bonusUsd = 0
        low.adults[0].compYears = []
        low.adults[0].benefitPremiumsUsd = 0
        low.adults[0].hsaAnnualContributionUsd = 0
        low.currentFixedSpendingUsd = 50_000; low.currentVariableSpendingUsd = 0
        let hl = built(low)
        let lowBase = yr(hl, 0)
        XCTAssertLessThan(lowBase.ficaTaxableWagesUsd, p.socialSecurityWageBaseUsd,
                          "and this one must be below the base")
        var lowLumped = hl
        lowLumped.cashFlow!.earners[0].deductions.retirementBps = 0
        lowLumped.cashFlow!.earners[0].deductions.benefitPremiumsUsd = lowBase.retirementDeferralUsd
        let ll = CashFlow.year(lowLumped, lowLumped.cashFlow!, year: 0, asOf: asOf)
        XCTAssertEqual(lowBase.payrollTaxUsd - ll.payrollTaxUsd,
                       lowBase.retirementDeferralUsd
                        * (p.socialSecurityRateBps.frac + p.medicareRateBps.frac),
                       accuracy: 1.0,
                       "below the wage base it is the full 7.65%")
    }

    /// Deferrals and the match reach the portfolio without passing through net pay, so the
    /// surplus exceeds leftover cash by EXACTLY their sum — no more (which would double-count)
    /// and no less (which would write off real saving).
    func testSurplusExceedsLeftoverCashByExactlyTheDeferralsAndMatch()  {
        let h = built(intake())
        let y = yr(h, 0)
        XCTAssertEqual(y.investableSurplusUsd - y.leftoverCashUsd,
                       y.retirementDeferralUsd + y.hsaDeferralUsd + y.employerMatchUsd,
                       accuracy: 0.01)
        XCTAssertGreaterThan(y.retirementDeferralUsd + y.hsaDeferralUsd + y.employerMatchUsd, 0,
                            "the gap must be able to differ from zero")
    }

    /// A premium is CONSUMED. It reduces net pay and is not added back, so unlike a deferral it
    /// lowers the surplus. The mirror of the test above: without it, a stub that added every
    /// pre-tax line back would pass.
    func testPremiumsLowerTheSurplusWhileDeferralsDoNot() {
        let h = built(intake())
        let base = yr(h, 0)

        var noPrem = h
        noPrem.cashFlow!.earners[0].deductions.benefitPremiumsUsd = 0
        let np = CashFlow.year(noPrem, noPrem.cashFlow!, year: 0, asOf: asOf)
        XCTAssertGreaterThan(np.investableSurplusUsd, base.investableSurplusUsd,
                            "dropping a consumed premium must RAISE investable surplus")

        // A deferral, by contrast, moves money between lines without changing the total by
        // more than its tax effect — and in the same direction, not the opposite one.
        var bigDeferral = h
        bigDeferral.cashFlow!.earners[0].deductions.retirementUsdOverride = 24_500
        let bd = CashFlow.year(bigDeferral, bigDeferral.cashFlow!, year: 0, asOf: asOf)
        XCTAssertGreaterThan(bd.investableSurplusUsd, base.investableSurplusUsd,
                            "deferring more saves tax, so the surplus rises, never falls")
        XCTAssertLessThan(bd.leftoverCashUsd, base.leftoverCashUsd,
                         "while the cash in the bank account falls")
    }

    /// The deferral and match are shares of BASE, not of base-plus-bonus. This earner's bonus is
    /// a third of pay in year 0 and nearly half in year 1, so the lumped version would overstate
    /// the deferral by over 50%.
    func testDeferralAndMatchAreSharesOfBaseNotTotalComp() {
        let h = built(intake())
        let y0 = yr(h, 0), y1 = yr(h, 1)
        XCTAssertEqual(y0.retirementDeferralUsd, 225_000 * 0.06, accuracy: 0.01)
        XCTAssertEqual(y0.employerMatchUsd, 225_000 * 0.04, accuracy: 0.01)
        // Base is unchanged at the step; only the bonus moves. A base-plus-bonus rate would
        // jump here.
        XCTAssertEqual(y1.retirementDeferralUsd, y0.retirementDeferralUsd, accuracy: 0.01,
                       "the bonus stepped $150,000 and the deferral must not move")
        XCTAssertGreaterThan(y1.grossWagesUsd, y0.grossWagesUsd, "the signal is live")
    }

    /// Statutory caps bind, including the age-50 catch-up and family-vs-self-only HSA coverage.
    func testDeferralsAreCappedAtTheStatutoryLimits() {
        let h = built(intake())
        var maxed = h
        maxed.cashFlow!.earners[0].deductions.retirementUsdOverride = 99_000
        maxed.cashFlow!.earners[0].deductions.hsaUsd = 99_000
        let y = CashFlow.year(maxed, maxed.cashFlow!, year: 0, asOf: asOf)
        XCTAssertEqual(y.retirementDeferralUsd, Seed.deferralLimits2026.elective401kUsd, accuracy: 0.01)
        XCTAssertEqual(y.hsaDeferralUsd, Seed.deferralLimits2026.hsaSelfOnlyUsd, accuracy: 0.01)

        // Age 50 and 55 catch-ups, at the plan year this 36-year-old reaches them.
        let at50 = CashFlow.year(maxed, maxed.cashFlow!, year: 14, asOf: asOf)
        XCTAssertEqual(at50.retirementDeferralUsd,
                       Seed.deferralLimits2026.elective401kUsd + Seed.deferralLimits2026.catchUp50Usd,
                       accuracy: 0.01)
        let at55 = CashFlow.year(maxed, maxed.cashFlow!, year: 19, asOf: asOf)
        XCTAssertEqual(at55.hsaDeferralUsd,
                       Seed.deferralLimits2026.hsaSelfOnlyUsd + Seed.deferralLimits2026.hsaCatchUp55Usd,
                       accuracy: 0.01)

        var family = maxed
        family.cashFlow!.earners[0].deductions.hsaFamilyCoverage = true
        XCTAssertEqual(CashFlow.year(family, family.cashFlow!, year: 0, asOf: asOf).hsaDeferralUsd,
                       Seed.deferralLimits2026.hsaFamilyUsd, accuracy: 0.01)
        XCTAssertNotEqual(Seed.deferralLimits2026.hsaFamilyUsd, Seed.deferralLimits2026.hsaSelfOnlyUsd,
                          "the two caps must differ for this to mean anything")
    }

    /// A flat override WINS over the rate, and only when it is positive.
    func testFlatDeferralOverridesTheRateOnlyWhenPositive() {
        let h = built(intake())
        XCTAssertEqual(yr(h, 0).retirementDeferralUsd, 13_500, accuracy: 0.01, "the 6% rate")
        var flat = h
        flat.cashFlow!.earners[0].deductions.retirementUsdOverride = 20_000
        XCTAssertEqual(CashFlow.year(flat, flat.cashFlow!, year: 0, asOf: asOf).retirementDeferralUsd,
                       20_000, accuracy: 0.01)
    }

    // MARK: - Payroll tax

    /// The Social Security wage base is a PER-PERSON cap. Two spouses each at the base owe
    /// twice one person's OASDI; summing their wages and capping once would pay it once.
    func testOasdiCapIsPerPersonNotPerHousehold() {
        let base = Seed.payroll2026.socialSecurityWageBaseUsd
        let one = Engine.payrollTax(ficaWages: base, filing: .mfj)
        let two = 2 * one
        let lumped = Engine.payrollTax(ficaWages: 2 * base, filing: .mfj)
        XCTAssertGreaterThan(two, lumped, "capping a household total understates OASDI for a couple")

        // The shortfall decomposes into the TWO errors lumping makes, in opposite directions:
        // one whole earner's capped OASDI goes unpaid, and the doubled base wrongly crosses the
        // additional-Medicare threshold that neither earner crosses alone. Naming both is what
        // keeps this from passing against a stub that got the net figure right by accident.
        let p = Seed.payroll2026
        let oasdiMissed = base * p.socialSecurityRateBps.frac
        let surtaxWronglyAdded = max(0, 2 * base - (p.additionalMedicareThresholdUsd[.mfj] ?? 0))
            * p.additionalMedicareRateBps.frac
        XCTAssertGreaterThan(oasdiMissed, 0)
        XCTAssertGreaterThan(surtaxWronglyAdded, 0, "the doubled base must actually cross the threshold")
        XCTAssertEqual(two - lumped, oasdiMissed - surtaxWronglyAdded, accuracy: 1.0)
    }

    /// OASDI stops at the wage base; Medicare never does. Both directions, so a stub that
    /// capped neither or capped both would fail.
    func testOasdiStopsAtTheWageBaseAndMedicareDoesNot() {
        let p = Seed.payroll2026
        let b = p.socialSecurityWageBaseUsd
        let below = Engine.payrollTax(ficaWages: b - 10_000, filing: .single)
        let at = Engine.payrollTax(ficaWages: b, filing: .single)
        let above = Engine.payrollTax(ficaWages: b + 10_000, filing: .single)
        XCTAssertEqual(at - below, 10_000 * (p.socialSecurityRateBps.frac + p.medicareRateBps.frac),
                       accuracy: 1.0, "below the base, both taxes apply")
        XCTAssertEqual(above - at, 10_000 * p.medicareRateBps.frac, accuracy: 1.0,
                       "above it, only Medicare")
    }

    /// The additional Medicare surtax bites above its own threshold and not below, and the MFJ
    /// threshold is the higher one — which is NOT the same as the NIIT threshold even where the
    /// dollar figures coincide.
    func testAdditionalMedicareSurtaxRespectsItsOwnThreshold() {
        let p = Seed.payroll2026
        let single = p.additionalMedicareThresholdUsd[.single] ?? 0
        let mfj = p.additionalMedicareThresholdUsd[.mfj] ?? 0
        XCTAssertGreaterThan(mfj, single)

        let plain = single + 50_000
        let asSingle = Engine.payrollTax(ficaWages: plain, filing: .single)
        let asMfj = Engine.payrollTax(ficaWages: plain, filing: .mfj)
        XCTAssertGreaterThan(asSingle, asMfj, "the single filer crosses the threshold and the couple does not")
        XCTAssertEqual(asSingle - asMfj, 50_000 * p.additionalMedicareRateBps.frac, accuracy: 1.0)

        XCTAssertEqual(Engine.payrollTax(ficaWages: single - 1_000, filing: .single),
                       Engine.payrollTax(ficaWages: single - 1_000, filing: .mfj), accuracy: 0.01,
                       "below both thresholds the filing status cannot matter")
    }

    // MARK: - The tax override and the state leg

    /// The override replaces the WHOLE computed leg. Federal is the stated rate on post-deferral
    /// wages, and payroll and state go to zero — not added on top, which would price the
    /// client's own all-in rate and then charge FICA again.
    func testEffectiveRateOverrideReplacesTheEntireTaxLeg() {
        let h = built(intake())
        var pinned = h
        pinned.cashFlow!.effectiveTaxRateBpsOverride = 3180
        let y = CashFlow.year(pinned, pinned.cashFlow!, year: 0, asOf: asOf)
        XCTAssertEqual(y.payrollTaxUsd, 0, accuracy: 0.01)
        XCTAssertEqual(y.stateIncomeTaxUsd, 0, accuracy: 0.01)
        XCTAssertEqual(y.federalIncomeTaxUsd, y.federalTaxableWagesUsd * 0.318, accuracy: 0.01)
        XCTAssertEqual(y.totalTaxUsd, y.federalTaxableWagesUsd * 0.318, accuracy: 0.01)
        XCTAssertGreaterThan(yr(h, 0).payrollTaxUsd, 0, "the computed leg really is being replaced")
    }

    /// A manual state rate below the proxy raises the surplus, and a rate above it lowers it.
    /// Both directions: a one-sided version would pass against a stub that ignored the basis in
    /// one of them.
    func testManualStateRateMovesTheSurplusInBothDirections() {
        let h = built(intake())
        let proxyBps = Seed.stateTaxProfile(for: "NJ").incomeRate.bps
        XCTAssertGreaterThan(proxyBps, 0, "NJ must tax wages for this to mean anything")

        var lower = h; lower.cashFlow!.stateWageTax = .manual(proxyBps / 2)
        var higher = h; higher.cashFlow!.stateWageTax = .manual(proxyBps * 2)
        let base = yr(h, 0).investableSurplusUsd
        XCTAssertGreaterThan(CashFlow.year(lower, lower.cashFlow!, year: 0, asOf: asOf).investableSurplusUsd, base)
        XCTAssertLessThan(CashFlow.year(higher, higher.cashFlow!, year: 0, asOf: asOf).investableSurplusUsd, base)
    }

    /// In a no-income-tax state the proxy is exactly right at zero, which is why the estimate
    /// finding must stay silent there.
    func testNoIncomeTaxStatePaysNoStateWageTax() {
        var m = intake(); m.state = "FL"
        let h = built(m)
        XCTAssertEqual(yr(h, 0).stateIncomeTaxUsd, 0, accuracy: 0.01)
    }

    // MARK: - Surplus plumbing

    /// A NEGATIVE surplus must reach the FUNDED RATIO signed. The rival is the old
    /// `if capped > 0`, which dropped it: the corpus recursion would still charge the deficit —
    /// so the required return rose — while the funded ratio pretended nothing had happened.
    ///
    /// ISOLATED ON PURPOSE. Comparing a deficit against a SURPLUS cannot see the defect: the
    /// surplus arm's PV is positive either way, so the deficit arm comes out lower whether its
    /// own PV is negative or clamped to zero, and the test passes against the bug. (It did.)
    /// `fundedRatio = (A + savingsPv) / netLiabilityPv` is the only path the surplus takes into
    /// that figure, and assets and liabilities are identical across these two arms, so the
    /// discriminating question is whether the funded ratio responds to the SIZE of a deficit at
    /// all. Clamped, both arms contribute exactly zero and the two ratios are equal.
    func testTheFundedRatioRespondsToTheSizeOfADeficit() {
        var mild = intake()
        mild.currentFixedSpendingUsd = 300_000; mild.currentVariableSpendingUsd = 60_000
        var severe = intake()
        severe.currentFixedSpendingUsd = 450_000; severe.currentVariableSpendingUsd = 60_000

        let hMild = built(mild), hSevere = built(severe)
        XCTAssertLessThan(yr(hMild, 1).investableSurplusUsd, 0, "both arms must be in deficit")
        XCTAssertLessThan(yr(hSevere, 1).investableSurplusUsd, yr(hMild, 1).investableSurplusUsd,
                          "and the second must be the worse of the two")

        let frMild = Engine.requiredReturn(hMild, asOf: asOf).fundedRatioBps
        let frSevere = Engine.requiredReturn(hSevere, asOf: asOf).fundedRatioBps
        XCTAssertLessThan(frSevere, frMild,
                          "a deeper deficit must read as a worse funded ratio, not the same one")
    }

    /// The mirror, and the reason the test above is not vacuous: the funded ratio and the
    /// required return both respond to a SURPLUS in the opposite direction.
    func testASurplusImprovesTheFundedRatioAndLowersTheRequiredReturn() {
        var small = intake()
        small.currentFixedSpendingUsd = 150_000; small.currentVariableSpendingUsd = 0
        var large = intake()
        large.currentFixedSpendingUsd = 60_000; large.currentVariableSpendingUsd = 0

        let hSmall = built(small), hLarge = built(large)
        XCTAssertGreaterThan(yr(hSmall, 1).investableSurplusUsd, 0, "both arms must be in surplus")
        XCTAssertGreaterThan(yr(hLarge, 1).investableSurplusUsd, yr(hSmall, 1).investableSurplusUsd)

        let rrSmall = Engine.requiredReturn(hSmall, asOf: asOf)
        let rrLarge = Engine.requiredReturn(hLarge, asOf: asOf)
        XCTAssertGreaterThan(rrLarge.fundedRatioBps, rrSmall.fundedRatioBps)
        XCTAssertLessThan(rrLarge.requiredRealReturnBps, rrSmall.requiredRealReturnBps,
                          "funding more of the plan from pay lowers the return it needs")
    }

    /// The savings what-if must not be swallowed by the derived path. Moving the slider drops
    /// back to the stated figure, because an arbitrary surplus cannot be decomposed into
    /// income, tax and spending.
    func testTheSavingsOverrideDropsBackToTheStatedPath() {
        let h = built(intake())
        XCTAssertNotNil(h.cashFlow)
        let moved = h.withDriverOverrides(HouseholdOverrides(annualSavingsUsd: 200_000))
        XCTAssertNil(moved.cashFlow, "the override must disable the derived profile")
        XCTAssertEqual(Engine.investableSurplusAtPlanYear(moved, year: 1, asOf: asOf),
                       min(200_000, Engine.wagesAtPlanYear(moved, year: 1, asOf: asOf)),
                       accuracy: 0.01)
        XCTAssertNotEqual(Engine.investableSurplusAtPlanYear(moved, year: 1, asOf: asOf),
                          Engine.investableSurplusAtPlanYear(h, year: 1, asOf: asOf),
                          "the what-if must actually move something")
    }

    /// The decumulation accumulation block now SUMS the per-year surplus forward instead of
    /// using a closed-form annuity. For a constant surplus the two must agree exactly, or every
    /// existing household's retirement starting balance has silently moved.
    func testSummingTheSurplusForwardReproducesTheAnnuityFactor() {
        let n = 29, r = 0.05, s: Usd = 30_000
        let closedForm = s * (pow(1 + r, Double(n)) - 1) / r
        var summed: Usd = 0
        for k in 1...n { summed += s * pow(1 + r, Double(n - k)) }
        XCTAssertEqual(summed, closedForm, accuracy: 0.01)

        var zero: Usd = 0
        for _ in 1...n { zero += s }
        XCTAssertEqual(zero, s * Double(n), accuracy: 0.01, "and the r == 0 branch")
    }

    /// The loop also applies the WAGE CAP the closed form skipped. A household stating savings
    /// above its wages used to have the excess compounded into its retirement balance by
    /// `projectDecumulation` while `requiredReturn` capped it — the two disagreeing about the
    /// same dollars. This is the behaviour change that landing the loop makes, asserted so it
    /// is a decision rather than a side effect.
    func testStatedSavingsAboveWagesIsCappedInTheAccumulationBlock() {
        var m = noSpendingIntake()
        m.annualSavingsUsd = 5_000_000           // far above any year's wages
        let h = built(m)
        XCTAssertNil(h.cashFlow)
        let wages = Engine.wagesAtPlanYear(h, year: 1, asOf: asOf)
        XCTAssertLessThan(wages, m.annualSavingsUsd, "the fixture must exceed its own wages")
        XCTAssertEqual(Engine.investableSurplusAtPlanYear(h, year: 1, asOf: asOf), wages, accuracy: 0.01,
                       "the cap binds, so the accumulation block credits wages, not the stated figure")

        // And the projection no longer starts retirement on money the household never earned:
        // stating $5M of savings against $275k of wages must fund exactly the same plan as
        // stating the wages. Under the old closed form the first figure compounded $5M a year.
        var atWages = m; atWages.annualSavingsUsd = wages
        let a = firstRetirementYearEndBalance(h)
        let b = firstRetirementYearEndBalance(built(atWages))
        XCTAssertEqual(a, b, accuracy: 1.0)
        XCTAssertGreaterThan(a, 0, "the balance must be able to differ")
    }

    // MARK: - Vesting is not wages
    //
    // The double-counting hazard the design named: an AWARDED grant is already on the balance
    // sheet, so crediting its vest as income counts the same units twice.

    func testOnlyExpectedFutureGrantsCountAsCashFlowIncome() {
        var m = intake()
        var grant = IntakeRsuGrant()
        grant.label = "2025 grant"; grant.employer = "EMPLOYER"; grant.ticker = "EMPLOYER"
        grant.unitsUnvested = 1_000; grant.sharePriceUsd = 100
        grant.vestDates = ["\(planYear + 1)-03-01"]
        grant.withholdingBps = 4200
        m.adults[0].rsuGrants = [grant]
        m.adults[0].expectedAnnualGrantUsd = 80_000
        m.adults[0].expectedGrantVestYears = 4
        m.adults[0].grantWithholdingBps = 4200
        let h = built(m)

        let awardedOnBalanceSheet = Engine.unvestedNetUsd(h)
        XCTAssertGreaterThan(awardedOnBalanceSheet, 0, "the awarded grant must be on the balance sheet")

        for t in 1...6 {
            let future = Engine.futureGrantVestingNetInYear(h, year: t, asOf: asOf)
            let all = Engine.vestingNetInYear(h, year: t, asOf: asOf)
            XCTAssertLessThanOrEqual(future, all + 0.01,
                                     "future-only vesting cannot exceed all vesting, year \(t)")
            let ch = Engine.compensationChannels(h, year: t, asOf: asOf)
            XCTAssertEqual(ch.awardedVesting + ch.futureGrantVesting, all, accuracy: 0.01,
                           "the channels must partition total vesting exactly, year \(t)")
        }

        // The awarded tranche vests in plan year 1 and must NOT be future-grant income.
        let awardedYear = 1
        XCTAssertGreaterThan(Engine.vestingNetInYear(h, year: awardedYear, asOf: asOf),
                             Engine.futureGrantVestingNetInYear(h, year: awardedYear, asOf: asOf),
                             "the awarded tranche converts this year and is excluded from income")
    }

    /// The opt-in switch: future vesting is always REPORTED and only added when asked. Both
    /// states, because a stub that always added it would pass a one-sided test.
    func testFutureVestingIsAddedToSurplusOnlyWhenOptedIn() {
        var m = intake()
        m.adults[0].expectedAnnualGrantUsd = 80_000
        m.adults[0].expectedGrantVestYears = 4
        m.adults[0].grantWithholdingBps = 4200
        let off = built(m)
        m.countFutureGrantsAsSavings = true
        let on = built(m)

        let t = 2
        let yOff = yr(off, t), yOn = yr(on, t)
        XCTAssertGreaterThan(yOff.futureEquityVestingUsd, 0, "it must be reported either way")
        XCTAssertEqual(yOff.futureEquityVestingUsd, yOn.futureEquityVestingUsd, accuracy: 0.01)
        XCTAssertEqual(yOn.investableSurplusUsd - yOff.investableSurplusUsd,
                       yOn.futureEquityVestingUsd, accuracy: 0.01,
                       "opting in adds exactly the future vesting and nothing else")
    }

    // MARK: - The GDP growth tie

    /// nil premium ⇒ the typed rate governs, and NOTHING about an existing household moves.
    func testNoPremiumLeavesTheTypedRateAndEveryNumberUntouched() {
        let h = built(intake())
        let c = h.humanCapital[0]
        XCTAssertNil(c.gdpTrendPremiumBps)
        XCTAssertEqual(c.effectiveRealGrowthBps, c.realGrowthRateBps)
        for t in 0...10 {
            let g = c.realGrowthRateBps.frac
            let e = c.compensationSchedule.filter { $0.year <= t }.max { $0.year < $1.year }
            let expected = e.map { $0.totalUsd * pow(1 + g, Double(max(0, t - $0.year))) }
                ?? c.annualIncomeUsd * pow(1 + g, Double(max(0, t - 1)))
            XCTAssertEqual(c.projectedIncomeUsd(planYear: t), expected, accuracy: 0.01,
                           "the pre-tie arithmetic, recomputed independently, year \(t)")
        }
    }

    /// A premium ⇒ the rate is trend + premium, and the human-capital PV moves with it. Both
    /// directions: a negative premium must lower the PV, which is what rules out a stub that
    /// only ever adds growth.
    func testTheGdpTieMovesWageGrowthAndHumanCapitalBothWays() {
        let flat = built(intake())
        var up = intake(); up.adults[0].gdpTrendPremiumBps = 200
        var down = intake(); down.adults[0].gdpTrendPremiumBps = -150
        let hUp = built(up), hDown = built(down)

        XCTAssertEqual(hUp.humanCapital[0].effectiveRealGrowthBps, Seed.gdpTrendRealGrowthBps + 200)
        XCTAssertEqual(hDown.humanCapital[0].effectiveRealGrowthBps, Seed.gdpTrendRealGrowthBps - 150)

        let pvFlat = humanCapitalPv(flat)
        let pvUp = humanCapitalPv(hUp)
        let pvDown = humanCapitalPv(hDown)
        XCTAssertGreaterThan(pvUp, pvFlat, "3.80% real growth must value the career above 1.00%")
        XCTAssertLessThan(pvDown, pvFlat, "0.30% must value it below")
    }

    /// Every growth exponent reads `effectiveRealGrowthBps`. If a reader were left on the raw
    /// field, the tie would move some paths and not others — and the balance sheet would value a
    /// career the projection was not running. The probe: set the premium so the derived rate is
    /// very different from the typed one, and assert the projected path honours the DERIVED rate
    /// exactly, in a year where the two cannot coincide.
    func testProjectedIncomeHonoursTheDerivedRateNotTheTypedOne() {
        var m = intake(); m.adults[0].gdpTrendPremiumBps = 820     // 10.00% real, nothing like 1.00%
        let c = built(m).humanCapital[0]
        XCTAssertEqual(c.effectiveRealGrowthBps, 1000)
        XCTAssertNotEqual(c.effectiveRealGrowthBps, c.realGrowthRateBps,
                          "the rates must differ or this probe is inert")
        // Year 5: governed by the year-1 entry, so the exponent is 4.
        XCTAssertEqual(c.projectedIncomeUsd(planYear: 5), 425_000 * pow(1.10, 4), accuracy: 0.01)
        // And the typed rate would have given something far away from it.
        XCTAssertNotEqual(c.projectedIncomeUsd(planYear: 5), 425_000 * pow(1.01, 4), accuracy: 1_000)
    }

    /// `projectedIncomeUsd` IS the sum of the pair, by construction. One formula, so the split
    /// the waterfall needs and the total the PV needs cannot drift apart.
    func testTheProjectedPairAlwaysSumsToTheProjectedTotal() {
        for premium in [nil, 0, 200, -150] as [Bps?] {
            var m = intake(); m.adults[0].gdpTrendPremiumBps = premium
            let c = built(m).humanCapital[0]
            for t in 0...20 {
                let p = c.projectedCompUsd(planYear: t)
                XCTAssertEqual(p.salary + p.cashBonus, c.projectedIncomeUsd(planYear: t), accuracy: 0.01,
                               "premium \(String(describing: premium)), year \(t)")
            }
        }
    }

    /// The deliberate separation: real wage growth values the CAREER and does not inflate this
    /// year's waterfall. The waterfall is flat in real terms because `wagesAtPlanYear` is, and
    /// the agreement test above is what that buys. A future edit that grows the waterfall
    /// without growing `wagesAtPlanYear` breaks both this and the agreement.
    func testTheGdpTieDoesNotMoveTheWaterfallWhileWagesAtPlanYearIsFlat() {
        var m = intake(); m.adults[0].gdpTrendPremiumBps = 820
        let h = built(m)
        for t in 0...10 {
            XCTAssertEqual(yr(h, t).grossWagesUsd, Engine.wagesAtPlanYear(h, year: t, asOf: asOf),
                           accuracy: 0.01, "year \(t)")
        }
        XCTAssertEqual(yr(h, 5).grossWagesUsd, 425_000, accuracy: 0.01,
                       "stated and flat, not grown at 10%")
    }

    // MARK: - Findings

    private func findings(_ h: Household) -> [Finding] {
        let ev = Engine.evaluate(h, asOf: asOf)
        return ev.findings
    }
    private func has(_ h: Household, _ ruleId: String) -> Bool {
        findings(h).contains { $0.ruleId == ruleId }
    }

    /// The state estimate is reported where it bites, and silent where it cannot: a manual rate,
    /// a no-income-tax state, and a household with no profile at all.
    func testStateWageTaxEstimateFiresOnTheProxyAndIsSilentOtherwise() {
        XCTAssertTrue(has(built(intake()), "state_wage_tax_is_estimated"), "NJ on the proxy")

        var manual = intake(); manual.stateWageTaxEffectiveBps = 450
        XCTAssertFalse(has(built(manual), "state_wage_tax_is_estimated"), "a stated rate is not an estimate")

        var fl = intake(); fl.state = "FL"
        XCTAssertFalse(has(built(fl), "state_wage_tax_is_estimated"), "the proxy is exactly right at zero")

        XCTAssertFalse(has(built(noSpendingIntake()), "state_wage_tax_is_estimated"),
                       "no profile ⇒ no waterfall ⇒ nothing to qualify")
    }

    /// A deficit is reported HARD, and a surplus is silent. Both, because a rule that always
    /// fired would pass a one-sided test.
    func testCashFlowDeficitFiresOnlyWhenTheHouseholdOutspendsItsPay() {
        var deficit = intake()
        deficit.currentFixedSpendingUsd = 300_000; deficit.currentVariableSpendingUsd = 60_000
        let hd = built(deficit)
        XCTAssertLessThan(yr(hd, 0).investableSurplusUsd, 0, "the fixture must be in deficit")
        XCTAssertTrue(has(hd, "cash_flow_deficit"))
        XCTAssertEqual(findings(hd).first { $0.ruleId == "cash_flow_deficit" }?.severity, .hard)

        let hs = built(intake())
        XCTAssertGreaterThan(yr(hs, 0).investableSurplusUsd, 0)
        XCTAssertFalse(has(hs, "cash_flow_deficit"))
    }

    /// The stated-versus-derived gap is reported in BOTH directions, and silent inside the
    /// tolerance. The mirror matters: this codebase has shipped the "too high" half of a rule
    /// twice while the "too low" half went missing.
    func testStatedSavingsGapIsReportedInBothDirectionsAndSilentWhenItAgrees() {
        let h = built(intake())
        let derived = yr(h, 0).investableSurplusUsd
        XCTAssertGreaterThan(derived, 0)

        var understated = intake(); understated.annualSavingsUsd = derived * 0.5
        var overstated = intake(); overstated.annualSavingsUsd = derived * 2.0
        var agreeing = intake(); agreeing.annualSavingsUsd = derived

        XCTAssertTrue(has(built(understated), "stated_savings_contradicts_paystub"),
                      "saving more than the client thinks must be reported")
        XCTAssertTrue(has(built(overstated), "stated_savings_contradicts_paystub"),
                      "saving less than the client thinks must be reported")
        XCTAssertFalse(has(built(agreeing), "stated_savings_contradicts_paystub"),
                       "and agreement must be silent")

        // The two titles are different, so the screen cannot describe one as the other.
        let lowTitle = findings(built(understated)).first { $0.ruleId == "stated_savings_contradicts_paystub" }?.title
        let highTitle = findings(built(overstated)).first { $0.ruleId == "stated_savings_contradicts_paystub" }?.title
        XCTAssertNotEqual(lowTitle, highTitle)
    }
}
