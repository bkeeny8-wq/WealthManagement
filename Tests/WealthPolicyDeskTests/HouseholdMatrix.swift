import Foundation
@testable import WealthPolicyDesk

/// A deliberately adversarial set of households, spanning the axes where this codebase's
/// defects actually live.
///
/// Four adversarial verification rounds found 9, 10, 10 and 10 high-severity defects, and
/// almost every one was a MIRROR case — the opposite direction of a case a fix had just
/// handled. They kept reaching production because the hand-written fixtures were uniform in
/// exactly the ways that mattered: single filers where couples behave differently, mid-range
/// ages where the boundaries are the interesting part, values that fit where exceeding is
/// the untested half.
///
/// Concretely, these all shipped green: a fixture with one adult could not exercise a
/// death-year floor the single-filer code path never consults; every spousal test was built
/// at age 62, so a claim already in the PAST was never evaluated; every conservation test
/// itemized LESS than the stated balance; and none had an adult past their own longevity
/// estimate or past their required beginning date.
///
/// So the axes below are chosen to be hostile rather than representative. Any household here
/// is a legal intake — every value is reachable from the form's own wheels and fields.
enum HouseholdMatrix {

    struct Case {
        let name: String
        let intake: IntakeModel
        /// Present only where the case is deliberately self-contradictory (itemised holdings
        /// exceeding a stated balance), so invariants can expect the documented behaviour
        /// rather than silently accepting either.
        let isOverItemised: Bool
    }

    private static func adult(_ name: String, born: Int, retireAt: Int, salary: Usd,
                              traditional: Usd = 0, roth: Usd = 0,
                              ssMonthly: Usd = 0, claimAt: Int = 0,
                              health: HealthStatus = .good) -> IntakeAdult {
        var a = IntakeAdult()
        a.name = name; a.birthYear = born; a.retirementAge = retireAt; a.salaryUsd = salary
        a.traditionalUsd = traditional; a.rothUsd = roth
        a.socialSecurityMonthlyUsd = ssMonthly; a.ssClaimAge = claimAt; a.health = health
        return a
    }

    private static func held(_ ticker: String, _ usd: Usd, _ treatment: AccountTaxTreatment,
                             owner: Int) -> IntakeHeldPosition {
        var h = IntakeHeldPosition()
        h.ticker = ticker; h.marketValueUsd = usd; h.costBasisUsd = usd * 0.6
        h.treatment = treatment; h.ownerIndex = owner
        return h
    }

    private static func base(_ adults: [IntakeAdult], taxable: Usd = 600_000,
                             spending: Usd = 120_000, planTo: Int = 92) -> IntakeModel {
        var m = IntakeModel()
        m.adults = adults
        m.taxableUsd = taxable
        m.retirementSpendingUsd = spending
        m.planToAge = planTo
        m.state = "NJ"
        m.protectionReviewed = true
        return m
    }

    /// `Engine.planningAsOf` is 2026-08-11, so a birth year of 2026 − n makes someone n.
    private static var planYear: Int { Engine.year(Engine.planningAsOf) }
    private static func bornAged(_ age: Int) -> Int { planYear - age }

    static let cases: [Case] = {
        var out: [Case] = []
        func add(_ name: String, _ m: IntakeModel, overItemised: Bool = false) {
            out.append(Case(name: name, intake: m, isOverItemised: overItemised))
        }

        // ── Household shape ────────────────────────────────────────────────────────────
        // A single filer and a couple take genuinely different code paths — survivor
        // economics exist only for the second. Three adults is legal input and was the shape
        // that exposed a spousal top-up being handed to every extra profile.
        add("single, mid-career",
            base([adult("Solo", born: bornAged(45), retireAt: 65, salary: 180_000,
                        traditional: 400_000, roth: 80_000, ssMonthly: 2_800, claimAt: 67)]))
        add("couple, both working",
            base([adult("A", born: bornAged(52), retireAt: 65, salary: 220_000, traditional: 500_000, ssMonthly: 3_400, claimAt: 67),
                  adult("B", born: bornAged(49), retireAt: 65, salary: 140_000, traditional: 300_000, ssMonthly: 2_100, claimAt: 67)]))
        add("three adults",
            base([adult("A", born: bornAged(60), retireAt: 65, salary: 200_000, traditional: 500_000, ssMonthly: 3_500, claimAt: 67),
                  adult("B", born: bornAged(58), retireAt: 65, salary: 60_000, traditional: 200_000, ssMonthly: 900, claimAt: 67),
                  adult("C", born: bornAged(55), retireAt: 65, salary: 40_000, traditional: 100_000, ssMonthly: 700, claimAt: 67)]))

        // ── Age boundaries ─────────────────────────────────────────────────────────────
        // Past the required beginning date; past a longevity estimate; a wide age gap, which
        // is where per-owner RMD schedules and survivor step-downs diverge.
        add("both past their required beginning date",
            base([adult("A", born: bornAged(78), retireAt: 62, salary: 0, traditional: 900_000, ssMonthly: 3_900, claimAt: 67),
                  adult("B", born: bornAged(76), retireAt: 62, salary: 0, traditional: 600_000, ssMonthly: 2_400, claimAt: 67)],
                 spending: 90_000, planTo: 95))
        add("one past their own longevity estimate",
            base([adult("A", born: bornAged(85), retireAt: 62, salary: 0, traditional: 400_000,
                        ssMonthly: 3_000, claimAt: 62, health: .poor),
                  adult("B", born: bornAged(74), retireAt: 62, salary: 0, traditional: 300_000, ssMonthly: 2_000, claimAt: 67)],
                 spending: 80_000, planTo: 95))
        add("single filer past their own longevity estimate",
            base([adult("Solo", born: bornAged(86), retireAt: 62, salary: 0, traditional: 300_000,
                        ssMonthly: 3_000, claimAt: 62, health: .poor)],
                 taxable: 400_000, spending: 70_000, planTo: 95))
        add("twenty-five year age gap",
            base([adult("A", born: bornAged(74), retireAt: 62, salary: 0, traditional: 800_000, ssMonthly: 4_000, claimAt: 70),
                  adult("B", born: bornAged(49), retireAt: 67, salary: 160_000, traditional: 200_000, ssMonthly: 2_600, claimAt: 62)],
                 spending: 150_000, planTo: 95))

        // ── Claiming ages, including claims already in the past ────────────────────────
        // Every spousal fixture used to be built at 62, so a claim behind the plan date — a
        // negative plan-year index — was never evaluated.
        add("both claimed years ago",
            base([adult("A", born: bornAged(76), retireAt: 62, salary: 0, traditional: 500_000, ssMonthly: 4_000, claimAt: 62),
                  adult("B", born: bornAged(76), retireAt: 62, salary: 0, traditional: 300_000, ssMonthly: 500, claimAt: 62)],
                 spending: 100_000, planTo: 95))
        add("worker delays to 70, spouse claims at 62",
            base([adult("A", born: bornAged(61), retireAt: 65, salary: 250_000, traditional: 700_000, ssMonthly: 4_200, claimAt: 70),
                  adult("B", born: bornAged(61), retireAt: 65, salary: 30_000, traditional: 100_000, ssMonthly: 600, claimAt: 62)]))
        add("no Social Security entered at all",
            base([adult("A", born: bornAged(50), retireAt: 65, salary: 200_000, traditional: 400_000),
                  adult("B", born: bornAged(48), retireAt: 65, salary: 120_000, traditional: 200_000)]))

        // ── Balance distribution ───────────────────────────────────────────────────────
        // A blank balance on one side is the shape that let a holding be relocated into the
        // other adult's account.
        add("all retirement money on one side",
            base([adult("A", born: bornAged(58), retireAt: 65, salary: 200_000, traditional: 1_000_000, ssMonthly: 3_400, claimAt: 67),
                  adult("B", born: bornAged(56), retireAt: 65, salary: 90_000, traditional: 0, ssMonthly: 1_800, claimAt: 67)]))
        add("lopsided split",
            base([adult("A", born: bornAged(58), retireAt: 65, salary: 200_000, traditional: 100_000, ssMonthly: 3_400, claimAt: 67),
                  adult("B", born: bornAged(56), retireAt: 65, salary: 90_000, traditional: 900_000, ssMonthly: 1_800, claimAt: 67)]))
        add("no portfolio at all",
            base([adult("A", born: bornAged(35), retireAt: 65, salary: 90_000)], taxable: 0, spending: 60_000))
        add("taxable only",
            base([adult("A", born: bornAged(45), retireAt: 65, salary: 150_000)], taxable: 800_000))

        // ── Itemised held-away holdings ────────────────────────────────────────────────
        // Fitting, exactly equal, exceeding, filed to a blank-balance owner, out of range.
        var fits = base([adult("A", born: bornAged(58), retireAt: 65, salary: 200_000, traditional: 600_000, ssMonthly: 3_400, claimAt: 67),
                         adult("B", born: bornAged(56), retireAt: 65, salary: 120_000, traditional: 400_000, ssMonthly: 2_200, claimAt: 67)])
        fits.heldAwayPositions = [held("AAPL", 150_000, .taxDeferred, owner: 0)]
        add("holding fits inside its owner's balance", fits)

        var exact = fits
        exact.heldAwayPositions = [held("AAPL", 600_000, .taxDeferred, owner: 0)]
        add("holding exactly equals its owner's balance", exact)

        var exceeds = fits
        exceeds.heldAwayPositions = [held("AAPL", 750_000, .taxDeferred, owner: 0)]
        add("holding exceeds its owner's balance", exceeds, overItemised: true)

        var blankOwner = base([adult("A", born: bornAged(58), retireAt: 65, salary: 200_000, traditional: 1_000_000, ssMonthly: 3_400, claimAt: 67),
                               adult("B", born: bornAged(76), retireAt: 62, salary: 0, traditional: 0, ssMonthly: 2_000, claimAt: 67)])
        blankOwner.heldAwayPositions = [held("MSFT", 400_000, .taxDeferred, owner: 1)]
        add("rollover filed to an owner who stated no balance", blankOwner, overItemised: true)

        var outOfRange = fits
        outOfRange.heldAwayPositions = [held("AAPL", 200_000, .taxDeferred, owner: 7)]
        add("holding names an owner index off the roster", outOfRange)

        var bothSides = fits
        bothSides.heldAwayPositions = [held("AAPL", 200_000, .taxDeferred, owner: 0),
                                       held("MSFT", 250_000, .taxDeferred, owner: 1),
                                       held("VTI", 180_000, .taxable, owner: 0)]
        add("holdings in both owners' accounts and taxable", bothSides)

        var taxableOver = fits
        taxableOver.taxableUsd = 100_000
        taxableOver.heldAwayPositions = [held("VTI", 400_000, .taxable, owner: 0)]
        add("taxable holdings exceed the taxable balance", taxableOver, overItemised: true)

        // ── Plan shape ─────────────────────────────────────────────────────────────────
        add("spending far beyond the portfolio",
            base([adult("A", born: bornAged(41), retireAt: 65, salary: 150_000)],
                 taxable: 25_000, spending: 200_000))
        add("portfolio far beyond the spending",
            base([adult("A", born: bornAged(58), retireAt: 62, salary: 0, traditional: 2_000_000,
                        ssMonthly: 4_000, claimAt: 67)],
                 taxable: 3_000_000, spending: 60_000))
        // A deferred balance large enough to SURVIVE to the required beginning date and
        // through the conversion window. Without one, no household in the matrix ever reaches
        // the boundaries that the RMD age and the conversion window are about — every balance
        // drains first, so the interesting years are never evaluated.
        add("deferred balance that survives to the RMD boundary",
            base([adult("A", born: bornAged(63), retireAt: 65, salary: 180_000,
                        traditional: 6_000_000, roth: 200_000, ssMonthly: 3_800, claimAt: 70)],
                 taxable: 1_500_000, spending: 140_000, planTo: 95))
        add("couple, both balances survive to their own boundaries",
            base([adult("A", born: bornAged(64), retireAt: 65, salary: 150_000,
                        traditional: 4_000_000, ssMonthly: 4_000, claimAt: 70),
                  adult("B", born: bornAged(72), retireAt: 62, salary: 0,
                        traditional: 3_000_000, ssMonthly: 2_800, claimAt: 67)],
                 taxable: 1_000_000, spending: 160_000, planTo: 95))

        // An accumulator carrying a NEAR-TERM non-spending outflow. Without one, every
        // household's first outflow of ANY kind IS its first retirement draw, so the
        // sequence anchor cannot be told apart from "the first year with any net outflow"
        // — a replay of that defect passed the whole resilience suite.
        add("accumulator funding a reserve years before it retires",
            { var m = base([adult("A", born: bornAged(51), retireAt: 65, salary: 400_000)],
                           taxable: 5_000_000, spending: 260_000)
              m.annualSavingsUsd = 120_000
              m.emergencyReserveUsd = 300_000
              return m }())

        add("already retired, drawing today",
            base([adult("A", born: bornAged(70), retireAt: 62, salary: 0, traditional: 800_000, ssMonthly: 3_600, claimAt: 67),
                  adult("B", born: bornAged(68), retireAt: 62, salary: 0, traditional: 400_000, ssMonthly: 2_400, claimAt: 67)],
                 spending: 110_000, planTo: 95))

        return out
    }()

    /// Every case, built. Evaluated once and cached — `Engine.evaluate` is ~70ms and the
    /// invariant suite reads each household many times.
    static let built: [(name: String, intake: IntakeModel, household: Household, isOverItemised: Bool)] = {
        cases.map { ($0.name, $0.intake, $0.intake.buildHousehold(), $0.isOverItemised) }
    }()

    static let evaluated: [(name: String, intake: IntakeModel, eval: Evaluation, isOverItemised: Bool)] = {
        built.map { ($0.name, $0.intake, Engine.evaluate($0.household), $0.isOverItemised) }
    }()
}
