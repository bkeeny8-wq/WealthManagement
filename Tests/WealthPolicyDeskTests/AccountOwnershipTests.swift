import XCTest
@testable import WealthPolicyDesk

/// Intake modelled the whole household as three lump sums — one taxable, one traditional,
/// one Roth — with every retirement dollar implicitly owned by the PRIMARY. There is no
/// such thing as a joint IRA, and the simplification was not cosmetic: it made per-owner
/// required distributions unreachable from intake (only the hand-built sample had two
/// owners), and it let the model pretend a wife's 401(k) could fund a purchase in her
/// husband's IRA.
final class AccountOwnershipTests: XCTestCase {

    private func couple(traditional: (Usd, Usd), roth: (Usd, Usd) = (0, 0),
                        births: (Int, Int) = (1975, 1975)) -> IntakeModel {
        var m = IntakeModel()
        var a = IntakeAdult(); a.name = "Ada"; a.birthYear = births.0; a.retirementAge = 65
        a.salaryUsd = 200_000; a.traditionalUsd = traditional.0; a.rothUsd = roth.0
        var b = IntakeAdult(); b.name = "Ben"; b.birthYear = births.1; b.retirementAge = 65
        b.salaryUsd = 150_000; b.traditionalUsd = traditional.1; b.rothUsd = roth.1
        m.adults = [a, b]
        m.taxableUsd = 500_000
        return m
    }

    // MARK: - Accounts belong to people

    func testEachAdultGetsTheirOwnRetirementAccounts() {
        let h = couple(traditional: (600_000, 400_000), roth: (100_000, 50_000)).buildHousehold()
        let deferred = h.accounts.filter { $0.treatment == .taxDeferred }
        XCTAssertEqual(deferred.count, 2, "two adults with IRAs means two accounts, not one pooled balance")
        XCTAssertEqual(Set(deferred.compactMap { $0.ownership.ownerPersonId }), ["p_0", "p_1"])

        func value(_ accountId: String) -> Usd {
            h.positions.filter { $0.accountId == accountId }.reduce(0) { $0 + $1.marketValueUsd }
        }
        XCTAssertEqual(value("acct_trad"), 600_000, accuracy: 1, "Ada's balance stays Ada's")
        XCTAssertEqual(value("acct_trad_1"), 400_000, accuracy: 1, "Ben's balance stays Ben's")
        XCTAssertEqual(value("acct_roth"), 100_000, accuracy: 1)
        XCTAssertEqual(value("acct_roth_1"), 50_000, accuracy: 1)
    }

    /// The primary keeps the original account ids, so a committed move recorded against
    /// `acct_trad` before this change still finds its account and replays.
    func testThePrimaryKeepsTheOriginalAccountIds() {
        let h = couple(traditional: (600_000, 400_000), roth: (100_000, 0)).buildHousehold()
        XCTAssertNotNil(h.account("acct_trad"), "the pre-existing traditional account id must survive")
        XCTAssertNotNil(h.account("acct_roth"), "the pre-existing Roth account id must survive")
    }

    /// An adult with no retirement money gets no empty account.
    func testAnAdultWithNoRetirementBalanceGetsNoAccount() {
        let h = couple(traditional: (600_000, 0)).buildHousehold()
        XCTAssertNil(h.account("acct_trad_1"), "an empty account is noise, not structure")
        XCTAssertEqual(h.accounts.filter { $0.treatment == .taxDeferred }.count, 1)
    }

    // MARK: - The reason it matters

    /// The payoff: with the balances owned, each distributes on its own owner's schedule.
    /// Under the lump-sum model both were the primary's, so this was unreachable from intake.
    func testEachAccountDistributesOnItsOwnOwnersSchedule() {
        // Ada b. 1948 (RMDs at 72), Ben b. 1965 (RMDs at 75) — seventeen years apart.
        var m = couple(traditional: (500_000, 500_000), births: (1948, 1965))
        m.adults[0].retirementAge = 62; m.adults[1].retirementAge = 62
        m.retirementStartAge = 62
        let e = Engine.evaluate(m.buildHousehold())

        guard let first = e.decumulation.baseline.years.first(where: { $0.rmdUsd > 0 }) else {
            return XCTFail("expected distributions to begin")
        }
        // Ada is already 78, so hers are overdue immediately; Ben's wait years.
        XCTAssertEqual(first.age, e.decumulation.baseline.years.first?.age,
                       "the older owner's account must distribute from the first projected year")
        // Only Ada's half is distributing at first, so the amount must be well under a
        // divisor applied to the whole pooled balance.
        let pooled = 1_000_000.0 / Engine.uniformLifetimeDivisor(78)
        XCTAssertLessThan(first.rmdUsd, pooled * 0.75,
                          "the whole pool is distributing — the younger owner's account was pulled in early")
    }

    // MARK: - Nothing saved under the old shape moves

    /// The household totals still read and write, so every existing call site keeps working.
    /// Assigning puts the balance on the primary, which is exactly what the model did before.
    func testTheHouseholdTotalsStillReadAndWrite() {
        var m = IntakeModel()
        m.traditionalUsd = 750_000
        m.rothUsd = 125_000
        XCTAssertEqual(m.traditionalUsd, 750_000, accuracy: 1)
        XCTAssertEqual(m.adults[0].traditionalUsd, 750_000, accuracy: 1, "a bare assignment lands on the primary")

        let two = couple(traditional: (600_000, 400_000), roth: (100_000, 50_000))
        XCTAssertEqual(two.traditionalUsd, 1_000_000, accuracy: 1, "reading gives the household total")
        XCTAssertEqual(two.rothUsd, 150_000, accuracy: 1)
        XCTAssertEqual(two.totalInvestableUsd, 500_000 + 1_000_000 + 150_000, accuracy: 1)
    }

    /// A plan saved under the old shape — household totals on the model, nothing per adult —
    /// must load with the money on the primary, evaluating exactly as it did before.
    func testALegacyPlanMigratesOntoThePrimary() throws {
        let legacy = """
        {"adults":[{"name":"Ada","birthYear":1975},{"name":"Ben","birthYear":1977}],
         "taxableUsd":500000,"traditionalUsd":800000,"rothUsd":90000}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(IntakeModel.self, from: legacy)
        XCTAssertEqual(m.adults[0].traditionalUsd, 800_000, accuracy: 1)
        XCTAssertEqual(m.adults[1].traditionalUsd, 0, accuracy: 1, "the old shape had no spouse balance to find")
        XCTAssertEqual(m.traditionalUsd, 800_000, accuracy: 1)
        XCTAssertEqual(m.rothUsd, 90_000, accuracy: 1)
    }

    /// And a plan saved under the NEW shape must not be flattened back onto one person.
    func testAPerAdultSplitSurvivesAReload() throws {
        let m = couple(traditional: (600_000, 400_000), roth: (100_000, 50_000))
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(IntakeModel.self, from: data)
        XCTAssertEqual(back.adults[0].traditionalUsd, 600_000, accuracy: 1)
        XCTAssertEqual(back.adults[1].traditionalUsd, 400_000, accuracy: 1,
                       "the spouse's balance was flattened onto the primary on reload")
        XCTAssertEqual(back.adults[1].rothUsd, 50_000, accuracy: 1)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("\"traditionalUsd\":1000000"),
                       "the household total must not be re-emitted as a stored key — it is a computed shim")
    }

    /// The migration must yield to per-adult values when BOTH are present. A round trip
    /// never produces that file today, because the totals are computed and so are not
    /// re-emitted — which is exactly why the guard needs a hand-built fixture rather than an
    /// encode/decode cycle. Without it, any future change that re-emits the legacy key would
    /// silently flatten every couple's split onto the primary on load.
    func testPerAdultValuesWinOverALegacyTotalWhenBothArePresent() throws {
        let mixed = """
        {"adults":[{"name":"Ada","birthYear":1975,"traditionalUsd":600000,"rothUsd":100000},
                   {"name":"Ben","birthYear":1977,"traditionalUsd":400000,"rothUsd":50000}],
         "taxableUsd":500000,"traditionalUsd":1000000,"rothUsd":150000}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(IntakeModel.self, from: mixed)
        XCTAssertEqual(m.adults[0].traditionalUsd, 600_000, accuracy: 1)
        XCTAssertEqual(m.adults[1].traditionalUsd, 400_000, accuracy: 1,
                       "the legacy household total overwrote the per-adult split")
        XCTAssertEqual(m.adults[1].rothUsd, 50_000, accuracy: 1)
        XCTAssertEqual(m.traditionalUsd, 1_000_000, accuracy: 1, "and the total still reads correctly")
    }
}
