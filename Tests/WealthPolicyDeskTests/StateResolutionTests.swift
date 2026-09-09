import XCTest
@testable import WealthPolicyDesk

/// Legacy plans stored the state as free text, and three different code paths resolved it:
/// the tax profile trimmed only the ends and fell back to a generic US profile, the intake
/// picker matched differently and fell back to CALIFORNIA, and the IPS printed the raw
/// string. One record could therefore show "California" in the wheel, "resides in N.J." in
/// the prose, and be taxed as neither.
final class StateResolutionTests: XCTestCase {

    /// The spellings that used to diverge.
    func testFreeTextSpellingsAllResolveToTheSameState() {
        for spelling in ["NJ", "nj", " NJ ", "N.J.", "New Jersey", "new jersey", "New  Jersey", "NEW JERSEY"] {
            XCTAssertEqual(Seed.stateTaxProfile(for: spelling).code, "NJ", "\(spelling) did not resolve to NJ")
            XCTAssertEqual(Seed.stateCode(for: spelling), "NJ", "\(spelling) resolved differently through the shared resolver")
        }
    }

    /// The two resolvers must never disagree — that divergence is the defect.
    func testTheTaxProfileAndTheIntakePickerAlwaysAgree() {
        for p in Seed.stateTaxProfiles {
            for spelling in [p.code, p.code.lowercased(), p.name, p.name.uppercased()] {
                let resolved = Seed.stateCode(for: spelling)
                let profile = Seed.stateTaxProfile(for: spelling).code
                XCTAssertEqual(resolved, p.code, "\(spelling) did not resolve to \(p.code)")
                XCTAssertEqual(resolved, profile, "\(spelling): resolver says \(resolved ?? "nil"), profile says \(profile)")
            }
        }
    }

    /// An unrecognised string must resolve to nothing, not silently to California.
    func testAnUnknownStateDoesNotSilentlyBecomeCalifornia() {
        for junk in ["Atlantis", "", "   ", "ZZ", "!!!"] {
            XCTAssertNil(Seed.stateCode(for: junk),
                         "\(junk) resolved to a state; the picker used to make this California")
            XCTAssertEqual(Seed.stateTaxProfile(for: junk).code, "US", "\(junk) must fall back, never crash")
        }
    }

    /// Washington DC and Washington state are distinct, and the substring overlap must not
    /// collapse them.
    func testWashingtonDcIsNotWashingtonState() {
        XCTAssertEqual(Seed.stateTaxProfile(for: "WA").code, "WA")
        XCTAssertEqual(Seed.stateTaxProfile(for: "DC").code, "DC")
        XCTAssertNotEqual(Seed.stateTaxProfile(for: "District of Columbia").code, "WA")
    }

    /// The rate feeds the muni crossover directly, so its sign and ordering must hold.
    func testNoIncomeTaxStatesReadAsZeroAndHighTaxStatesAsHigh() {
        for s in ["TX", "FL", "WA", "NV", "SD", "WY", "AK", "TN", "NH"] {
            XCTAssertEqual(Seed.stateTaxProfile(for: s).incomeRate, 0, accuracy: 1e-9,
                           "\(s) levies no tax on wage or interest income")
        }
        XCTAssertGreaterThan(Seed.stateTaxProfile(for: "CA").incomeRate, Seed.stateTaxProfile(for: "NJ").incomeRate)
        XCTAssertEqual(Seed.stateTaxProfiles.count, 51, "50 states plus DC")
    }
}
