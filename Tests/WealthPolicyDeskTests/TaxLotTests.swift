import XCTest
@testable import WealthPolicyDesk

/// The tax-lot layer — the engine's ability to tell short- from long-term gains and to
/// sell the RIGHT lots tax-first. These lock the two things with a proven regression
/// history: the long-term boundary (the anniversary day itself is still short-term) and
/// `afterSelling`'s ordering + value conservation.
final class TaxLotTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"

    private func lot(_ id: String, mv: Usd, basis: Usd, acq: IsoDate) -> TaxLot {
        TaxLot(id: id, marketValueUsd: mv, costBasisUsd: basis, acquisitionDate: acq)
    }
    private func pos(_ lots: [TaxLot]) -> Position {
        Position(id: "p", accountId: "a", ticker: "T", sleeveId: nil,
                 marketValueUsd: lots.reduce(0) { $0 + $1.marketValueUsd },
                 costBasisUsd: lots.reduce(0) { $0 + $1.costBasisUsd },
                 layer: .strategic, disposition: .consume, holdToStepUp: false, lots: lots)
    }

    // MARK: - The long-term boundary (IRS: MORE than one year)

    func testLongTermBoundaryIsExclusiveOfTheAnniversary() {
        // Exactly one year to the day — still SHORT-term.
        XCTAssertFalse(lot("x", mv: 1, basis: 0, acq: "2025-08-11").isLongTerm(asOf: asOf))
        // One year and a day — long-term.
        XCTAssertTrue(lot("x", mv: 1, basis: 0, acq: "2025-08-10").isLongTerm(asOf: asOf))
        // One year less a day — short-term.
        XCTAssertFalse(lot("x", mv: 1, basis: 0, acq: "2025-08-12").isLongTerm(asOf: asOf))
        // Comfortably over a year (whole-year gap) — long-term.
        XCTAssertTrue(lot("x", mv: 1, basis: 0, acq: "2024-01-01").isLongTerm(asOf: asOf))
        // Same year — short-term.
        XCTAssertFalse(lot("x", mv: 1, basis: 0, acq: "2026-06-01").isLongTerm(asOf: asOf))
        // Unparseable date defaults to long-term (the "unknown vintage" assumption).
        XCTAssertTrue(lot("x", mv: 1, basis: 0, acq: "n/a").isLongTerm(asOf: asOf))
    }

    // MARK: - gainSplit

    func testGainSplitNoLotsIsAllLongTerm() {
        let p = Position(id: "p", accountId: "a", ticker: "T", sleeveId: nil,
                         marketValueUsd: 100_000, costBasisUsd: 60_000,
                         layer: .strategic, disposition: .consume, holdToStepUp: false)
        let (st, lt) = p.gainSplit(asOf: asOf)
        XCTAssertEqual(st, 0)
        XCTAssertEqual(lt, 40_000, accuracy: 0.5)
    }

    func testGainSplitSeparatesShortAndLongTermLots() {
        let p = pos([
            lot("lt", mv: 20_000, basis: 5_000, acq: "2020-01-01"),   // +15k LT
            lot("st", mv: 10_000, basis: 6_000, acq: "2026-06-01"),   // +4k  ST
        ])
        let (st, lt) = p.gainSplit(asOf: asOf)
        XCTAssertEqual(st, 4_000, accuracy: 0.5)
        XCTAssertEqual(lt, 15_000, accuracy: 0.5)
    }

    // MARK: - afterSelling: ordering, remainder, conservation

    /// The four canonical lots, ordered by the tax-first rank: loss → LT-lowest-gain →
    /// LT-highest-gain → ST-last (defer the ordinary-rate gain).
    private var mixedBook: Position {
        pos([
            lot("loss",     mv: 10_000, basis: 15_000, acq: "2020-01-01"),  // −5k  LT (loss)
            lot("lowGain",  mv: 20_000, basis: 18_000, acq: "2020-01-01"),  // +2k  LT  (0.10/$)
            lot("highGain", mv: 20_000, basis:  5_000, acq: "2020-01-01"),  // +15k LT  (0.75/$)
            lot("st",       mv: 10_000, basis:  6_000, acq: "2026-06-01"),  // +4k  ST  (0.40/$)
        ])
    }

    func testAfterSellingHarvestsLossThenLowestGainAndDefersShortTerm() {
        // Sell 25k: consumes the whole loss lot (−5k), then 15k of the low-gain LT lot
        // (+1.5k); the high-gain LT lot and the ST lot are untouched.
        let r = mixedBook.afterSelling(sellUsd: 25_000, asOf: asOf)
        XCTAssertEqual(r.shortTerm, 0, accuracy: 0.5, "the ordinary-rate ST lot must be deferred")
        XCTAssertEqual(r.longTerm, -3_500, accuracy: 0.5, "−5,000 loss + 1,500 of the low-gain lot")

        // Value conservation: what leaves as market value equals what was sold …
        XCTAssertEqual(r.position.marketValueUsd, 35_000, accuracy: 0.5)
        // … and the ST lot is still there (3 lots remain: partial low-gain, high-gain, st).
        XCTAssertEqual(r.position.lots.count, 3)
        XCTAssertTrue(r.position.lots.contains { $0.id == "st" })
        XCTAssertFalse(r.position.lots.contains { $0.id == "loss" })
    }

    func testAfterSellingConservesGain() {
        // Realized gain + gain still embedded in the surviving position = the original gain.
        let originalGain = mixedBook.unrealizedGainUsd   // 16,000
        for sell in [0.0, 5_000.0, 25_000.0, 55_000.0, 60_000.0, 999_999.0] {
            let r = mixedBook.afterSelling(sellUsd: sell, asOf: asOf)
            XCTAssertEqual(r.shortTerm + r.longTerm + r.position.unrealizedGainUsd,
                           originalGain, accuracy: 0.5, "gain must be conserved at sell=\(sell)")
            XCTAssertEqual(r.position.marketValueUsd,
                           60_000 - min(sell, 60_000), accuracy: 0.5, "MV conserved at sell=\(sell)")
        }
    }

    func testSellingEverythingRealizesTheWholeSplit() {
        let (st, lt) = mixedBook.gainSplit(asOf: asOf)
        let r = mixedBook.afterSelling(sellUsd: 60_000, asOf: asOf)
        XCTAssertEqual(r.shortTerm, st, accuracy: 0.5)
        XCTAssertEqual(r.longTerm, lt, accuracy: 0.5)
        XCTAssertEqual(r.position.marketValueUsd, 0, accuracy: 0.5)
        XCTAssertTrue(r.position.lots.isEmpty)
    }

    func testRealizedGainSplitMatchesAfterSelling() {
        let split = mixedBook.realizedGainSplit(sellUsd: 30_000, asOf: asOf)
        let r = mixedBook.afterSelling(sellUsd: 30_000, asOf: asOf)
        XCTAssertEqual(split.shortTerm, r.shortTerm, accuracy: 0.5)
        XCTAssertEqual(split.longTerm, r.longTerm, accuracy: 0.5)
    }

    func testNoLotsSellsProRata() {
        let p = Position(id: "p", accountId: "a", ticker: "T", sleeveId: nil,
                         marketValueUsd: 100_000, costBasisUsd: 60_000,
                         layer: .strategic, disposition: .consume, holdToStepUp: false)
        let r = p.afterSelling(sellUsd: 25_000, asOf: asOf)   // 25% of MV → 25% of the 40k gain
        XCTAssertEqual(r.shortTerm, 0)
        XCTAssertEqual(r.longTerm, 10_000, accuracy: 0.5)
        XCTAssertEqual(r.position.marketValueUsd, 75_000, accuracy: 0.5)
        XCTAssertEqual(r.position.costBasisUsd, 45_000, accuracy: 0.5)
    }

    // MARK: - capitalGainsTax netting (§1(h)-style cross-offset)

    func testShortTermLossOffsetsLongTermGain() {
        let tax = Seed.tax2026
        let withLoss = Engine.capitalGainsTax(shortTerm: -30_000, longTerm: 100_000,
                                              grossOrdinary: 200_000, ordinaryTaxable: 180_000, filing: .single, tax: tax)
        let without = Engine.capitalGainsTax(shortTerm: 0, longTerm: 100_000,
                                             grossOrdinary: 200_000, ordinaryTaxable: 180_000, filing: .single, tax: tax)
        XCTAssertLessThan(withLoss, without, "a short-term loss nets against the long-term gain")
        XCTAssertGreaterThan(withLoss, 0)
    }

    func testNetCapitalLossYieldsZeroTax() {
        let tax = Seed.tax2026
        XCTAssertEqual(Engine.capitalGainsTax(shortTerm: -50_000, longTerm: -10_000,
                                              grossOrdinary: 200_000, ordinaryTaxable: 180_000, filing: .single, tax: tax), 0)
        XCTAssertEqual(Engine.capitalGainsTax(shortTerm: 20_000, longTerm: -50_000,
                                              grossOrdinary: 200_000, ordinaryTaxable: 180_000, filing: .single, tax: tax), 0)
    }
}
