import XCTest
@testable import WealthPolicyDesk

/// Account titling → first-death basis step-up. Locks the per-kind step-up fractions,
/// the community-property what-if, and the rule that an entity interest's inside basis
/// does NOT transmute (so it is excluded from the CP what-if).
final class OwnershipTests: XCTestCase {

    func testStepUpEqualsGainTimesTheTitlingFraction() {
        let e = Engine.titlingStepUp(Seed.sampleHousehold)
        XCTAssertTrue(e.isCouple, "the sample is a couple")
        XCTAssertFalse(e.accounts.isEmpty, "the joint brokerage carries an embedded gain")
        for row in e.accounts {
            XCTAssertEqual(row.firstDeathStepUpUsd,
                           row.embeddedGainUsd * row.kind.firstDeathStepUpFraction, accuracy: 0.5,
                           "\(row.kind) step-up must be the gain times its fraction")
            XCTAssertGreaterThanOrEqual(row.taxSavedUsd, 0)
        }
        XCTAssertEqual(e.totalFirstDeathStepUpUsd, e.accounts.reduce(0) { $0 + $1.firstDeathStepUpUsd }, accuracy: 0.5)
    }

    func testAccountsAreSortedByEmbeddedGainDescending() {
        let rows = Engine.titlingStepUp(Seed.sampleHousehold).accounts
        for (a, b) in zip(rows, rows.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.embeddedGainUsd, b.embeddedGainUsd)
        }
    }

    func testCommunityPropertyStepsUpMoreThanJointTitling() {
        // The sample's taxable account is joint (half step-up); community property would
        // step up the full gain, so its what-if saving must exceed the partial titling.
        let e = Engine.titlingStepUp(Seed.sampleHousehold)
        XCTAssertGreaterThan(e.communityPropertyTaxSavedUsd, e.totalTaxSavedUsd)
    }

    func testEntityInterestIsExcludedFromTheCommunityPropertyWhatIf() {
        var h = Seed.sampleHousehold
        h.accounts = h.accounts.map { a in
            var a = a
            if a.treatment == .taxable { a.ownership = AccountOwnership(kind: .entity) }
            return a
        }
        let e = Engine.titlingStepUp(h)
        XCTAssertGreaterThan(e.totalEmbeddedGainUsd, 0, "the gain is still on the books")
        XCTAssertEqual(e.totalFirstDeathStepUpUsd, 0, "an entity interest gets no first-death step-up")
        XCTAssertEqual(e.communityPropertyTaxSavedUsd, 0, "entity inside basis cannot be transmuted to CP")
    }

    func testSingleFilerHasNoCommunityPropertyWhatIf() {
        let e = Engine.titlingStepUp(IntakeModel().buildHousehold())
        XCTAssertFalse(e.isCouple)
        XCTAssertEqual(e.communityPropertyTaxSavedUsd, 0)
    }
}
