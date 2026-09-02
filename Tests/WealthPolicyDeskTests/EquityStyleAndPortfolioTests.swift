import XCTest
@testable import WealthPolicyDesk

/// The US-equity value/growth style overlay and the portfolio-integration classifier.
/// These lock the three behaviours an adversarial review found broken or missing:
/// the style must re-flavor ONLY synthesized proxies, a held VUG is large-core (not the
/// factor satellite), and a rebalance BUY names the styled ETF the book actually holds.
final class EquityStyleAndPortfolioTests: XCTestCase {

    // MARK: - Style overlay: what it may and may not re-flavor

    /// A synthesized policy proxy (it carries a sleeveId) IS re-flavored to the chosen style.
    func testStyleReflavorsSynthesizedProxy() {
        var h = Seed.sampleHousehold
        h.positions = [proxy(ticker: "VOO", sleeveId: "us_large_core")]
        let styled = h.withEquityStyle(USEquityStyleTilt(large: .growth))
        XCTAssertEqual(styled.positions[0].ticker, "VUG", "large=growth must swap the proxy VOO → VUG")
        XCTAssertEqual(styled.positions[0].sleeveId, "us_large_core", "the sleeve must not move")
    }

    /// The client's REAL entered holding (itemized: sleeveId == nil) is never renamed. Silently
    /// rewriting a holding the advisor typed would misrepresent what the client owns.
    func testStyleLeavesRealEnteredHoldingsAlone() {
        var h = Seed.sampleHousehold
        h.positions = [itemized(ticker: "VOO")]
        let styled = h.withEquityStyle(USEquityStyleTilt(large: .value))
        XCTAssertEqual(styled.positions[0].ticker, "VOO", "an entered holding must keep the ticker as typed")
    }

    /// Resetting to blend must map a previously-styled proxy back, not no-op. (The original
    /// guard short-circuited on a neutral tilt, so "reset to blend" silently did nothing.)
    func testResetToBlendRevertsAStyledProxy() {
        var h = Seed.sampleHousehold
        h.positions = [proxy(ticker: "VUG", sleeveId: "us_large_core")]
        let reset = h.withEquityStyle(USEquityStyleTilt())          // all blend
        XCTAssertEqual(reset.positions[0].ticker, "VOO", "neutral must revert the styled proxy to blend")
        XCTAssertTrue(reset.equityStyle.isNeutral)
    }

    /// Each size bucket flavors independently, and only its own holding.
    func testSizeBucketsFlavorIndependently() {
        var h = Seed.sampleHousehold
        h.positions = [proxy(ticker: "VOO", sleeveId: "us_large_core"),
                       proxy(ticker: "VO", sleeveId: "us_mid_small"),
                       proxy(ticker: "VB", sleeveId: "us_mid_small")]
        let styled = h.withEquityStyle(USEquityStyleTilt(large: .growth, mid: .blend, small: .value))
        XCTAssertEqual(styled.positions[0].ticker, "VUG", "large → growth")
        XCTAssertEqual(styled.positions[1].ticker, "VO",  "mid stays blend")
        XCTAssertEqual(styled.positions[2].ticker, "VBR", "small → value")
    }

    // MARK: - Ticker → sleeve classification

    /// VUG is BOTH the large-growth style ETF and an option instrument of us_factor_tilt.
    /// It must classify as large core; the factor sleeve prefers shelter, so misfiling it
    /// there produced a bogus "relocate out of taxable" for a plain growth index fund.
    func testHeldGrowthEtfIsLargeCoreNotTheFactorSleeve() {
        XCTAssertEqual(Seed.sleeveId(forTicker: "VUG"), "us_large_core")
        XCTAssertEqual(Seed.sleeveId(forTicker: "VTV"), "us_large_core")
        XCTAssertEqual(Seed.sleeveId(forTicker: "VBR"), "us_mid_small")
        XCTAssertEqual(Seed.sleeveId(forTicker: "VOT"), "us_mid_small")
        // A genuine single-factor ETF still belongs to the factor sleeve.
        XCTAssertEqual(Seed.sleeveId(forTicker: "VLUE"), "us_factor_tilt")
    }

    func testClassifierCoversFundsSectorsAndSingleNames() {
        XCTAssertEqual(Seed.sleeveId(forTicker: "BND"), "fixed_income_liquid")
        XCTAssertEqual(Seed.sleeveId(forTicker: "XLK"), "us_sector_tilt")
        XCTAssertEqual(Seed.sleeveId(forTicker: "vnq"), "real_assets", "classification is case-insensitive")
        // A single stock has no ticker match; its SECTOR gives it a home. Without a sector
        // it can't be placed, which is why the holding row now captures one.
        XCTAssertEqual(Seed.sleeveId(forTicker: "MSFT", sector: .technology), "us_large_core")
        XCTAssertNil(Seed.sleeveId(forTicker: "MSFT"), "a bare single name has no policy home")
        XCTAssertNil(Seed.sleeveId(forTicker: ""))
    }

    // MARK: - Rebalance buys honor the style

    /// A buy proposal must name the ETF the styled book actually holds, or the advice
    /// contradicts the holdings ("you hold VUG; buy VOO").
    func testRebalanceBuyTickerFollowsTheStyle() {
        guard let large = Seed.legacyPolicy.sleeves.first(where: { $0.id == "us_large_core" }),
              let bonds = Seed.legacyPolicy.sleeves.first(where: { $0.id == "fixed_income_liquid" }) else {
            return XCTFail("expected the seeded sleeves")
        }
        XCTAssertEqual(Engine.styledBuyTicker(for: large, style: USEquityStyleTilt(large: .growth)), "VUG")
        XCTAssertEqual(Engine.styledBuyTicker(for: large, style: USEquityStyleTilt(large: .value)), "VTV")
        XCTAssertEqual(Engine.styledBuyTicker(for: large, style: USEquityStyleTilt()), "VOO", "blend keeps the primary")
        XCTAssertEqual(Engine.styledBuyTicker(for: bonds, style: USEquityStyleTilt(large: .growth)), bonds.primaryTicker,
                       "a non-US-size sleeve is untouched by the equity style")
    }

    // MARK: - Portfolio integration suggestions

    /// A concentrated single name must reach the tax-aware UNWIND step. It usually has no
    /// clean sleeve, so checking classification first sent it to "review" and the
    /// concentration flag was never consulted.
    func testConcentratedSingleNameUnwindsRatherThanReviews() {
        let integ = integration(with: [itemized(ticker: "AAPL", value: 400_000, basis: 50_000, concentrated: true)])
        guard let s = integ.suggestions.first(where: { $0.ticker == "AAPL" }) else { return XCTFail("expected AAPL") }
        XCTAssertEqual(s.action, .unwind)
        XCTAssertNotNil(s.taxNote, "an unwind in a taxable account must carry the gain/budget note")
    }

    /// An alternative is sized by its ALT BUDGET, not the sleeve targets — it should be read
    /// against that budget rather than dumped in "review" for having no sleeve.
    func testAlternativeIsReadAgainstItsAltBudget() {
        let integ = integration(with: [itemized(ticker: "BUFR", value: 100_000, basis: 90_000)])
        guard let s = integ.suggestions.first(where: { $0.ticker == "BUFR" }) else { return XCTFail("expected BUFR") }
        XCTAssertNotEqual(s.action, .review, "a known alternative must not fall to review")
        XCTAssertTrue(s.isPlaced, "an alt has a home in the model (its budget function)")
        XCTAssertEqual(s.sleeveLabel, AltFunction.shapedPayoff.label)
    }

    /// A bond fund parked in taxable is the classic asset-location error.
    func testTaxInefficientHoldingInTaxableRelocates() {
        let integ = integration(with: [itemized(ticker: "BND", value: 200_000, basis: 150_000)])
        guard let s = integ.suggestions.first(where: { $0.ticker == "BND" }) else { return XCTFail("expected BND") }
        XCTAssertEqual(s.action, .relocate)
        XCTAssertEqual(s.sleeveId, "fixed_income_liquid")
    }

    /// Ordering is deterministic and most-pressing first (engines must reproduce).
    func testSuggestionsSortMostPressingFirstAndAreDeterministic() {
        let holdings = [itemized(ticker: "BND", value: 200_000, basis: 150_000),
                        itemized(ticker: "AAPL", value: 400_000, basis: 50_000, concentrated: true)]
        let a = integration(with: holdings).suggestions.map { $0.ticker }
        let b = integration(with: holdings).suggestions.map { $0.ticker }
        XCTAssertEqual(a, b, "the same book must produce the same order")
        XCTAssertEqual(a.first, "AAPL", "unwind outranks relocate")
    }

    // MARK: - helpers

    private func proxy(ticker: String, sleeveId: String) -> Position {
        Position(id: "p_\(ticker)", accountId: "acct_taxable", ticker: ticker, sleeveId: sleeveId,
                 marketValueUsd: 100_000, costBasisUsd: 80_000, layer: .strategic,
                 disposition: .stepUpThenSell, holdToStepUp: false)
    }

    private func itemized(ticker: String, value: Usd = 100_000, basis: Usd = 50_000,
                          concentrated: Bool = false, sector: Sector? = nil) -> Position {
        Position(id: "held_\(ticker)", accountId: "acct_taxable", ticker: ticker, sleeveId: nil,
                 marketValueUsd: value, costBasisUsd: basis, layer: .strategic,
                 disposition: .stepUpThenSell, holdToStepUp: false,
                 isConcentrated: concentrated, sector: sector)
    }

    /// Evaluate the sample with the given itemized holdings appended, then integrate.
    private func integration(with holdings: [Position]) -> PortfolioIntegration {
        var h = Seed.sampleHousehold
        h.positions = h.positions.filter { $0.sleeveId != nil } + holdings
        return Engine.portfolioIntegration(Engine.evaluate(h))
    }
}
