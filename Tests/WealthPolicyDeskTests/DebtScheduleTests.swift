import XCTest
@testable import WealthPolicyDesk

/// Debt used to be ONE balance at ONE rate. The case study's $33,869 is three instruments
/// whose only shared property is that they are all owed: $16,717 on 0% promotional balances
/// that REVERT on a date, $8,545 of float paid off every month, and $8,607 of student loans
/// at 6%. Blended they are "2%", which is true of none of them and silent about the one fact
/// that decides what to do — the date.
///
/// Every test here is written so that reverting its subject turns it RED, and where a
/// plausible WRONG fix exists (pricing every promotional balance at its revert rate, or
/// adding the itemized list to the scalar it replaces) there is a test for that too.
final class DebtScheduleTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"     // Engine.planningAsOf
    private var yr: Int { Engine.year(asOf) }

    // MARK: - fixtures

    private func debt(_ label: String, _ kind: LiabilityKind, _ usd: Usd, _ bps: Bps,
                      promo: IsoDate = "", postPromo: Bps = 0, float: Bool = false) -> IntakeDebt {
        var d = IntakeDebt()
        d.label = label; d.kind = kind; d.balanceUsd = usd; d.rateBps = bps
        d.promoExpiry = promo; d.postPromoRateBps = postPromo; d.paidMonthlyInFull = float
        return d
    }

    /// The case study: single NJ filer born 1990, renting, no mortgage.
    private func caseStudy() -> IntakeModel {
        var m = IntakeModel()
        var a = IntakeAdult(); a.name = "Case"; a.birthYear = 1990; a.retirementAge = 65
        a.salaryUsd = 225_000; a.bonusUsd = 50_000
        m.adults = [a]
        m.state = "NJ"
        m.filingStatus = .single
        m.taxableUsd = 16_937
        m.adults[0].traditionalUsd = 252_275
        m.emergencyReserveUsd = 2_000
        m.retirementSpendingUsd = 120_000
        m.ownsHome = false
        return m
    }

    private func threePieceDebts(promoExpiry: IsoDate = "2027-03-01") -> [IntakeDebt] {
        [debt("Promo cards", .creditCard, 16_717, 0, promo: promoExpiry, postPromo: 2290),
         debt("Card float", .creditCard, 8_545, 0, float: true),
         debt("Aidvantage + Firstmark", .studentFederal, 8_607, 600)]
    }

    private func liability(_ id: String, _ bps: Bps, promo: IsoDate? = nil, postPromo: Bps = 0,
                           usd: Usd = 16_717, float: Bool = false) -> Liability {
        Liability(id: id, kind: .creditCard, balanceUsd: usd, rateBps: bps, fixed: true,
                  maturityDate: nil, durationYears: 0.25, interestDeductible: false,
                  afterTaxRateBps: bps, revocable: false,
                  promoRateExpiry: promo, postPromoRateBps: postPromo, paidMonthlyInFull: float)
    }

    // MARK: - the dated rate itself

    func testPromotionalRateIsInForceUntilItsExpiryAndRevertsAfter() {
        let l = liability("promo", 0, promo: "2027-03-01", postPromo: 2290)
        XCTAssertEqual(l.effectiveRateBps(asOf: "2026-08-11"), 0, "0% while the promotion runs")
        XCTAssertEqual(l.effectiveRateBps(asOf: "2027-02-28"), 0, "still 0% the day before")
        XCTAssertEqual(l.effectiveRateBps(asOf: "2027-03-01"), 2290, "reverts ON the date")
        XCTAssertEqual(l.effectiveRateBps(asOf: "2030-01-01"), 2290, "and stays reverted")
    }

    func testMonthsToRevertCountsDownAndGoesNilOnceItHasReverted() {
        let l = liability("promo", 0, promo: "2027-03-01", postPromo: 2290)
        XCTAssertEqual(l.monthsToPromoRevert(asOf: "2026-08-11"), 7)
        XCTAssertEqual(l.monthsToPromoRevert(asOf: "2027-02-01"), 1)
        XCTAssertNil(l.monthsToPromoRevert(asOf: "2027-03-01"), "on the date there is no deadline left")
        XCTAssertNil(l.monthsToPromoRevert(asOf: "2028-01-01"))
    }

    /// A half-filled row — an expiry typed with no revert rate — must not be honoured. The
    /// mirror of this is the dangerous one: it would price a 0% balance at 0% forever on the
    /// strength of a date the client entered and a rate they didn't.
    func testExpiryWithoutARevertRateIsNotAPromotion() {
        let l = liability("half", 1200, promo: "2027-03-01", postPromo: 0)
        XCTAssertFalse(l.hasPromoRevert)
        XCTAssertEqual(l.effectiveRateBps(asOf: asOf), 1200, "the entered rate still governs")
        XCTAssertNil(l.monthsToPromoRevert(asOf: asOf), "no deadline from an incomplete row")
    }

    func testARevertThatIsNotAnIncreaseIsNotAPromotion() {
        XCTAssertFalse(liability("flat", 2290, promo: "2027-03-01", postPromo: 2290).hasPromoRevert)
        XCTAssertFalse(liability("down", 2290, promo: "2027-03-01", postPromo: 1000).hasPromoRevert)
    }

    func testMonthsBetweenCountsCalendarMonthsAndIsSignSymmetric() {
        XCTAssertEqual(Engine.monthsBetween("2026-08-11", "2027-03-01"), 7)
        XCTAssertEqual(Engine.monthsBetween("2026-08-31", "2026-09-01"), 1, "day of month is ignored")
        XCTAssertEqual(Engine.monthsBetween("2027-03-01", "2026-08-11"), -7)
        XCTAssertEqual(Engine.monthsBetween("2026-08-11", "2026-08-28"), 0)
    }

    // MARK: - paydown: the date decides, and BOTH rates are reported

    private func paydownOf(_ l: Liability, asOf d: IsoDate) -> PaydownAnalysis {
        var h = Seed.sampleHousehold
        h.liabilities = [l]
        return Engine.paydown(l, household: h, tax: Seed.tax2026, asOf: d)
    }

    /// The trap. Priced at today's 0% the spread is about −430bp, the badge reads MAINTAIN,
    /// and the household carries the balance through the revert into the most expensive money
    /// they owe. Inside the twelve-month horizon the governing rate is the one it is about to
    /// carry — so badge, spread and rationale describe the same decision.
    func testPromoRevertingInsideTheHorizonIsPricedAtTheRevertRateAndSaysPayDown() {
        let p = paydownOf(liability("promo", 0, promo: "2027-03-01", postPromo: 2290), asOf: asOf)
        XCTAssertEqual(p.recommendation, .payDown, "a 0% balance reverting in 7 months must not read MAINTAIN")
        XCTAssertEqual(p.afterTaxDebtRateBps, 2290, "priced at the rate it is about to carry")
        XCTAssertGreaterThan(p.spreadBps, 50, "and the spread agrees with the badge")
        XCTAssertEqual(p.currentRateBps, 0, "today's rate is still reported, not overwritten")
        XCTAssertEqual(p.monthsToPromoRevert, 7)
        XCTAssertEqual(p.postPromoRateBps, 2290)
    }

    /// The mirror fault: pricing EVERY promotional balance at its revert rate says PAY DOWN
    /// on free money with three years to run. Beyond the horizon the verdict is maintain —
    /// with the deadline still named, because it is still the plan's most important debt fact.
    func testPromoRevertingBeyondTheHorizonIsHeldAtItsPromotionalRate() {
        let p = paydownOf(liability("promo", 0, promo: "2029-09-01", postPromo: 2290), asOf: asOf)
        XCTAssertEqual(p.recommendation, .maintain, "0% for three more years is free money")
        XCTAssertEqual(p.afterTaxDebtRateBps, 0, "priced at the rate actually in force")
        XCTAssertEqual(p.monthsToPromoRevert, 37, "the deadline is still reported")
        XCTAssertEqual(p.postPromoRateBps, 2290)
        XCTAssertTrue(p.rationale.contains("2029-09-01"), "the rationale must name the date")
    }

    /// Exactly on the horizon boundary, and one month past it. Without this pair the horizon
    /// could be any number at all and both tests above would still pass.
    func testTheHorizonBoundaryIsTwelveMonths() {
        XCTAssertEqual(Engine.promoRevertHorizonMonths, 12)
        let at = paydownOf(liability("at", 0, promo: "2027-08-01", postPromo: 2290), asOf: asOf)
        XCTAssertEqual(at.monthsToPromoRevert, 12)
        XCTAssertEqual(at.recommendation, .payDown, "twelve months is inside the horizon")
        XCTAssertEqual(at.afterTaxDebtRateBps, 2290)
        let past = paydownOf(liability("past", 0, promo: "2027-09-01", postPromo: 2290), asOf: asOf)
        XCTAssertEqual(past.monthsToPromoRevert, 13)
        XCTAssertEqual(past.recommendation, .maintain, "thirteen is outside it")
        // The badge alone cannot pin the boundary: the rationale branch and the pricing branch
        // are separate, so a fix that moved only one of them would still badge this MAINTAIN.
        XCTAssertEqual(past.afterTaxDebtRateBps, 0, "and it is priced at the rate in force, not the revert rate")
    }

    /// After the revert there is no deadline, just an expensive balance. It must still be
    /// priced at the rate it now carries — the promotional `rateBps` is stale history.
    func testAfterTheRevertTheBalanceIsPricedAtTheRateItNowCarries() {
        let p = paydownOf(liability("promo", 0, promo: "2027-03-01", postPromo: 2290), asOf: "2027-06-01")
        XCTAssertNil(p.monthsToPromoRevert, "the deadline has passed")
        XCTAssertEqual(p.afterTaxDebtRateBps, 2290, "a reverted balance is not a 0% balance")
        XCTAssertEqual(p.recommendation, .payDown)
    }

    /// Float paid in full every statement accrues no interest. A 0.00% row badged MAINTAIN
    /// reads as advice to keep carrying a card, so it gets no verdict at all — while staying
    /// fully on the balance sheet, because it IS owed.
    func testFloatPaidMonthlyGetsNoPaydownVerdictButStaysOnTheBalanceSheet() {
        var m = caseStudy()
        m.debts = threePieceDebts()
        let e = Engine.evaluate(m.buildHousehold(asOf: asOf), asOf: asOf)

        let floatId = e.household.liabilities.first { $0.paidMonthlyInFull }?.id
        XCTAssertNotNil(floatId, "fixture check: the float must reach the engine as a liability")
        XCTAssertFalse(e.paydowns.contains { $0.liabilityId == floatId }, "no rate, no verdict")
        XCTAssertEqual(e.paydowns.count, 2, "the promo balance and the student loan still get one")
        XCTAssertEqual(e.balanceSheet.liabilities.debtUsd, 33_869, accuracy: 0.5,
                       "float is not advice-relevant, but it is still owed — all three pieces are on the sheet")
    }

    // MARK: - the finding: the only rule on this desk with a deadline

    private func findings(promoExpiry: IsoDate) -> [Finding] {
        var m = caseStudy()
        m.debts = threePieceDebts(promoExpiry: promoExpiry)
        return Engine.evaluate(m.buildHousehold(asOf: asOf), asOf: asOf).findings
    }

    func testPromoExpiryFiresSoftBetweenSixAndTwelveMonthsOut() {
        let f = findings(promoExpiry: "2027-03-01")           // 7 months
        let hit = f.first { $0.ruleId == "promo_rate_expiring" }
        XCTAssertNotNil(hit, "a 0% balance reverting in 7 months is a planning event")
        XCTAssertEqual(hit?.severity, .soft, "a year out this is still a savings plan")
        XCTAssertEqual(hit?.magnitudeUsd ?? 0, 16_717, accuracy: 0.5)
        XCTAssertTrue(hit?.detail.contains("2027-03-01") ?? false, "the finding must carry the date")
    }

    func testPromoExpiryFiresHardInsideSixMonths() {
        let hit = findings(promoExpiry: "2026-12-01").first { $0.ruleId == "promo_rate_expiring" }   // 4 months
        XCTAssertEqual(hit?.severity, .hard, "four months out the cash has to already be moving")
    }

    func testPromoExpiryIsSilentBeyondTwelveMonthsAndAfterTheRevert() {
        XCTAssertNil(findings(promoExpiry: "2029-09-01").first { $0.ruleId == "promo_rate_expiring" },
                     "three years out there is nothing to act on yet")
        XCTAssertNil(findings(promoExpiry: "2026-01-01").first { $0.ruleId == "promo_rate_expiring" },
                     "once it has reverted the deadline is gone; it is just an expensive balance")
    }

    /// Teeth for the finding's own subject: with no promotional balance in the book the rule
    /// must not fire at all, so a rule that fired unconditionally could not pass this suite.
    func testNoPromoBalanceNoFinding() {
        var m = caseStudy()
        m.debts = [debt("Student", .studentFederal, 8_607, 600)]
        let f = Engine.evaluate(m.buildHousehold(asOf: asOf), asOf: asOf).findings
        XCTAssertNil(f.first { $0.ruleId == "promo_rate_expiring" })
    }

    // MARK: - liquidity floor

    private func ladderWith(_ debts: [IntakeDebt]) -> LadderPlan {
        var m = caseStudy()
        m.debts = debts
        return Engine.evaluate(m.buildHousehold(asOf: asOf), asOf: asOf).ladder
    }

    /// A dated, certain outflow of a known size has to be funded from assets that can
    /// actually be spent. Without this term a renter decades from retirement has a floor of
    /// the rebalance reserve alone, so a $16,717 deadline is invisible to the one rule whose
    /// whole job is near-term liquidity.
    func testLiquidityFloorPreFundsAPromoBalanceRevertingWithinTwelveMonths() {
        let withPromo = ladderWith(threePieceDebts(promoExpiry: "2027-03-01"))
        let without = ladderWith([debt("Card float", .creditCard, 8_545, 0, float: true),
                                  debt("Student", .studentFederal, 8_607, 600)])
        XCTAssertEqual(withPromo.promoRetirementUsd, 16_717, accuracy: 0.5)
        XCTAssertEqual(without.promoRetirementUsd, 0, accuracy: 0.5)
        XCTAssertEqual(withPromo.requiredLiquidUsd - without.requiredLiquidUsd, 16_717, accuracy: 0.5,
                       "the deadline is added to the floor, not averaged into it")
    }

    /// The mirror: a promotional balance three years out is NOT a near-term outflow, and
    /// loading it into today's floor would demand liquidity for money that is still free.
    func testLiquidityFloorIgnoresAPromoBalanceBeyondTwelveMonths() {
        XCTAssertEqual(ladderWith(threePieceDebts(promoExpiry: "2029-09-01")).promoRetirementUsd, 0, accuracy: 0.5)
    }

    /// Ordinary debt is NOT a liquidity-floor item — only the dated deadline is. A rule that
    /// swept every balance into the floor would fail here.
    func testOrdinaryDebtIsNotInTheLiquidityFloor() {
        let plain = ladderWith([debt("Student", .studentFederal, 8_607, 600),
                                debt("Card", .creditCard, 8_545, 2290)])
        XCTAssertEqual(plain.promoRetirementUsd, 0, accuracy: 0.5)
    }

    /// The seeded households carry no promotional balance, so the new term must leave their
    /// floors untouched — this is what lets the golden master stay green.
    func testTheSeededHouseholdsFloorIsUnchanged() {
        let plan = Engine.ladder(Seed.sampleHousehold, policy: Seed.spendingPolicy, asOf: asOf)
        XCTAssertEqual(plan.promoRetirementUsd, 0, accuracy: 0.5)
        XCTAssertEqual(plan.requiredLiquidUsd,
                       plan.ladderSizeUsd + plan.rebalanceReserveUsd + plan.twelveMonthFloorUsd, accuracy: 0.5)
    }

    // MARK: - the list vs the scalar

    /// The scalar is the answer a client gives when they cannot break the total down. It has
    /// to keep working untouched.
    func testScalarAloneStillBuildsOneBlendedLiability() {
        var m = caseStudy()
        m.otherDebtUsd = 33_869; m.otherDebtRateBps = 700
        let h = m.buildHousehold(asOf: asOf)
        XCTAssertEqual(h.liabilities.count, 1)
        XCTAssertEqual(h.liabilities[0].balanceUsd, 33_869, accuracy: 0.5)
        XCTAssertEqual(h.liabilities[0].rateBps, 700)
        XCTAssertEqual(m.resolvedOtherDebtUsd, 33_869, accuracy: 0.5)
    }

    /// The itemized list REPLACES the scalar, exactly as `rsuGrants` replaces
    /// `employerStockUsd`. Adding them is the plausible wrong fix and it invents $33,869 of
    /// debt that does not exist.
    func testItemizedDebtsReplaceTheScalarRatherThanAddingToIt() {
        var m = caseStudy()
        m.otherDebtUsd = 33_869; m.otherDebtRateBps = 700      // the old blended answer
        m.debts = threePieceDebts()                            // the same money, itemized
        let h = m.buildHousehold(asOf: asOf)
        XCTAssertEqual(h.liabilities.count, 3, "three instruments, three liabilities")
        XCTAssertEqual(h.liabilities.reduce(0) { $0 + $1.balanceUsd }, 33_869, accuracy: 0.5,
                       "the list is the same money, not money on top of it")
        XCTAssertEqual(m.resolvedOtherDebtUsd, 33_869, accuracy: 0.5)
    }

    /// Zero-balance rows the advisor started and abandoned must not become liabilities, and
    /// must not make an empty list look itemized and hide the scalar.
    func testBlankDebtRowsDoNotSuppressTheScalar() {
        var m = caseStudy()
        m.otherDebtUsd = 33_869
        m.debts = [IntakeDebt(), IntakeDebt()]
        let h = m.buildHousehold(asOf: asOf)
        XCTAssertEqual(h.liabilities.count, 1, "blank rows are not an itemization")
        XCTAssertEqual(h.liabilities[0].balanceUsd, 33_869, accuracy: 0.5)
    }

    func testEachItemKeepsItsOwnRateKindAndDate() {
        var m = caseStudy()
        m.debts = threePieceDebts()
        let h = m.buildHousehold(asOf: asOf)
        let promo = h.liabilities.first { $0.hasPromoRevert }
        XCTAssertEqual(promo?.rateBps, 0)
        XCTAssertEqual(promo?.postPromoRateBps, 2290)
        XCTAssertEqual(promo?.promoRateExpiry, "2027-03-01")
        XCTAssertEqual(promo?.displayLabel, "Promo cards", "the client's own name identifies the row")
        let student = h.liabilities.first { $0.kind == .studentFederal }
        XCTAssertEqual(student?.rateBps, 600, "6% is not blended away to 2%")
        XCTAssertEqual(h.liabilities.filter { $0.paidMonthlyInFull }.count, 1)
    }

    /// One flat 3.0 for everything put a revolving card and a ten-year student loan on the
    /// same clock, which is the household's net duration quietly wrong by years. A promotional
    /// balance reprices ON its expiry, so time-to-expiry IS its duration.
    func testDurationFollowsTheInstrumentNotOneFlatAssumption() {
        var m = caseStudy()
        m.debts = threePieceDebts()
        let h = m.buildHousehold(asOf: asOf)
        let promo = h.liabilities.first { $0.hasPromoRevert }
        let float = h.liabilities.first { $0.paidMonthlyInFull }
        let student = h.liabilities.first { $0.kind == .studentFederal }
        XCTAssertEqual(promo?.durationYears ?? 0, 7.0 / 12.0, accuracy: 0.01, "it reprices on the expiry date")
        XCTAssertLessThan(float?.durationYears ?? 99, 0.2, "float turns over every month")
        XCTAssertEqual(student?.durationYears, 5.0)
        XCTAssertNotEqual(student?.durationYears, promo?.durationYears,
                          "a card and a student loan must not share one clock")
    }

    // MARK: - schema migration

    /// The data-loss shape this file's siblings guard: the parent decodes `debts` inside a
    /// `try?`, so one element that fails takes EVERY debt with it and the next save writes
    /// the loss to disk.
    func testADebtMissingAKeyDoesNotWipeTheList() throws {
        var m = caseStudy()
        m.debts = threePieceDebts()
        let data = try JSONEncoder().encode(m)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var arr = try XCTUnwrap(obj["debts"] as? [[String: Any]])
        XCTAssertNotNil(arr.first?["rateBps"], "fixture check: the key is there before we strip it")
        arr[0].removeValue(forKey: "rateBps")
        arr[1].removeValue(forKey: "paidMonthlyInFull")
        obj["debts"] = arr
        let back = try JSONDecoder().decode(IntakeModel.self, from: try JSONSerialization.data(withJSONObject: obj))

        XCTAssertEqual(back.debts.count, 3, "all three debts must survive two missing keys")
        XCTAssertEqual(back.debts[0].balanceUsd, 16_717, accuracy: 0.5, "the rest of that row is intact")
        XCTAssertEqual(back.debts[0].promoExpiry, "2027-03-01", "including the date")
        XCTAssertEqual(back.debts[0].rateBps, IntakeDebt().rateBps, "only the absent field falls back")
        XCTAssertEqual(back.debts[2].rateBps, 600, "the untouched row is unaffected")
    }

    func testDebtListRoundTripsThroughJson() throws {
        var m = caseStudy()
        m.debts = threePieceDebts()
        let back = try JSONDecoder().decode(IntakeModel.self, from: try JSONEncoder().encode(m))
        XCTAssertEqual(back.debts, m.debts)
        XCTAssertEqual(back.buildHousehold(asOf: asOf).liabilities.map(\.balanceUsd),
                       m.buildHousehold(asOf: asOf).liabilities.map(\.balanceUsd))
    }

    /// A plan saved before `debts` existed must load with the scalar still driving, not with
    /// an empty itemization that deletes the household's debt.
    func testAPlanSavedBeforeTheListLoadsWithTheScalarStillDriving() throws {
        var m = caseStudy()
        m.otherDebtUsd = 33_869; m.otherDebtRateBps = 700
        let data = try JSONEncoder().encode(m)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "debts")
        let back = try JSONDecoder().decode(IntakeModel.self, from: try JSONSerialization.data(withJSONObject: obj))
        XCTAssertTrue(back.debts.isEmpty)
        XCTAssertEqual(back.buildHousehold(asOf: asOf).liabilities.count, 1)
        XCTAssertEqual(back.resolvedOtherDebtUsd, 33_869, accuracy: 0.5)
    }

    // MARK: - the case study, end to end

    func testCaseStudyThreePiecesReachEveryDebtConsumer() {
        var m = caseStudy()
        m.debts = threePieceDebts()
        let e = Engine.evaluate(m.buildHousehold(asOf: asOf), asOf: asOf)

        // One blended rate could not have produced any of these four facts.
        XCTAssertEqual(e.household.liabilities.count, 3)
        XCTAssertEqual(e.balanceSheet.liabilities.debtUsd, 33_869, accuracy: 0.5)
        XCTAssertTrue(e.findings.contains { $0.ruleId == "promo_rate_expiring" },
                      "the expiring 0% balance is a dated planning event")
        XCTAssertEqual(e.paydowns.count, 2, "the float has no rate to compare")
        let promoId = e.household.liabilities.first { $0.hasPromoRevert }?.id
        XCTAssertEqual(e.paydowns.first { $0.liabilityId == promoId }?.recommendation, .payDown,
                       "pay it before the revert")
        XCTAssertGreaterThan(e.ladder.promoRetirementUsd, 0, "and find the cash for it")
    }
}
