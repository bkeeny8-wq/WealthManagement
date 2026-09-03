import XCTest
@testable import WealthPolicyDesk

/// Guards the tax-input corrections from the full-app audit. Each of these was a number a
/// client could act on that the engine got wrong: a flat RMD age, one IRMAA table for every
/// filing status, a hardcoded New Jersey tax profile with $20k of invented charity, an
/// ignored working spouse, and an IRA that rebalance refused to touch.
final class TaxInputCorrectionTests: XCTestCase {

    // MARK: - RMD required beginning age (SECURE 2.0)

    /// The age is a function of BIRTH YEAR, not a scalar. A flat 73 starts a 1963-born
    /// client's RMDs two years early, overstating forced income and lifetime tax.
    func testRmdStartAgeFollowsBirthYear() {
        XCTAssertEqual(Engine.rmdStartAge(birthDate: "1949-06-01", default: 73), 72, "born before 1951")
        XCTAssertEqual(Engine.rmdStartAge(birthDate: "1951-01-01", default: 73), 73, "born 1951–1959")
        XCTAssertEqual(Engine.rmdStartAge(birthDate: "1959-12-31", default: 73), 73, "last year of the 73 cohort")
        XCTAssertEqual(Engine.rmdStartAge(birthDate: "1960-01-01", default: 73), 75, "SECURE 2.0 moves 1960+ to 75")
        XCTAssertEqual(Engine.rmdStartAge(birthDate: "1963-03-01", default: 73), 75, "the sample's primary")
        XCTAssertEqual(Engine.rmdStartAge(birthDate: "", default: 73), 73, "no birth date falls back to the seed")
    }

    /// The sample's primary is born 1963, so his RMDs must not begin before 75.
    func testSampleRmdsBeginAtSeventyFive() {
        let e = Engine.evaluate(Seed.sampleHousehold)
        let first = e.decumulation.baseline.firstRmdAge
        XCTAssertTrue(first == 0 || first >= 75, "a 1963-born primary cannot have an RMD before 75 (got \(first))")
    }

    // MARK: - IRMAA by filing status

    /// The seeded table was the MFJ schedule. Applied to a single filer it reports no
    /// surcharge across a band where one is actually owed.
    func testIrmaaThresholdsDifferByFilingStatus() {
        let tiers = Seed.tax2026.irmaaTiers
        let magi: Usd = 150_000            // above the single band, below the MFJ band
        let single = Engine.irmaaAnnual(magi: magi, medicareCount: 1, filing: .single, tiers: tiers)
        let mfj = Engine.irmaaAnnual(magi: magi, medicareCount: 1, filing: .mfj, tiers: tiers)
        XCTAssertGreaterThan(single, 0, "a single filer at $150k MAGI owes an IRMAA surcharge")
        XCTAssertEqual(mfj, 0, accuracy: 0.01, "the same MAGI is below the married threshold")
    }

    func testIrmaaScalesWithMedicareCountAndIsZeroBelowTheFirstTier() {
        let tiers = Seed.tax2026.irmaaTiers
        XCTAssertEqual(Engine.irmaaAnnual(magi: 90_000, medicareCount: 2, filing: .single, tiers: tiers), 0, accuracy: 0.01)
        let one = Engine.irmaaAnnual(magi: 300_000, medicareCount: 1, filing: .mfj, tiers: tiers)
        let two = Engine.irmaaAnnual(magi: 300_000, medicareCount: 2, filing: .mfj, tiers: tiers)
        XCTAssertEqual(two, one * 2, accuracy: 0.01, "the surcharge is per enrolled person")
    }

    /// Every filing status must resolve to a band; a missing key silently reported $0.
    func testEveryFilingStatusHasAnIrmaaSchedule() {
        for f in FilingStatus.allCases {
            XCTAssertGreaterThan(Engine.irmaaAnnual(magi: 1_000_000, medicareCount: 1, filing: f, tiers: Seed.tax2026.irmaaTiers), 0,
                                 "\(f) has no IRMAA schedule, so a top-band MAGI reads as no surcharge")
        }
    }

    // MARK: - State tax profile

    /// The engine taxed every household as a New Jersey household.
    func testStateProfilesAreKeyedToTheHousehold() {
        XCTAssertEqual(Seed.stateTaxProfile(for: "TX").incomeRate, 0, accuracy: 1e-9, "Texas has no state income tax")
        XCTAssertEqual(Seed.stateTaxProfile(for: "FL").incomeRate, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(Seed.stateTaxProfile(for: "CA").incomeRate, 0.05, "California is a high-rate state")
        XCTAssertGreaterThan(Seed.stateTaxProfile(for: "NJ").propertyRate, 0.015, "New Jersey property tax is high")
        XCTAssertEqual(Seed.stateTaxProfiles.count, 51, "50 states plus DC")
    }

    func testStateLookupAcceptsCodesNamesAndUnknowns() {
        XCTAssertEqual(Seed.stateTaxProfile(for: "nj").code, "NJ", "case-insensitive")
        XCTAssertEqual(Seed.stateTaxProfile(for: " NJ ").code, "NJ", "whitespace-tolerant")
        XCTAssertEqual(Seed.stateTaxProfile(for: "New Jersey").code, "NJ", "legacy free-text plans stored a full name")
        XCTAssertEqual(Seed.stateTaxProfile(for: "Atlantis").code, "US", "unknown falls back, never crashes")
        XCTAssertEqual(Seed.stateTaxProfile(for: "").code, "US")
    }

    /// Itemization must read the client's OWN state and giving, not invented constants.
    func testItemizationUsesTheHouseholdsStateAndActualGiving() {
        var h = Seed.sampleHousehold
        h.estate.annualGivingUsd = 0
        let nj = Engine.itemizationInput(for: h, asOf: Engine.planningAsOf)
        XCTAssertEqual(nj.charitableUsd, 0, accuracy: 0.01,
                       "a household that gives nothing must not receive a $20,000 deduction")
        h.stateOfResidence = "TX"
        let tx = Engine.itemizationInput(for: h, asOf: Engine.planningAsOf)
        XCTAssertEqual(tx.stateIncomeTaxUsd, 0, accuracy: 0.01, "no state income tax in Texas")
        XCTAssertLessThan(tx.propertyTaxUsd, nj.propertyTaxUsd, "Texas property tax is below New Jersey's")

        h.stateOfResidence = "NJ"
        h.estate.annualGivingUsd = 12_000
        XCTAssertEqual(Engine.itemizationInput(for: h, asOf: Engine.planningAsOf).charitableUsd, 12_000, accuracy: 0.01)
    }

    // MARK: - A working spouse is income

    /// The projection starts at the PRIMARY's retirement, so a younger spouse is often still
    /// earning. Ignoring that made the pre-RMD years look empty and handed the Roth optimizer
    /// a phantom low bracket. Susan works one year past Robert's retirement.
    func testStillWorkingSpouseWagesAppearInOrdinaryIncome() {
        let e = Engine.evaluate(Seed.sampleHousehold)
        guard let firstYear = e.decumulation.baseline.years.first else { return XCTFail("expected a projection") }
        let susanIncome = Seed.sampleHousehold.humanCapital
            .first { $0.personId == "p_susan" }?.annualIncomeUsd ?? 0
        XCTAssertGreaterThan(susanIncome, 0, "fixture check: the spouse earns")
        XCTAssertGreaterThanOrEqual(firstYear.ordinaryIncomeUsd, susanIncome,
                                    "the spouse's final working year must be taxed, not ignored")
    }

    // MARK: - An IRA earmarked to charity still rebalances

    /// `charitableAtDeath` is a beneficiary designation on the ACCOUNT, not a lock on the
    /// instrument. Treating it as unsellable made every tax-deferred holding untouchable,
    /// so rebalance could never trade inside an IRA.
    func testCharitableAtDeathIsSellableOnlyInsideAShelteredAccount() {
        let p = Position(id: "x", accountId: "a", ticker: "BND", sleeveId: "fixed_income_liquid",
                         marketValueUsd: 100_000, costBasisUsd: 90_000, layer: .strategic,
                         disposition: .charitableAtDeath, holdToStepUp: false)
        XCTAssertTrue(Engine.isSellable(p, treatment: .taxDeferred), "an IRA routed to charity still rebalances")
        XCTAssertFalse(Engine.isSellable(p, treatment: .taxable), "in taxable it earmarks the specific low-basis lot")
    }

    func testStepUpEarmarksStillHoldEverywhere() {
        let p = Position(id: "y", accountId: "a", ticker: "VOO", sleeveId: "us_large_core",
                         marketValueUsd: 100_000, costBasisUsd: 10_000, layer: .strategic,
                         disposition: .holdToStepUp, holdToStepUp: true)
        for t in AccountTaxTreatment.allCases {
            XCTAssertFalse(Engine.isSellable(p, treatment: t), "a step-up earmark holds in \(t)")
        }
    }
}
