import XCTest
@testable import WealthPolicyDesk

/// Guards the fourth batch of audit fixes: the Portfolio tab's per-holding advice. Each of
/// these produced advice a client would recognise as wrong — relocate a muni out of taxable,
/// unwind a position the client had already earmarked to hold, or shrug at half a statement.
final class PortfolioSuggestionTests: XCTestCase {

    private func suggestion(for ticker: String, in m: IntakeModel) -> HoldingSuggestion? {
        Engine.portfolioIntegration(Engine.evaluate(m.buildHousehold()))
            .suggestions.first { $0.ticker.uppercased() == ticker.uppercased() }
    }

    private func held(_ ticker: String, _ usd: Usd = 100_000, basis: Usd = 60_000,
                      treatment: AccountTaxTreatment = .taxable,
                      plan: HeldPositionTreatment = .keepAsCore) -> IntakeHeldPosition {
        var p = IntakeHeldPosition()
        p.ticker = ticker; p.marketValueUsd = usd; p.costBasisUsd = basis
        p.treatment = treatment; p.plan = plan
        return p
    }

    // MARK: - The classifier knows the funds a real statement contains

    /// A typo here silently routes a holding into a sleeve that does not exist, so the
    /// mapping is checked against the policy itself.
    func testEveryMappedFundPointsAtARealSleeve() {
        let ids = Set(Seed.legacyPolicy.sleeves.map { $0.id })
        for (ticker, sleeve) in Seed.commonFundSleeves {
            XCTAssertTrue(ids.contains(sleeve), "\(ticker) maps to '\(sleeve)', which is not a policy sleeve")
        }
    }

    func testWidelyHeldFundsClassifyInsteadOfFallingToReview() {
        let expected: [String: String] = [
            "VTI": "us_large_core", "SPY": "us_large_core", "SCHD": "us_large_core",
            "VXUS": "intl_developed", "IEMG": "emerging", "AGG": "fixed_income_liquid",
            "TIP": "tips", "IWM": "us_mid_small", "SPAXX": "cash", "VMFXX": "cash",
        ]
        for (ticker, sleeve) in expected {
            XCTAssertEqual(Seed.sleeveId(forTicker: ticker), sleeve, "\(ticker) should classify to \(sleeve)")
        }
    }

    /// The convenience table must never shadow the model's own instruments or the
    /// value/growth style ladder.
    func testModelInstrumentsAndStyleLadderStillWin() {
        XCTAssertEqual(Seed.sleeveId(forTicker: "VOO"), "us_large_core")
        XCTAssertEqual(Seed.sleeveId(forTicker: "VLUE"), "us_factor_tilt", "a real factor ETF stays the factor sleeve")
        XCTAssertEqual(Seed.sleeveId(forTicker: "VUG"), "us_large_core", "the growth style flavor is large core")
        XCTAssertEqual(Seed.sleeveId(forTicker: "XLK"), "us_sector_tilt")
    }

    // MARK: - Relocate must be advice the client can act on

    /// A municipal fund belongs in taxable — tax-exempt interest is wasted inside a shelter.
    func testMuniInTaxableIsNotToldToRelocate() {
        var m = IntakeModel()
        m.taxableUsd = 500_000; m.traditionalUsd = 500_000     // a shelter DOES exist
        m.heldAwayPositions = [held("MUB")]
        let s = suggestion(for: "MUB", in: m)
        XCTAssertNotNil(s)
        XCTAssertNotEqual(s?.action, .relocate, "relocating a muni out of taxable inverts its whole purpose")
    }

    /// There is nowhere to relocate to if the household holds only a taxable account.
    func testNoRelocateWhenThereIsNoShelteredAccount() {
        var m = IntakeModel()
        m.taxableUsd = 600_000; m.traditionalUsd = 0; m.rothUsd = 0
        m.heldAwayPositions = [held("BND")]
        let s = suggestion(for: "BND", in: m)
        XCTAssertNotNil(s)
        XCTAssertNotEqual(s?.action, .relocate, "cannot relocate into an account the client does not have")
    }

    /// The genuine case still fires: tax-inefficient, in taxable, with somewhere to move it.
    func testBondsInTaxableStillRelocateWhenAShelterExists() {
        var m = IntakeModel()
        m.taxableUsd = 500_000; m.traditionalUsd = 500_000
        m.heldAwayPositions = [held("BND")]
        XCTAssertEqual(suggestion(for: "BND", in: m)?.action, .relocate)
    }

    // MARK: - The client's declared plan outranks the ladder

    /// A position the client earmarked to hold to step-up must not be told to unwind, and
    /// must not carry a sale-based tax note. The card was previously arguing with itself.
    func testPermanentHoldIsKeptNotUnwound() {
        var m = IntakeModel()
        m.taxableUsd = 800_000
        var p = held("AAPL", 300_000, basis: 40_000, plan: .permanentHold)
        p.isConcentrated = true
        p.sector = .technology
        m.heldAwayPositions = [p]

        guard let s = suggestion(for: "AAPL", in: m) else { return XCTFail("expected AAPL") }
        XCTAssertEqual(s.action, .keep, "the client already declared this one is never sold")
        XCTAssertNil(s.taxNote, "no sale is proposed, so a realized-gain note is misleading")
        XCTAssertTrue(s.rationale.lowercased().contains("held per the plan"))
    }

    /// A concentrated name with NO such earmark still reaches the tax-aware unwind step.
    func testConcentratedNameWithoutAnEarmarkStillUnwinds() {
        var m = IntakeModel()
        m.taxableUsd = 800_000
        var p = held("AAPL", 300_000, basis: 40_000, plan: .keepAsCore)
        p.isConcentrated = true
        p.sector = .technology
        m.heldAwayPositions = [p]

        guard let s = suggestion(for: "AAPL", in: m) else { return XCTFail("expected AAPL") }
        XCTAssertEqual(s.action, .unwind)
        XCTAssertNotNil(s.taxNote, "an unwind in taxable must carry the embedded-gain note")
    }
}
