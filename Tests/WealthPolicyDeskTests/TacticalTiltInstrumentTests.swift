import XCTest
@testable import WealthPolicyDesk

/// A tactical tilt is a call on a specific exposure, and the sentiment candidate that
/// produces it names the ETF that expresses it — XLE for energy. Staging dropped that
/// ticker: the action recorded the sector's NAME and the sleeve, and the sleeve merely
/// houses the call. `us_sector_tilt` lists all eleven Select Sector SPDRs and its PRIMARY is
/// XLK, so an advisor who staged "overweight Energy", wrote an energy thesis and committed
/// it was handed a ticket to buy TECHNOLOGY — a trade contradicting the thesis printed
/// beside it.
final class TacticalTiltInstrumentTests: XCTestCase {

    private var sectorSleeve: Sleeve { Seed.legacyPolicy.sleeve("us_sector_tilt")! }

    private func householdTilted(to ticker: String, status: TacticalTiltAction.Status = .committed) -> Household {
        var h = Seed.sampleHousehold
        h.tacticalTilts = [TacticalTiltAction(sleeveId: "us_sector_tilt", deviationBps: 300,
                                              sourceName: "Energy", ticker: ticker,
                                              thesis: "real-asset convexity", status: status)]
        return h
    }

    /// The headline: the trade must name the instrument the tilt called for.
    func testATiltedSleeveBuysTheInstrumentTheTiltNamed() {
        let h = householdTilted(to: "XLE")
        XCTAssertEqual(Engine.buyTicker(for: sectorSleeve, household: h, style: h.equityStyle), "XLE",
                       "an energy overweight must buy energy, not the sleeve's default")
    }

    /// Without a tilt, the sleeve's own primary still governs — nothing else changes.
    func testAnUntiltedSleeveStillBuysItsPrimary() {
        let h = Seed.sampleHousehold
        XCTAssertTrue(h.tacticalTilts.isEmpty, "fixture check")
        XCTAssertEqual(Engine.buyTicker(for: sectorSleeve, household: h, style: h.equityStyle),
                       sectorSleeve.primaryTicker)
    }

    /// A STAGED tilt is a preview, not the plan of record, and must not redirect a trade
    /// until it is committed.
    func testAStagedTiltDoesNotRedirectTheTrade() {
        let h = householdTilted(to: "XLE", status: .staged)
        XCTAssertEqual(Engine.buyTicker(for: sectorSleeve, household: h, style: h.equityStyle),
                       sectorSleeve.primaryTicker)
    }

    /// The instrument has to be one the sleeve actually lists, so a stale or hand-edited
    /// tilt cannot send the plan off-policy.
    func testATickerTheSleeveDoesNotListIsIgnored() {
        for junk in ["NVDA", "BITCOIN", ""] {
            let h = householdTilted(to: junk)
            XCTAssertEqual(Engine.buyTicker(for: sectorSleeve, household: h, style: h.equityStyle),
                           sectorSleeve.primaryTicker,
                           "\(junk) is not an instrument of this sleeve and must not be bought")
        }
    }

    /// Every sector SPDR the sleeve lists must be reachable — the menu is the point.
    func testEveryListedSectorInstrumentCanBeTiltedTo() {
        for instrument in sectorSleeve.instruments {
            let h = householdTilted(to: instrument.ticker)
            XCTAssertEqual(Engine.buyTicker(for: sectorSleeve, household: h, style: h.equityStyle),
                           instrument.ticker)
        }
    }

    /// The equity-style tilt still governs the size sleeves, which carry no sector tilt.
    func testTheEquityStyleTiltStillGovernsTheSizeSleeves() {
        var h = Seed.sampleHousehold
        h.equityStyle = USEquityStyleTilt(large: .growth, mid: .growth, small: .growth)
        guard let large = Seed.legacyPolicy.sleeve("us_large_core") else { return XCTFail("missing sleeve") }
        XCTAssertEqual(Engine.buyTicker(for: large, household: h, style: h.equityStyle), "VUG")
    }

    /// The instrument must survive a save and reload, or the tilt silently reverts to the
    /// sleeve's default the next time the book is opened.
    func testTheInstrumentRoundTrips() throws {
        let tilt = TacticalTiltAction(sleeveId: "us_sector_tilt", deviationBps: 300,
                                      sourceName: "Energy", ticker: "XLE", thesis: "t", status: .committed)
        let back = try JSONDecoder().decode(TacticalTiltAction.self, from: try JSONEncoder().encode(tilt))
        XCTAssertEqual(back.ticker, "XLE")
    }

    /// A tilt recorded before this field existed has no instrument, and must keep behaving
    /// exactly as it did — the sleeve's primary.
    func testALegacyTiltWithNoInstrumentFallsBackToThePrimary() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-0000000000BB","createdAt":"2026-01-02T03:04:05Z",
         "sleeveId":"us_sector_tilt","deviationBps":300,"sourceName":"Energy",
         "thesis":"t","status":"committed"}
        """.data(using: .utf8)!
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let tilt = try d.decode(TacticalTiltAction.self, from: legacy)
        XCTAssertEqual(tilt.ticker, "", "no instrument was recorded under the old shape")
        var h = Seed.sampleHousehold
        h.tacticalTilts = [tilt]
        XCTAssertEqual(Engine.buyTicker(for: sectorSleeve, household: h, style: h.equityStyle),
                       sectorSleeve.primaryTicker)
    }
}
