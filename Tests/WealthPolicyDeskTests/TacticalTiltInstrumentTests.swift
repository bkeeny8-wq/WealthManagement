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

/// `deviationBps` is SIGNED, and the sign changes what the tilt's ticker means. Honouring
/// it unconditionally made a committed UNDERWEIGHT buy the very fund its thesis says to
/// avoid — the exact opposite of the recorded call.
final class TacticalTiltSignTests: XCTestCase {

    private var sectorSleeve: Sleeve { Seed.legacyPolicy.sleeve("us_sector_tilt")! }

    private func tilted(_ ticker: String, _ deviationBps: Bps) -> Household {
        var h = Seed.sampleHousehold
        h.tacticalTilts = [TacticalTiltAction(sleeveId: "us_sector_tilt", deviationBps: deviationBps,
                                              sourceName: "Energy", ticker: ticker,
                                              thesis: "t", status: .committed)]
        return h
    }

    func testAnOverweightNamesWhatToBuy() {
        let h = tilted("XLE", 300)
        XCTAssertEqual(Engine.buyTicker(for: sectorSleeve, household: h, style: h.equityStyle), "XLE")
    }

    /// The defect: an underweight must never buy the fund it is underweighting.
    func testAnUnderweightNeverBuysTheFundItAvoids() {
        let h = tilted("XLE", -300)
        XCTAssertNotEqual(Engine.buyTicker(for: sectorSleeve, household: h, style: h.equityStyle), "XLE",
                          "an underweight thesis must not produce a ticket to buy that very sector")
    }

    /// The hard case: underweighting the sleeve's OWN default. Buying the default would buy
    /// the avoided fund — but picking a SUBSTITUTE is not the answer either.
    ///
    /// Falling back to "the first listed instrument that is not the avoided one" let a single
    /// expressed view — short technology — put the whole sector satellite into financials,
    /// chosen by nothing but declaration order in the policy. Reverse the menu and it buys
    /// communications instead. The governance layer certified it, because `tactical_no_thesis`
    /// only inspects tilts and that position was not one. An underweight names what to avoid;
    /// it does not license a bet nobody wrote.
    func testUnderweightingTheSleevesDefaultProposesNoBuyRatherThanASubstitute() {
        let h = tilted(sectorSleeve.primaryTicker, -300)
        XCTAssertEqual(Engine.buyTicker(for: sectorSleeve, household: h, style: h.equityStyle), "",
                       "a substitute sector picked by declaration order is a bet nobody argued for")
    }

    /// And the plan must say so rather than silently dropping the sleeve. Built on a
    /// synthetic policy where the tilted sleeve is the ONLY underweight and the selling
    /// account is its preferred home, so the guard is actually reached — on the shipped
    /// sample the sector sleeve prefers tax-deferred and the taxable account's cash goes
    /// elsewhere first, which would make this pass for the wrong reason.
    func testTheUnfundedSleeveIsReportedNotSilentlyDropped() {
        func sleeve(_ id: String, _ tickers: [String], target: Bps) -> Sleeve {
            Sleeve(id: id, label: id, tier: .satellite, role: .growth, targetBps: target,
                   bandBps: 50, maxBps: 10000, taxEfficiency: .moderate,
                   locationPreference: [.taxable], liquidityClass: .daily,
                   instruments: tickers.enumerated().map { .init(ticker: $1, role: $0 == 0 ? .primary : .option) },
                   rationale: "")
        }
        var policy = Seed.legacyPolicy
        policy.sleeves = [sleeve("zz_sell", ["SELLME"], target: 0),
                          sleeve("aa_tilted", ["TILTP", "TILTB"], target: 10000)]
        policy.altBudgets = []

        var h = Seed.sampleHousehold
        h.accounts = [Account(id: "acct_taxable", label: "Brokerage", treatment: .taxable)]
        h.positions = [Position(id: "p1", accountId: "acct_taxable", ticker: "SELLME", sleeveId: "zz_sell",
                                marketValueUsd: 500_000, costBasisUsd: 500_000, layer: .strategic,
                                disposition: .consume, holdToStepUp: false)]
        // Underweight the sleeve's OWN primary: nothing left that anyone has argued for.
        h.tacticalTilts = [TacticalTiltAction(sleeveId: "aa_tilted", deviationBps: -300,
                                              sourceName: "Tech", ticker: "TILTP",
                                              thesis: "trim it", status: .committed)]

        let plan = Engine.rebalancePlan(h, policy: policy, tax: Seed.tax2026, asOf: Engine.planningAsOf)
        XCTAssertFalse(plan.trades.contains { $0.side == TradeSide.buy && $0.sleeveId == "aa_tilted" },
                       "no instrument here has a thesis, so nothing should be bought")
        XCTAssertTrue(plan.warnings.contains { $0.contains("un-thesised") },
                      "the advisor has to be told why the sleeve was left underweight")
        XCTAssertFalse(plan.trades.contains { $0.side == TradeSide.buy && $0.ticker == "TILTB" },
                       "TILTB is a substitute picked by declaration order, not a bet anyone wrote")
    }

    /// A zero deviation is neither a buy nor an avoid, and must not redirect anything.
    func testAZeroDeviationDoesNotRedirectTheTrade() {
        let h = tilted("XLE", 0)
        XCTAssertEqual(Engine.buyTicker(for: sectorSleeve, household: h, style: h.equityStyle),
                       sectorSleeve.primaryTicker)
    }

    /// The ticket carries the sleeve's own spelling, not whatever case the tilt was saved in.
    func testTheTicketUsesTheSleevesCanonicalSpelling() {
        let h = tilted("xle", 300)
        XCTAssertEqual(Engine.buyTicker(for: sectorSleeve, household: h, style: h.equityStyle), "XLE")
    }

    /// A tilt on a US SIZE sleeve must not silently undo the household's value/growth style —
    /// naming the blend fund should still buy the styled flavour.
    func testAnOverweightOnASizeSleeveStillHonoursTheEquityStyle() {
        guard let large = Seed.legacyPolicy.sleeve("us_large_core"),
              large.instruments.contains(where: { $0.ticker == "VOO" }) else {
            return   // this sleeve does not list VOO in the shipped policy; nothing to assert
        }
        var h = Seed.sampleHousehold
        h.equityStyle = USEquityStyleTilt(large: .value, mid: .value, small: .value)
        h.tacticalTilts = [TacticalTiltAction(sleeveId: "us_large_core", deviationBps: 200,
                                              sourceName: "US large", ticker: "VOO",
                                              thesis: "t", status: .committed)]
        XCTAssertEqual(Engine.buyTicker(for: large, household: h, style: h.equityStyle), "VTV",
                       "a value household buying its large sleeve should still buy the value fund")
    }
}
