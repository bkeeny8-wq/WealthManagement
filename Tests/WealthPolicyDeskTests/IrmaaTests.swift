import XCTest
@testable import WealthPolicyDesk

/// IRMAA is the Medicare premium surcharge. It is the headline "Lifetime IRMAA" tile, it is
/// debited from the portfolio every year, and it therefore moves RMDs, lifetime tax and the
/// Roth-conversion target the optimizer picks. Two things about it were wrong once the
/// per-filing-status schedules landed: the surcharge was multiplied by head count even for
/// returns whose bands apply to one person's income, and the MAGI it was tested against
/// omitted the tax-exempt interest the rule explicitly adds back.
final class IrmaaTests: XCTestCase {

    private let tiers = Seed.tax2026.irmaaTiers

    // MARK: - Head count

    /// Only the joint schedule is a household schedule. Charging two adults on a single or
    /// married-filing-separately return doubles a surcharge computed on combined income.
    func testOnlyJointFilersAreChargedPerPerson() {
        let magi: Usd = 300_000
        let mfjOne = Engine.irmaaAnnual(magi: magi, medicareCount: 1, filing: .mfj, tiers: tiers)
        let mfjTwo = Engine.irmaaAnnual(magi: magi, medicareCount: 2, filing: .mfj, tiers: tiers)
        XCTAssertEqual(mfjTwo, mfjOne * 2, accuracy: 0.01, "the joint surcharge is per enrolled spouse")

        for filing in FilingStatus.allCases where filing != .mfj {
            let one = Engine.irmaaAnnual(magi: magi, medicareCount: 1, filing: filing, tiers: tiers)
            let two = Engine.irmaaAnnual(magi: magi, medicareCount: 2, filing: filing, tiers: tiers)
            XCTAssertEqual(two, one, accuracy: 0.01,
                           "\(filing): the bands apply to one person's income, so head count cannot double it")
        }
    }

    /// The reachable case. Intake offers all four filing chips regardless of adult count, so
    /// a two-adult MFS household is a real input — and was billed $9,768/yr at $150,000 MAGI
    /// where the truth is between $0 and $4,884.
    func testATwoAdultSeparateReturnIsNotDoubleBilled() {
        let charged = Engine.irmaaAnnual(magi: 150_000, medicareCount: 2, filing: .mfs, tiers: tiers)
        let single = Engine.irmaaAnnual(magi: 150_000, medicareCount: 1, filing: .mfs, tiers: tiers)
        XCTAssertEqual(charged, single, accuracy: 0.01)
        XCTAssertLessThan(charged, 9_768, "the doubled bill was invented")
    }

    func testNoSurchargeBelowTheFirstTier() {
        for filing in FilingStatus.allCases {
            XCTAssertEqual(Engine.irmaaAnnual(magi: 50_000, medicareCount: 2, filing: filing, tiers: tiers), 0,
                           accuracy: 0.01, "\(filing) owes nothing at $50k")
        }
        XCTAssertEqual(Engine.irmaaAnnual(magi: 10_000_000, medicareCount: 0, filing: .mfj, tiers: tiers), 0,
                       accuracy: 0.01, "nobody enrolled in Medicare owes nothing")
    }

    // MARK: - Every filing status needs its OWN schedule

    /// `tiers[filing] ?? tiers[.single]` means a MISSING schedule silently borrows the
    /// single one. The previous test asserted only that a top-band MAGI produces some
    /// surcharge, which the fallback satisfies — delete the `.mfs` entry from the seed and
    /// it still passed, while an MFS filer at $150k under-reported by 55%.
    func testEveryFilingStatusHasItsOwnSeededSchedule() {
        for filing in FilingStatus.allCases {
            XCTAssertNotNil(tiers[filing], "\(filing) has no IRMAA schedule and is silently borrowing another")
            XCTAssertFalse(tiers[filing]?.isEmpty ?? true, "\(filing)'s schedule is empty")
        }
    }

    /// And the schedules must differ where the law differs. Married-filing-separately has
    /// its own compressed bands, so borrowing the single table under-reports materially.
    func testSeparateFilersAreNotOnTheSingleSchedule() {
        let magi: Usd = 150_000
        let mfs = Engine.irmaaAnnual(magi: magi, medicareCount: 1, filing: .mfs, tiers: tiers)
        let single = Engine.irmaaAnnual(magi: magi, medicareCount: 1, filing: .single, tiers: tiers)
        XCTAssertGreaterThan(mfs, 0, "an MFS filer at $150k MAGI owes a surcharge")
        XCTAssertNotEqual(mfs, single, accuracy: 0.01,
                          "MFS is borrowing the single schedule — its own bands are compressed")
    }

    /// The joint bands are wider, so the same MAGI that stings a single filer may not reach
    /// the married threshold at all.
    func testJointThresholdsAreWiderThanSingle() {
        let magi: Usd = 150_000
        XCTAssertGreaterThan(Engine.irmaaAnnual(magi: magi, medicareCount: 1, filing: .single, tiers: tiers), 0)
        XCTAssertEqual(Engine.irmaaAnnual(magi: magi, medicareCount: 1, filing: .mfj, tiers: tiers), 0,
                       accuracy: 0.01, "$150k is below the married threshold")
    }

    // MARK: - Tax-exempt interest is added back

    /// IRMAA MAGI is AGI PLUS tax-exempt interest. Muni income stays out of NIIT and the
    /// SALT phase-down band, which makes the two easy to conflate, but omitting the add-back
    /// puts a retiree just under a step when they have actually cleared it.
    func testMuniInterestRaisesTheIrmaaMagiAndCanCrossAStep() {
        func lifetimeIrmaa(muniShareOfTaxable: Double) -> Usd {
            var h = Seed.sampleHousehold
            h.positions = h.positions.map { p in
                guard h.treatment(of: p) == .taxable else { return p }
                var q = p
                q.ticker = muniShareOfTaxable > 0 ? "MUB" : "VTI"
                q.sleeveId = muniShareOfTaxable > 0 ? "fixed_income_liquid" : "us_large_core"
                return q
            }
            return Engine.evaluate(h).decumulation.baseline.lifetimeIrmaaUsd
        }
        XCTAssertGreaterThan(lifetimeIrmaa(muniShareOfTaxable: 1), lifetimeIrmaa(muniShareOfTaxable: 0),
                             "an all-muni taxable book must raise IRMAA MAGI, not leave it untouched")
    }

    /// The add-back is IRMAA-only. Muni interest must not leak into ordinary income, the
    /// federal tax, or NIIT.
    func testTheAddBackDoesNotLeakIntoOrdinaryIncomeOrFederalTax() {
        var muni = Seed.sampleHousehold
        muni.positions = muni.positions.map { p in
            guard muni.treatment(of: p) == .taxable else { return p }
            var q = p; q.ticker = "MUB"; q.sleeveId = "fixed_income_liquid"; return q
        }
        for y in Engine.evaluate(muni).decumulation.baseline.years {
            XCTAssertEqual(y.magiUsd, y.ordinaryIncomeUsd + y.capitalGainsUsd, accuracy: 0.5,
                           "age \(y.age): the reported MAGI must stay the tax MAGI, not the IRMAA one")
        }
    }
}
