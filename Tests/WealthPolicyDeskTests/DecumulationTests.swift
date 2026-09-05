import XCTest
@testable import WealthPolicyDesk

/// The after-tax decumulation projection + the Roth-conversion optimizer — the most
/// intricate engine, feeding the two-pass after-tax required return. No hand-computed
/// goldens (the schedule is long and will move); these lock the structural invariants a
/// silent break would violate while still returning a plausible number.
final class DecumulationTests: XCTestCase {

    private let asOf: IsoDate = "2026-08-11"
    private let tax = Seed.tax2026
    private var h: Household { Seed.sampleHousehold }
    private var rr: RequiredReturn { Engine.requiredReturn(h, asOf: asOf) }

    private func plan(conversionTo target: Bps? = nil) -> DecumulationPlan {
        Engine.decumulation(h, tax: tax, rr: rr, asOf: asOf, conversionToBracketTopBps: target, debitTax: true)
    }

    /// This household's own RMD age, which is what the projection gates on. `tax.rmdStartAge`
    /// is the seeded FALLBACK (73) and is two years early for a 1960-or-later primary —
    /// asserting against it both understates the RMD age and rejects legal conversions.
    private var rmdAge: Int {
        Engine.rmdStartAge(birthDate: h.primary!.birthDate, default: tax.rmdStartAge)
    }

    /// The sample's deferred balance drains before RMDs ever begin, so it cannot exercise
    /// the boundary at all. This variant reaches ages 73–75 with the account still funded.
    private func deepDeferredPlan(conversionTo target: Bps? = nil) -> DecumulationPlan {
        var big = h
        big.positions = big.positions.map { p in
            guard big.treatment(of: p) == .taxDeferred else { return p }
            var q = p; q.marketValueUsd *= 20; q.costBasisUsd *= 20; return q
        }
        return Engine.decumulation(big, tax: tax, rr: Engine.requiredReturn(big, asOf: asOf), asOf: asOf,
                                   conversionToBracketTopBps: target, debitTax: true)
    }

    // MARK: - Bucket conservation

    func testNoAccountBucketGoesNegative() {
        for p in [plan(), plan(conversionTo: 2400)] {
            XCTAssertFalse(p.years.isEmpty)
            for y in p.years {
                XCTAssertGreaterThanOrEqual(y.endTaxableUsd, -0.5, "taxable negative at age \(y.age)")
                XCTAssertGreaterThanOrEqual(y.endDeferredUsd, -0.5, "deferred negative at age \(y.age)")
                XCTAssertGreaterThanOrEqual(y.endRothUsd, -0.5, "roth negative at age \(y.age)")
            }
        }
    }

    // MARK: - RMDs

    func testRmdsBeginAtTheStatutoryAgeAndMatchFirstRmdAge() {
        let p = plan()
        let firstRmdYear = p.years.first { $0.rmdUsd > 0 }
        if let f = firstRmdYear {
            XCTAssertGreaterThanOrEqual(f.age, rmdAge, "an RMD before this client's statutory age")
            XCTAssertEqual(p.firstRmdAge, f.age, "firstRmdAge must name the first RMD year")
        } else {
            XCTAssertEqual(p.firstRmdAge, 0, "no RMD year ⇒ firstRmdAge is 0")
        }
    }

    // MARK: - Roth conversions

    func testBaselineNeverConverts() {
        for y in plan().years {
            XCTAssertEqual(y.rothConversionUsd, 0, accuracy: 0.5, "the baseline path has no conversions")
        }
    }

    func testConversionsHappenOnlyInThePreRmdWindow() {
        for y in plan(conversionTo: 2400).years where y.rothConversionUsd > 0.5 {
            XCTAssertLessThan(y.age, rmdAge, "a conversion after RMDs begin")
        }
    }

    /// The boundary the sample cannot reach. Its deferred balance drains by the late
    /// sixties, so reverting the conversion gate to the seeded fallback age left the whole
    /// suite green — this fixture keeps the account funded through the real boundary.
    func testTheConversionWindowExtendsToTheClientsOwnRmdAge() {
        XCTAssertEqual(rmdAge, 75, "fixture check: the sample's primary was born in 1963")
        let ages = deepDeferredPlan(conversionTo: 2400).years
            .filter { $0.rothConversionUsd > 0.5 }.map(\.age)
        guard let last = ages.max() else { return XCTFail("fixture check: expected conversions") }
        XCTAssertEqual(last, rmdAge - 1, "the two highest-value conversion years, 73 and 74, must be usable")
        XCTAssertGreaterThan(last, tax.rmdStartAge - 1,
                             "gating on the seeded fallback would stop converting at 72")
    }

    /// And RMDs must actually begin at 75 in that fixture — the other half of the same
    /// boundary, which no test reached while the account drained early.
    func testRmdsBeginAtTheClientsOwnAgeWhenTheAccountSurvivesToReachThem() {
        let p = deepDeferredPlan()
        XCTAssertEqual(p.firstRmdAge, rmdAge, "a 1963-born primary's first RMD is at 75, not 73")
    }

    // MARK: - The optimizer

    func testRothStrategyPicksNoWorseThanBaselineAndReportsConsistently() {
        let s = Engine.rothStrategy(h, tax: tax, rr: rr, asOf: asOf)
        XCTAssertGreaterThan(s.baseline.lifetimeFederalTaxUsd, 0)
        // The recommended plan can never cost more lifetime tax than doing nothing …
        XCTAssertLessThanOrEqual(s.plan.lifetimeFederalTaxUsd, s.baseline.lifetimeFederalTaxUsd + 0.5)
        // … and the reported saving is exactly that gap, floored at zero.
        XCTAssertEqual(s.lifetimeTaxSavedUsd,
                       max(0, s.baseline.lifetimeFederalTaxUsd - s.plan.lifetimeFederalTaxUsd), accuracy: 0.5)
        // If it recommends converting, the summary must be self-consistent.
        if s.targetBracketBps > 0 {
            XCTAssertGreaterThan(s.conversionYears, 0)
            XCTAssertGreaterThan(s.avgAnnualConversionUsd, 0)
        } else {
            XCTAssertEqual(s.conversionYears, 0)
        }
    }

    func testRothStrategyIsDeterministic() {
        let a = Engine.rothStrategy(h, tax: tax, rr: rr, asOf: asOf)
        let b = Engine.rothStrategy(h, tax: tax, rr: rr, asOf: asOf)
        XCTAssertEqual(a.lifetimeTaxSavedUsd, b.lifetimeTaxSavedUsd, accuracy: 0.0001)
        XCTAssertEqual(a.plan.lifetimeFederalTaxUsd, b.plan.lifetimeFederalTaxUsd, accuracy: 0.0001)
    }

    // MARK: - The couples survivor step-down reaches the projection

    func testSurvivorStepDownLowersLateRetirementSpendingInTheProjection() {
        let base = plan()                                              // joint schedule
        let stepped = Engine.decumulation(h.withSurvivorSpending(asOf: asOf),
                                          tax: tax, rr: rr, asOf: asOf, debitTax: true)
        XCTAssertEqual(base.years.count, stepped.years.count)
        guard let jointLast = base.years.last, let survivorLast = stepped.years.last else {
            return XCTFail("both projections must run the full horizon")
        }
        XCTAssertLessThan(survivorLast.spendingNeedUsd, jointLast.spendingNeedUsd,
                          "after the first death the survivor's spending need must be lower")
    }
}
