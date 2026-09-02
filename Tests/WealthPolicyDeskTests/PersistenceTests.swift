import XCTest
@testable import WealthPolicyDesk

/// Codable round-trip guards for the seven hand-written decoders that persist the client
/// book (wealth-policy-book.json). Each type has a forward-compatible `init(from:)` that
/// starts from defaults and decodes only the keys it lists — so a NEW stored field that is
/// encoded but forgotten in that list is "write-only": it saves and then silently reverts
/// to its default on reload (the exact bug that shipped once via IntakeModel.taxableTitling).
///
/// The guard: build a FULLY-POPULATED instance (every field a non-default), encode, decode,
/// and assert equality. A dropped field reverts to its default and fails the assertion.
final class PersistenceTests: XCTestCase {

    /// encode → decode → must equal. Fails if any stored field isn't faithfully persisted.
    private func assertRoundTrips<T: Codable & Equatable>(_ x: T, _ label: String, file: StaticString = #file, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(x)
        let back = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(back, x, "\(label): a field is encoded but not decoded (write-only) — add its decodeIfPresent line", file: file, line: line)
    }

    /// A valid non-default case for any CaseIterable enum — no need to name each case.
    private func other<T: CaseIterable & Equatable>(_ v: T) -> T { T.allCases.first { $0 != v } ?? v }

    private let d1 = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private let d2 = Date(timeIntervalSinceReferenceDate: 712_345_678)
    private func uuid(_ n: Int) -> UUID { UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")! }

    // MARK: - Fixtures (every field non-default)

    private func populatedOverrides() -> HouseholdOverrides {
        var o = HouseholdOverrides()
        o.legacyFloorUsd = 1_000_000; o.toleranceMaxDrawdownBps = 3000; o.annualSavingsUsd = 55_000
        o.retirementAge = 66; o.spouseRetirementAge = 64
        o.addedGoals = [GoalEdit(id: "ov_home", label: "Home", annualUsd: 500_000, startYear: 3, years: 1)]
        o.goalAmountOverrides = ["g_spending": 210_000]
        o.goalTimingOverrides = ["ov_home": GoalTiming(startYear: 4, years: 2)]
        o.removedGoalIds = ["ov_travel"]
        o.usEquityStyle = USEquityStyleTilt(large: .growth, mid: .value, small: .blend)   // non-nil ⇒ teeth for the write
        return o
    }

    private func populatedReview() -> IPSReview {
        IPSReview(id: "review-1", createdAt: d1, note: "what changed this year",
                  confirmedSections: ["return", "risk", "allocation"],
                  requiredRealReturnBps: 456, fundedRatioBps: 6313, equityCeilingBps: 6000,
                  afterTaxNetWorthUsd: 2_893_928, goalCount: 3, overrides: populatedOverrides())
    }

    private func populatedTilt() -> TacticalTiltAction {
        // status: .staged, NOT the decoder's ?? .committed fallback — so a dropped status key is caught.
        TacticalTiltAction(id: uuid(1), createdAt: d1, sleeveId: "us_sector_tilt", deviationBps: 300,
                           sourceName: "Energy", thesis: "real-asset convexity", reviewDate: d2, status: .staged)
    }

    private func populatedAction() -> PlannedAction {
        PlannedAction(id: uuid(2), createdAt: d1, sellAccountId: "acct_taxable", sellTicker: "XLK",
                      sellUsd: 120_000, buyTicker: "XLP", buySleeveId: "us_sector_tilt", buySectorRaw: "consumer_staples",
                      thesis: "rotate defensive", reviewDate: d2, status: .staged)   // .staged ≠ decoder fallback .committed
    }

    private func populatedPractice() -> PracticeMetadata {
        var p = PracticeMetadata()
        p.id = uuid(3); p.advisorName = "Advisor Name"; p.clientName = "Client Name"
        p.contactEmail = "client@example.com"; p.contactPhone = "555-0100"
        p.stage = other(p.stage); p.leadSource = other(p.leadSource); p.leadSourceDetail = "the Okafors"
        p.nextAction = "confirm rollover"; p.notes = "prefers email"; p.createdAt = d1; p.updatedAt = d2
        return p
    }

    private func populatedAdult() -> IntakeAdult {
        var a = IntakeAdult()
        a.id = uuid(4); a.name = "Robert Test"; a.birthYear = 1968; a.retirementAge = 66; a.health = other(a.health)
        a.salaryUsd = 250_000; a.bonusUsd = 40_000; a.bonusStability = other(a.bonusStability)
        a.incomeCharacter = other(a.incomeCharacter); a.sector = .energy
        a.employerStockUsd = 80_000; a.deferredCashUsd = 25_000
        return a
    }

    private func populatedHeldPosition() -> IntakeHeldPosition {
        var h = IntakeHeldPosition()
        h.id = uuid(5); h.ticker = "AAPL"; h.marketValueUsd = 300_000; h.costBasisUsd = 90_000
        h.treatment = other(h.treatment); h.plan = other(h.plan); h.unwindYears = 5
        h.isConcentrated = true; h.acquisitionDate = "2019-03-15"
        return h
    }

    private func populatedIntake() -> IntakeModel {
        var m = IntakeModel()
        // 1 household
        m.adults = [populatedAdult()]; m.childrenBirthYears = [2012]; m.filingStatus = other(m.filingStatus)
        m.state = "NJ"; m.survivableOnOneIncome = false
        // 3 savings & reserve
        m.annualSavingsUsd = 80_000; m.emergencyReserveUsd = 75_000
        // 4 accounts & holdings
        m.taxableUsd = 900_000; m.traditionalUsd = 600_000; m.rothUsd = 120_000
        m.taxableTitling = .communityProperty; m.taxableUnrealizedGainPct = 0.42; m.currentEquityPct = 0.7
        // 5 real estate & debts. ownsHome = false while home > 0 is deliberate teeth: the
        // decoder derives ownsHome from home>0 when the key is absent, so only a real
        // round-trip of the stored bool can reproduce false here.
        m.ownsHome = false
        m.homeValueUsd = 1_200_000; m.mortgageBalanceUsd = 400_000; m.mortgageRateBps = 625
        m.mortgageFixed = false; m.helocUsd = 50_000; m.otherDebtUsd = 30_000; m.otherDebtRateBps = 900
        // 6 external income
        m.pensionAnnualUsd = 24_000; m.ssClaimAge = 70
        // 7 goals
        m.retirementSpendingUsd = 220_000; m.retirementStartAge = 66; m.planToAge = 95; m.legacyFloorUsd = 1_000_000
        // 8 personality / risk
        m.lossToleranceBps = 3000; m.pastBehavior = other(m.pastBehavior); m.forwardLossReaction = other(m.forwardLossReaction)
        m.worry = other(m.worry); m.legacyPriority = other(m.legacyPriority)
        m.spendingFlexibility = other(m.spendingFlexibility); m.complexityAppetite = other(m.complexityAppetite)
        // 9 held-away & transition
        m.heldAwayPositions = [populatedHeldPosition()]; m.annualGainBudgetUsd = 60_000
        m.transitionTargetYears = 5; m.permanentHoldPolicy = other(m.permanentHoldPolicy)
        // 10-11 additional goals / dependents. children MUST stay non-empty, or the decoder's
        // childrenBirthYears→children legacy migration synthesizes a child and false-fails the
        // round-trip. (These three types use synthesized Codable — no write-only risk inside them.)
        m.additionalGoals = [IntakeGoal()]; m.children = [IntakeChild()]; m.educationGoals = [IntakeEducationGoal()]
        // 12 estate & giving
        m.heirCount = 2; m.expectedHeirBracket = other(m.expectedHeirBracket); m.annualGivingUsd = 15_000
        m.qcdEligible = true; m.qcdPlannedUsd = 10_000; m.dafExists = true; m.dafBalanceUsd = 200_000
        m.charitableBequestSource = other(m.charitableBequestSource)
        m.hasWill = true; m.hasRevocableTrust = true; m.hasFinancialPOA = true
        m.hasHealthcareDirective = true; m.beneficiaryDesignationsCurrent = true
        // 13 protection
        m.disabilityGroupMonthlyUsd = 5_000; m.disabilityIndividualMonthlyUsd = 3_000
        m.disabilityBenefitsTaxable = false; m.disabilityOwnOccupation = true; m.disabilityCoversBonus = true
        m.lifeInForceUsd = 2_000_000; m.lifeKind = other(m.lifeKind); m.lifeInIrrevocableTrust = true
        m.ltcApproach = other(m.ltcApproach); m.ltcDedicatedReserveUsd = 150_000
        m.ltcEstimatedAnnualCostUsd = 120_000; m.ltcEstimatedDurationYears = 4; m.umbrellaLimitUsd = 3_000_000
        // 14 equity comp
        m.equityGrantTypes = [.rsu]; m.isCompanyInsider = true; m.tradingWindow = other(m.tradingWindow)
        m.has10b51Plan = true; m.isoUnexercisedValueUsd = 400_000; m.planningIsoExerciseAndHold = true
        m.isoBargainElementUsd = 220_000; m.pending83bGrantDate = "2025-06-01"
        m.esppAnnualContributionUsd = 25_000; m.esppDiscountBps = 1200; m.esppLookback = false   // 1200 ≠ default 1500
        m.qsbsStatus = other(m.qsbsStatus)
        return m
    }

    private func populatedRecord() -> ClientRecord {
        var r = ClientRecord(id: uuid(6), intake: populatedIntake(), practice: populatedPractice())
        r.updatedAt = d2; r.archived = true
        r.actions = [populatedAction()]; r.tilts = [populatedTilt()]
        r.driverOverrides = populatedOverrides(); r.reviews = [populatedReview()]
        return r
    }

    // MARK: - Round-trip tests

    func testHouseholdOverridesRoundTrips() throws { try assertRoundTrips(populatedOverrides(), "HouseholdOverrides") }
    func testIPSReviewRoundTrips() throws { try assertRoundTrips(populatedReview(), "IPSReview") }
    func testTacticalTiltActionRoundTrips() throws { try assertRoundTrips(populatedTilt(), "TacticalTiltAction") }
    func testPlannedActionRoundTrips() throws { try assertRoundTrips(populatedAction(), "PlannedAction") }
    func testPracticeMetadataRoundTrips() throws { try assertRoundTrips(populatedPractice(), "PracticeMetadata") }
    func testIntakeModelRoundTrips() throws { try assertRoundTrips(populatedIntake(), "IntakeModel") }

    /// The whole persisted record — transitively re-locks every nested type as it is
    /// actually stored in wealth-policy-book.json.
    func testClientRecordRoundTrips() throws { try assertRoundTrips(populatedRecord(), "ClientRecord") }
}
