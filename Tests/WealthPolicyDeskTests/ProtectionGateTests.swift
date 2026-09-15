import XCTest
@testable import WealthPolicyDesk

/// The umbrella rule guarded on `umbrellaLimitUsd > 0`, so a household with NO liability
/// cover at all raised nothing while one carrying $1M raised a finding. The gate was silent
/// for exactly the client most exposed, and it rewarded not answering.
///
/// Fixing it needs a way to tell an answered zero from an unanswered question — the same
/// distinction the zeroed dollar defaults made acute everywhere else in intake.
final class ProtectionGateTests: XCTestCase {

    private func household(umbrella: Usd, reviewed: Bool) -> Household {
        var m = IntakeModel()
        var a = IntakeAdult(); a.name = "Ada"; a.birthYear = 1975; a.retirementAge = 65
        a.salaryUsd = 300_000; a.traditionalUsd = 700_000
        m.adults = [a]
        m.taxableUsd = 1_500_000
        m.retirementSpendingUsd = 180_000
        m.umbrellaLimitUsd = umbrella
        m.protectionReviewed = reviewed
        return m.buildHousehold()
    }

    private func findings(_ h: Household) -> [String] {
        Engine.evaluate(h).findings.map(\.ruleId)
    }

    /// The defect: no cover at all must be the LOUDEST case, not the quietest.
    func testNoUmbrellaCoverIsFlagged() {
        let h = household(umbrella: 0, reviewed: true)
        XCTAssertGreaterThan(Engine.evaluate(h).balanceSheet.grossNetWorthUsd, 0, "fixture check: there is something to lose")
        XCTAssertTrue(findings(h).contains("umbrella_thin"),
                      "a household with no liability cover against a seven-figure net worth raised nothing")
    }

    /// And it must outrank a merely thin policy, because it is strictly worse.
    func testNoCoverIsMoreSevereThanThinCover() {
        let none = Engine.evaluate(household(umbrella: 0, reviewed: true))
            .findings.first { $0.ruleId == "umbrella_thin" }
        let thin = Engine.evaluate(household(umbrella: 1_000_000, reviewed: true))
            .findings.first { $0.ruleId == "umbrella_thin" }
        XCTAssertNotNil(none); XCTAssertNotNil(thin)
        XCTAssertEqual(none?.severity, .hard, "no cover at all is a hard finding")
        XCTAssertEqual(thin?.severity, .soft)
        XCTAssertGreaterThan(none?.magnitudeUsd ?? 0, thin?.magnitudeUsd ?? 0)
    }

    /// Adequate cover raises nothing.
    func testAdequateCoverRaisesNothing() {
        XCTAssertFalse(findings(household(umbrella: 10_000_000, reviewed: true)).contains("umbrella_thin"))
    }

    /// An unreviewed section reports as unreviewed — not as an all-clear, and not as a
    /// fabricated gap either.
    func testAnUnreviewedSectionSaysSoRatherThanGoingSilent() {
        let ids = findings(household(umbrella: 0, reviewed: false))
        XCTAssertTrue(ids.contains("protection_not_reviewed"),
                      "silence on an unasked question reads as an all-clear")
        XCTAssertFalse(ids.contains("umbrella_thin"),
                       "and it must not invent a specific gap from an answer nobody gave")
    }

    /// Reviewing the section is itself enough to build a profile — "we checked, and there is
    /// nothing" has to be representable, or the rules never run on the case that matters.
    func testReviewingWithEveryAnswerZeroStillProducesAProfile() {
        XCTAssertNotNil(household(umbrella: 0, reviewed: true).protection,
                        "an all-zero but reviewed household must still be assessed")
        XCTAssertNil(household(umbrella: 0, reviewed: false).protection)
    }

    /// The flag must survive a save and reload, or the review silently un-happens.
    func testTheReviewedFlagRoundTrips() throws {
        var m = IntakeModel(); m.protectionReviewed = true
        let back = try JSONDecoder().decode(IntakeModel.self, from: try JSONEncoder().encode(m))
        XCTAssertTrue(back.protectionReviewed)
    }
}
