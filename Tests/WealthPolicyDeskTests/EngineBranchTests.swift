import XCTest
@testable import WealthPolicyDesk

/// Three engine branches the 80-test suite never exercised — each shipped a real bug once:
/// the second-death estate tax (dead in every test because both seed households sit below
/// the exemption), the ladder near-term gate (the prefix→filter fix), and the exposure
/// look-through breach detection (the VTI/EM mis-classification).
final class EngineBranchTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"

    // MARK: - Estate / second-death

    /// The sample scaled by `factor` (assets only), to cross the estate exemption.
    private func inflated(_ factor: Double) -> Household {
        var h = Seed.sampleHousehold
        h.positions = h.positions.map { var p = $0; p.marketValueUsd *= factor; p.costBasisUsd *= factor; return p }
        return h
    }
    private func estateTax(_ h: Household) -> Usd { Engine.evaluate(h, asOf: asOf).balanceSheet.liabilities.projectedEstateTaxUsd }

    func testBelowExemptionNoEstateTax() {
        // The Harrisons' ~$2.5M estate sits far below the OBBBA exemption (× 2 people).
        XCTAssertEqual(estateTax(Seed.sampleHousehold), 0, accuracy: 0.5)
    }

    func testAboveExemptionEstateTaxFiresAndReducesNetWorth() {
        let bs = Engine.evaluate(inflated(20), asOf: asOf).balanceSheet   // ~$50M estate
        XCTAssertGreaterThan(bs.liabilities.projectedEstateTaxUsd, 0, "an estate above the exemption owes estate tax")
        // Independent of the exact formula: the estate tax STRICTLY reduces net worth below
        // gross-minus-income-tax (only true because projectedEstateTax > 0 here).
        XCTAssertLessThan(bs.afterTaxNetWorthUsd, bs.grossNetWorthUsd - bs.liabilities.deferredTaxUsd)
        // And the balance-sheet identity: after-tax net worth nets BOTH embedded income tax
        // and the projected estate tax.
        XCTAssertEqual(bs.afterTaxNetWorthUsd,
                       bs.grossNetWorthUsd - bs.liabilities.deferredTaxUsd - bs.liabilities.projectedEstateTaxUsd,
                       accuracy: 1.0)
    }

    func testEstateTaxIsMonotonicInWealth() {
        XCTAssertGreaterThan(estateTax(inflated(30)), estateTax(inflated(20)))
    }

    // MARK: - Ladder near-term gate (prefix → filter)

    /// The sample with its retirement-spending goal replaced by outflows in the given years.
    private func spendingAt(_ years: [Int]) -> Household {
        var h = Seed.sampleHousehold
        h.goals = h.goals.map { g in
            guard g.id == "g_spending" else { return g }
            var g = g
            g.outflows = years.map { Outflow(year: $0, amountUsd: 200_000, inflationLinked: true) }
            return g
        }
        return h
    }

    func testLadderIgnoresOutflowsBeyondItsHorizon() {
        // spendingPolicy pre-funds 7 years. A young accumulator whose spending is 20+ years
        // out has NOTHING to pre-fund — the old prefix(years) grabbed the first 7 outflows
        // even decades away, over-sizing the bond floor.
        let far = spendingAt(Array(20...45))
        let plan = Engine.ladder(far, policy: Seed.spendingPolicy, asOf: asOf)
        XCTAssertEqual(plan.ladderSizeUsd, 0, accuracy: 0.5)
        // Pin the FILTER path, not the guard early-return: the guard returns yearsCovered 0,
        // the real path returns 7 — so a regression dropping the spending goal can't pass here.
        XCTAssertEqual(plan.yearsCovered, 7)
    }

    func testLadderPreFundsNearTermOutflows() {
        let near = spendingAt(Array(1...10))
        XCTAssertGreaterThan(Engine.ladder(near, policy: Seed.spendingPolicy, asOf: asOf).ladderSizeUsd, 0)
    }

    // MARK: - Exposure look-through breaches

    private func book(_ positions: [(ticker: String, sleeve: String, usd: Usd)]) -> Household {
        var h = Seed.sampleHousehold
        h.positions = positions.enumerated().map { i, p in
            Position(id: "p\(i)", accountId: "acct_taxable", ticker: p.ticker, sleeveId: p.sleeve,
                     marketValueUsd: p.usd, costBasisUsd: p.usd * 0.6, layer: .strategic, disposition: .consume, holdToStepUp: false)
        }
        return h
    }

    func testConcentratedBookTripsSectorAndEmBreaches() {
        // 70% XLK (all US Technology) + 30% VWO (emerging markets).
        let m = Engine.exposureMatrix(book([("XLK", "us_sector_tilt", 700_000), ("VWO", "emerging", 300_000)]), asOf: asOf)
        XCTAssertTrue(m.breaches.contains { $0.id == "sector-technology" }, "70% Tech must breach the 38% sector cap")
        XCTAssertTrue(m.breaches.contains { $0.id == "em" }, "30% EM must breach the 15% EM ceiling")
        XCTAssertTrue(m.breaches.contains { $0.id.hasPrefix("cell-") }, "a single country×sector cell is over the cap")
        XCTAssertGreaterThan(m.emBps, 1500)
    }

    /// VTI is TOTAL-MARKET, not a Tech fund — it must NOT trip the Tech sector breach the
    /// way a concentrated XLK book does (the mis-classification that shipped once).
    func testBroadMarketFundIsNotMisclassifiedAsSectorConcentration() {
        let m = Engine.exposureMatrix(book([("VTI", "us_large_core", 1_000_000)]), asOf: asOf)
        XCTAssertFalse(m.breaches.contains { $0.id == "sector-technology" },
                       "a 100% total-market book is diversified — no hard sector breach")
        XCTAssertFalse(m.breaches.contains { $0.id == "em" }, "VTI is US-only — no EM exposure")
    }
}
