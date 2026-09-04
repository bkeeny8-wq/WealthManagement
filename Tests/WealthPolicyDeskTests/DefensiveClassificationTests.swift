import XCTest
@testable import WealthPolicyDesk

/// One evaluation used to state two contradictory things about the same book. The
/// allocation table resolves a holding's sleeve from its TICKER when none is stored, but
/// `sleeveRole` — which every risk/liquidity classifier is built on — read only the STORED
/// id. Intake writes every itemized held-away holding with `sleeveId: nil`, so a client who
/// typed in their bond funds saw them counted as fixed income on one tab and as equity on
/// another: the ladder reported $0 of defensive assets and raised a hard liquidity finding
/// against a book that was majority bonds.
final class DefensiveClassificationTests: XCTestCase {

    /// Re-ticker the sample's bond sleeve the way intake writes it: a real fund symbol with
    /// no stored sleeve id.
    private func withHeldAwayBonds(_ ticker: String) -> Household {
        var h = Seed.sampleHousehold
        h.positions = h.positions.map { p in
            guard p.ticker == "MUB" || p.ticker == "BND" else { return p }
            var q = p; q.ticker = ticker; q.sleeveId = nil; return q
        }
        return h
    }

    /// The headline contradiction: the two readings must agree on the same dollars.
    func testTheLadderAndTheAllocationClassifyAHoldingIdentically() {
        for ticker in ["VTEB", "SHY", "TIP", "LQD", "VGIT", "BSV"] {
            let h = withHeldAwayBonds(ticker)
            let e = Engine.evaluate(h)
            let bondsUsd = h.positions.filter { $0.ticker == ticker }.reduce(0) { $0 + $1.marketValueUsd }
            XCTAssertGreaterThan(bondsUsd, 0, "fixture check for \(ticker)")
            XCTAssertGreaterThanOrEqual(e.ladder.availableDefensiveUsd, bondsUsd,
                                        "\(ticker): entered without a sleeve id, it still has to count as defensive")
        }
    }

    /// A Treasury or money-market fund must never read as equity. `isEquity` is the
    /// negation of the fixed-income test, so anything the classifier misses lands there.
    func testMainstreamBondAndCashFundsAreNotEquity() {
        let defensive = ["SHY", "IEI", "IEF", "TLH", "GOVT", "BSV", "BIV", "BLV", "VGSH", "VGIT",
                         "VGLT", "SCHO", "SCHR", "IGSB", "LQD", "VCIT", "VCSH", "TIP", "STIP",
                         "BNDX", "AGG", "SCHZ", "VMFXX", "SPAXX", "SPRXX", "SGOV", "VUSXX", "TBIL"]
        for t in defensive {
            let p = Position(id: t, accountId: "a", ticker: t, sleeveId: nil,
                             marketValueUsd: 100_000, costBasisUsd: 100_000, layer: .strategic,
                             disposition: .consume, holdToStepUp: false)
            XCTAssertTrue(Engine.isFixedIncome(p), "\(t) is a bond or cash fund")
            XCTAssertFalse(Engine.isEquity(p), "\(t) must never be counted as equity risk")
        }
    }

    /// The failure the misclassification produced, end to end: a majority-defensive retiree
    /// told their near-term spending is unfunded.
    func testAMajorityBondRetireeIsNotToldTheirSpendingIsUnfunded() {
        var h = withHeldAwayBonds("SHY")
        // Tip the book heavily defensive: everything that isn't already bonds becomes SHY.
        h.positions = h.positions.map { p in
            guard p.ticker != "SHY", p.layer != .ladder else { return p }
            var q = p; q.ticker = "SHY"; q.sleeveId = nil; return q
        }
        let e = Engine.evaluate(h)
        let defensiveShare = e.ladder.availableDefensiveUsd / max(1, h.portfolioValueUsd)
        XCTAssertGreaterThan(defensiveShare, 0.9,
                             "an all-Treasury book must read as defensive, not as equity")
        XCTAssertFalse(e.findings.contains { $0.ruleId == "liquidity_floor" && $0.severity == .hard },
                       "a book that is over 90% short Treasuries cannot be short of defensive assets")
    }

    /// Stored ids still win — resolving the ticker is a FALLBACK, not an override. A lot the
    /// advisor deliberately assigned to a sleeve must keep that assignment.
    func testAStoredSleeveIdIsNotOverriddenByTheTicker() {
        let p = Position(id: "x", accountId: "a", ticker: "SHY", sleeveId: "us_large_core",
                         marketValueUsd: 100_000, costBasisUsd: 100_000, layer: .strategic,
                         disposition: .consume, holdToStepUp: false)
        XCTAssertTrue(Engine.isEquity(p), "an explicit sleeve assignment governs")
        XCTAssertFalse(Engine.isFixedIncome(p))
    }
}
