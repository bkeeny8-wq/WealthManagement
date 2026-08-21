import XCTest
@testable import WealthPolicyDesk

/// The tax primitives that the required-return, decumulation, and disposition engines
/// all lean on. Property + characterization tests (monotonicity, ST-vs-LT ordering,
/// the ISO/QSBS flags on the sample) rather than hand-computed goldens.
final class TaxTests: XCTestCase {

    private let tax = Seed.tax2026

    func testProgressiveTaxIsMonotonicAndZeroAtZero() {
        let brackets = tax.ordinaryBrackets[.single]!
        XCTAssertEqual(Engine.progressiveTax(0, brackets: brackets), 0, accuracy: 0.5)
        XCTAssertGreaterThan(Engine.progressiveTax(100_000, brackets: brackets), 0)
        XCTAssertGreaterThan(Engine.progressiveTax(500_000, brackets: brackets),
                             Engine.progressiveTax(100_000, brackets: brackets))
    }

    func testShortTermGainsTaxedHigherThanLongTerm() {
        let st = Engine.capitalGainsTax(shortTerm: 100_000, longTerm: 0,
                                        grossOrdinary: 200_000, ordinaryTaxable: 180_000, filing: .single, tax: tax)
        let lt = Engine.capitalGainsTax(shortTerm: 0, longTerm: 100_000,
                                        grossOrdinary: 200_000, ordinaryTaxable: 180_000, filing: .single, tax: tax)
        XCTAssertGreaterThan(lt, 0)
        XCTAssertGreaterThan(st, lt, "short-term gains are taxed as ordinary income, above the LTCG rate")
    }

    func testCapitalGainsTaxIsMonotonicInGain() {
        func t(_ lt: Usd) -> Usd {
            Engine.capitalGainsTax(shortTerm: 0, longTerm: lt, grossOrdinary: 150_000, ordinaryTaxable: 130_000, filing: .mfj, tax: tax)
        }
        XCTAssertGreaterThan(t(300_000), t(100_000))
        XCTAssertGreaterThan(t(100_000), t(0))
    }

    func testLtcgTaxOnGainMonotonic() {
        let h = Seed.sampleHousehold
        let t0 = Engine.ltcgTaxOnGain(h, gain: 0)
        let t1 = Engine.ltcgTaxOnGain(h, gain: 100_000)
        let t2 = Engine.ltcgTaxOnGain(h, gain: 300_000)
        XCTAssertGreaterThanOrEqual(t0, 0)
        XCTAssertGreaterThan(t1, t0)
        XCTAssertGreaterThan(t2, t1)
    }

    func testIsoAmtOnSample() {
        let iso = Engine.isoAmt(Seed.sampleHousehold)
        XCTAssertNotNil(iso, "the sample carries a planned ISO exercise-and-hold")
        guard let iso else { return }
        XCTAssertEqual(iso.bargainElementUsd, 220_000, accuracy: 0.5)
        XCTAssertGreaterThan(iso.amtOwedUsd, 0)
        XCTAssertGreaterThanOrEqual(iso.crossoverBargainUsd, 0)
        XCTAssertLessThanOrEqual(iso.crossoverBargainUsd, iso.bargainElementUsd,
                                 "the AMT-free crossover cannot exceed the full bargain element")
    }

    func testQsbsExclusionOnSample() {
        let q = Engine.qsbsExclusion(Seed.sampleHousehold)
        XCTAssertNotNil(q)
        if let q {
            XCTAssertGreaterThan(q.perIssuerCapUsd, 0)
            XCTAssertGreaterThan(q.maxFederalTaxExcludedUsd, 0)
        }
    }
}
