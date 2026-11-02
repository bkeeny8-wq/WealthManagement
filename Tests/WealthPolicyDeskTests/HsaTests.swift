import XCTest
@testable import WealthPolicyDesk

/// An HSA is the only triple-tax-advantaged account, and the app had no concept of one:
/// the case-study client's $4,514 Merrill HSA was entered as part of `traditionalUsd`,
/// which charged it ordinary income on every withdrawal and put it on an RMD clock it
/// does not have.
///
/// It is modelled as a `.taxFree` account carrying `isHsa`, NOT as a fourth
/// `AccountTaxTreatment` case. These tests are written to go red under BOTH plausible
/// wrong answers:
///
///   * folding it back into `.taxDeferred` → `testHsaIsNotOnAnRmdClock` and
///     `testHsaLandsInTheTaxFreeBucket` go red;
///   * giving it a fourth treatment case → `testHsaReachesTheDecumulationProjection`,
///     `testHsaCountsInTheFrictionDragDenominator` and
///     `testPlanHoldsEveryDollarTheClientEntered` go red, because every one of those
///     three sums the THREE named treatments and a fourth case drops out of all of them
///     without breaking a single compile.
final class HsaTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"

    /// The first real case study, reduced to the accounts: single NJ filer born 1990,
    /// $16,937 taxable, $252,275 rollover IRA, $4,514 Merrill HSA.
    private func caseStudy(hsa: Usd = 4_514) -> IntakeModel {
        var m = IntakeModel()
        var a = IntakeAdult()
        a.name = "Case"; a.birthYear = 1990; a.retirementAge = 65
        a.salaryUsd = 225_000; a.traditionalUsd = 252_275; a.hsaUsd = hsa
        m.adults = [a]
        m.filingStatus = .single
        m.state = "NJ"
        m.taxableUsd = 16_937
        m.annualSavingsUsd = 20_000
        return m
    }

    // MARK: - It is a tax-free account, flagged, and it is not the Roth

    func testHsaLandsInTheTaxFreeBucket() {
        let h = caseStudy().buildHousehold()
        guard let hsa = h.accounts.first(where: { $0.isHsa }) else {
            return XCTFail("the HSA did not reach the plan as an account at all")
        }
        XCTAssertEqual(hsa.treatment, .taxFree,
                       "an HSA grows tax-free and pays no tax on a qualified-medical withdrawal")
        XCTAssertEqual(h.hsaValueUsd, 4_514, accuracy: 1)
        // The defect being fixed: it used to be part of the traditional balance.
        XCTAssertEqual(h.value(in: .taxDeferred), 252_275, accuracy: 1,
                       "the IRA is $252,275 — the HSA must not be inside it")
        XCTAssertNotEqual(hsa.id, "acct_roth",
                          "the HSA needs its own account, or the plan cannot say which part of the tax-free bucket is conditional")
    }

    /// `hsaValueUsd` is a SUBSET of the tax-free bucket, never a fourth bucket. If this
    /// inverts, every three-treatment sum in the engine has silently lost the HSA.
    func testHsaIsASubsetOfTheTaxFreeBucketAndNotAFourthOne() {
        let h = caseStudy().buildHousehold()
        XCTAssertGreaterThan(h.hsaValueUsd, 0, "fixture check: there is an HSA to find")
        XCTAssertEqual(h.value(in: .taxFree), h.hsaValueUsd, accuracy: 1,
                       "this client's only tax-free money IS the HSA, so the two must agree")
        XCTAssertEqual(h.portfolioValueUsd,
                       h.value(in: .taxable) + h.value(in: .taxDeferred) + h.value(in: .taxFree),
                       accuracy: 1,
                       "the three named treatments must still account for every position")
    }

    /// Conservation. `totalInvestableUsd` is what the intake form quotes the client and
    /// what the CRM row ships; `portfolioValueUsd` is what the plan actually holds.
    func testPlanHoldsEveryDollarTheClientEntered() {
        let m = caseStudy()
        XCTAssertEqual(m.totalInvestableUsd, m.buildHousehold().portfolioValueUsd, accuracy: 1,
                       "the HSA must be in BOTH the quoted total and the plan, or the form contradicts itself")
        XCTAssertEqual(m.statedInvestableUsd, 16_937 + 252_275 + 4_514, accuracy: 1)
    }

    // MARK: - No RMD clock

    /// The reason `.taxDeferred` is the wrong home even though a non-medical withdrawal
    /// after 65 is taxed like one: an HSA has no required minimum distribution, ever.
    func testHsaIsNotOnAnRmdClock() {
        var m = caseStudy()
        m.adults[0].birthYear = 1945          // well past any required beginning age
        m.adults[0].retirementAge = 65
        m.adults[0].traditionalUsd = 0        // the HSA is the only retirement money left
        let h = m.buildHousehold()
        XCTAssertGreaterThan(h.hsaValueUsd, 0, "fixture check: the HSA is the whole retirement book")
        let buckets = Engine.deferredBalancesByOwner(h, asOf: asOf, tax: Seed.tax2026)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.balance }, 0, accuracy: 0.5,
                       "an HSA has no RMD; nothing of it may appear in the deferred/RMD pool")
        XCTAssertEqual(Engine.currentYearRmd(h, asOf: asOf), 0, accuracy: 0.5,
                       "an 81-year-old whose only account is an HSA owes no required distribution")
    }

    // MARK: - The money reaches the engines that sum the three treatments

    /// The decumulation projection opens on `value(in: .taxable)`, `value(in: .taxFree)`
    /// and the deferred-by-owner pool. A fourth treatment case would have left the HSA in
    /// `portfolioValueUsd` and out of the projection entirely — a money leak no existing
    /// test covers.
    func testHsaReachesTheDecumulationProjection() {
        let tax = Seed.tax2026
        func terminalTaxFree(hsa: Usd) -> Usd {
            let h = caseStudy(hsa: hsa).buildHousehold()
            let rr = Engine.requiredReturn(h, asOf: asOf)
            let p = Engine.decumulation(h, tax: tax, rr: rr, asOf: asOf, debitTax: true)
            XCTAssertFalse(p.years.isEmpty, "fixture check: the projection ran")
            return p.years[0].endRothUsd
        }
        let without = terminalTaxFree(hsa: 0)
        let with = terminalTaxFree(hsa: 250_000)
        XCTAssertGreaterThan(with, without + 1_000,
                             "adding $250,000 of HSA must move the projection's tax-free bucket")
    }

    /// `Engine.cmeFrictionDragBps` scales the annual tax drag by the TAXABLE share of the
    /// book, with the three treatments as its denominator. A sheltered dollar the
    /// denominator cannot see over-charges the whole plan and can flip the funded verdict.
    func testHsaCountsInTheFrictionDragDenominator() {
        let bare = caseStudy(hsa: 0).buildHousehold()
        let sheltered = caseStudy(hsa: 500_000).buildHousehold()
        XCTAssertLessThan(Engine.cmeFrictionDragBps(sheltered), Engine.cmeFrictionDragBps(bare),
                          "half a million of sheltered HSA must dilute the taxable share, not be invisible to it")
    }

    // MARK: - The approximation is disclosed, not silent

    /// Pricing the HSA as Roth is right for dollars spent on qualified medical and
    /// overstates after-tax wealth by the ordinary tax on dollars that are not. The engine
    /// does not forecast medical spending — it states the condition and the size of the
    /// approximation.
    func testConditionalExemptionIsDisclosed() {
        let e = Engine.evaluate(caseStudy().buildHousehold(), asOf: asOf)
        guard let f = e.findings.first(where: { $0.ruleId == "hsa_exemption_is_conditional" }) else {
            return XCTFail("holding an HSA priced as tax-free must be disclosed, not assumed away")
        }
        XCTAssertGreaterThan(f.magnitudeUsd, 0, "the disclosure must quantify what is being overstated")
        XCTAssertLessThan(f.magnitudeUsd, 4_514,
                          "the overstatement is the TAX on the balance, not the balance")
    }

    /// The mirror case. Without it the test above passes on a rule that fires for every
    /// household, which would disclose nothing.
    func testNoDisclosureWhenThereIsNoHsa() {
        let e = Engine.evaluate(caseStudy(hsa: 0).buildHousehold(), asOf: asOf)
        XCTAssertNil(e.findings.first(where: { $0.ruleId == "hsa_exemption_is_conditional" }),
                     "a household with no HSA must not be told about one")
    }

    // MARK: - Asset location

    /// A long-horizon bucket that never distributes deserves the growth sleeves, and the
    /// EXISTING machinery already does that — so modelling the HSA as `.taxFree` needs NO
    /// new asset-location rule. Every growth sleeve but one permits tax-free, and the
    /// highest-growth broad sleeve (`us_mid_small`) PREFERS it first. This test pins that
    /// claim so a future edit to Seed's sleeves cannot quietly falsify it.
    ///
    /// The one exception is deliberate and named: `us_sector_tilt` is tax-deferred-only.
    /// Note that its stated reason ("rotation throws short-term gains") does not actually
    /// distinguish tax-free from tax-deferred — short-term gains are equally irrelevant in
    /// a Roth or an HSA — so the exclusion is a policy belief worth revisiting separately,
    /// not something the HSA change should silently alter.
    func testTaxFreeIsAPermittedHomeForTheGrowthSleeves() {
        let growth = Seed.legacyPolicy.sleeves.filter { $0.role == .growth }
        XCTAssertFalse(growth.isEmpty, "fixture check: the policy has growth sleeves")
        let excluded = growth.filter { !$0.locationPreference.contains(.taxFree) }.map { $0.id }
        XCTAssertEqual(excluded, ["us_sector_tilt"],
                       "exactly one growth sleeve may exclude tax-free; any other would rank an HSA last for it and make every buy ticket there call it tax-inefficient")
        XCTAssertEqual(Seed.legacyPolicy.sleeve("us_mid_small")?.locationPreference.first, .taxFree,
                       "the completion-equity sleeve already prefers the tax-free bucket — the HSA inherits the right home for free")
    }
}
