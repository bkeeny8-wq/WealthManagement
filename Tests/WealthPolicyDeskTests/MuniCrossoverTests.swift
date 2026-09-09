import XCTest
@testable import WealthPolicyDesk

/// The muni-vs-taxable verdict ignored the state income rate entirely. Seed carries 51
/// state profiles and Seed's own comment claims they drive this crossover; they moved it by
/// exactly 0 bps. The taxable-equivalent yield read 530 for the sample in Texas, New Jersey
/// and California alike.
///
/// The rate cannot simply be added to a gross-up, because the three instruments are taxed
/// asymmetrically: a national muni fund is federally exempt but state-taxable, a Treasury is
/// federally taxable but state-exempt, and a corporate bond is taxed by both. The verdict
/// therefore compares after-tax yields directly.
final class MuniCrossoverTests: XCTestCase {

    private func crossover(state: String, muni: Bps = 340, treasury: Bps = 430, corporate: Bps = 520) -> MuniCrossover {
        var h = Seed.sampleHousehold
        h.stateOfResidence = state
        return Engine.muniCrossover(h, tax: Seed.tax2026, muniYieldBps: muni, treasuryYieldBps: treasury, corporateYieldBps: corporate)
    }

    /// The headline: the seeded profiles must actually reach this verdict.
    func testTheStateRateMovesTheCrossover() {
        let tx = crossover(state: "TX"), nj = crossover(state: "NJ"), ca = crossover(state: "CA")
        XCTAssertEqual(tx.stateIncomeRateBps, 0, "Texas has no state income tax")
        XCTAssertGreaterThan(nj.stateIncomeRateBps, 0)
        XCTAssertGreaterThan(ca.stateIncomeRateBps, nj.stateIncomeRateBps, "California is the higher-rate state")

        XCTAssertNotEqual(tx.taxableEquivalentYieldBps, nj.taxableEquivalentYieldBps,
                          "the state rate is not reaching the taxable-equivalent yield")
        XCTAssertLessThan(tx.taxableEquivalentYieldBps, ca.taxableEquivalentYieldBps,
                          "a higher state rate raises the taxable yield a muni has to beat")
    }

    /// A national muni fund is STATE-TAXABLE, so its after-tax yield falls as the state rate
    /// rises. Treating it as exempt from both would overstate the muni case.
    func testANationalMuniFundIsTaxedByTheHoldersState() {
        XCTAssertEqual(crossover(state: "TX").muniAfterTaxBps, 340, "nothing to tax in Texas")
        XCTAssertLessThan(crossover(state: "CA").muniAfterTaxBps, 340,
                          "a national fund's income is taxable in California")
        XCTAssertLessThan(crossover(state: "CA").muniAfterTaxBps, crossover(state: "NJ").muniAfterTaxBps)
    }

    /// Treasuries are the mirror — state-exempt — so their after-tax yield must NOT move
    /// with the state rate. Getting this backwards is the easy error.
    func testTreasuriesAreStateExemptSoTheirAfterTaxYieldIsStateInvariant() {
        let states = ["TX", "NJ", "CA", "NY", "FL"]
        let yields = Set(states.map { crossover(state: $0).treasuryAfterTaxBps })
        XCTAssertEqual(yields.count, 1, "Treasury interest is exempt from state tax in every state (got \(yields))")
    }

    /// Corporates are taxed by both, so they fall fastest — which is why muni preference
    /// STRENGTHENS in a high-tax state rather than weakening.
    func testCorporatesFallFastestSoMuniPreferenceStrengthensInHighTaxStates() {
        let tx = crossover(state: "TX"), ca = crossover(state: "CA")
        XCTAssertLessThan(ca.corporateAfterTaxBps, tx.corporateAfterTaxBps)
        let txEdge = tx.muniAfterTaxBps - max(tx.treasuryAfterTaxBps, tx.corporateAfterTaxBps)
        let caEdge = ca.muniAfterTaxBps - max(ca.treasuryAfterTaxBps, ca.corporateAfterTaxBps)
        XCTAssertGreaterThan(caEdge, txEdge, "the muni advantage must widen in a high-tax state")
    }

    /// The verdict has to be able to flip — a crossover that always says the same thing is
    /// not a crossover.
    func testTheVerdictFlipsWhenTheTaxableYieldIsHighEnough() {
        XCTAssertTrue(crossover(state: "CA").muniPreferred, "at a 3.40% muni vs 5.20% corporate in CA, muni wins")
        XCTAssertFalse(crossover(state: "TX", muni: 200, corporate: 700).muniPreferred,
                       "a 2.00% muni cannot beat a 7.00% corporate in a no-income-tax state")
    }

    /// The preference must follow the after-tax yields it reports, not a separate rule.
    func testTheVerdictAgreesWithTheAfterTaxYieldsItReports() {
        for state in ["TX", "NJ", "CA", "NY", "WA"] {
            for muni in [200, 340, 500] {
                let mc = crossover(state: state, muni: muni)
                XCTAssertEqual(mc.muniPreferred, mc.muniAfterTaxBps > max(mc.treasuryAfterTaxBps, mc.corporateAfterTaxBps),
                               "\(state) at \(muni) bps: the verdict contradicts the rows shown beside it")
            }
        }
    }
}
