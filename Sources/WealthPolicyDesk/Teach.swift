//  Teach.swift
//  WealthPolicyDesk
//
//  The teaching layer. All explanatory copy lives here, apart from layout, so it
//  can be edited without touching view code. Rule followed throughout: copy
//  states MECHANISMS and BELIEFS, never a specific client's numbers — the app
//  supplies the live figures, so nothing here goes stale when the household
//  changes.

import Foundation

public struct BlockHelp: Sendable, Hashable {
    public let what: String
    public let moves: String
    public let watch: String
    public init(what: String, moves: String, watch: String) { self.what = what; self.moves = moves; self.watch = watch }
}

public struct Lesson: Identifiable, Sendable, Hashable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let goal: String
    public let steps: [String]
    public let takeaway: String
}

public struct GlossaryTerm: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public let name: String
    public let plain: String
    public let desk: String
}

public enum Teach {

    // MARK: - Block help by key

    public static func help(_ key: String) -> BlockHelp {
        switch key {
        case "balanceSheet":
            return BlockHelp(
                what: "The whole household on one page: portfolio, home, human capital, pensions and Social Security as assets; debt, deferred tax and projected estate tax as liabilities.",
                moves: "Three numbers reverse the conclusion a brokerage statement invites. After-tax net worth strips out the embedded tax a statement counts as yours. Net fixed income nets debt against bonds. Total balance-sheet equity counts your income's beta.",
                watch: "Watch the gap between gross and after-tax net worth — commonly 15–25% — and whether net fixed income is positive at all.")
        case "netFI":
            return BlockHelp(
                what: "Fixed income assets minus debt. A 30-year fixed mortgage is a large short bond position; a household can hold bonds and still be net short duration.",
                moves: "Every statement shows the bonds and omits the mortgage. Netting them is the correct, defensible version of ‘home equity is bond allocation’ — it lives on the liability side.",
                watch: "When this is negative, the household believes it holds a defensive allocation while running net short duration.")
        case "requiredReturn":
            return BlockHelp(
                what: "The real return the portfolio must earn to fund every claim to plan-end, given current assets, future savings, and external income (Social Security, pensions, home equity).",
                moves: "It is pure arithmetic — no capital-market forecast. Report it first; then let assumptions answer how plausible it is, rather than laundering everything into one success probability.",
                watch: "Compare it to the required return AFTER flexing goals. The drop is the value of deferring or scaling a goal — usually a stronger lever than taking more risk.")
        case "allocation":
            return BlockHelp(
                what: "Current sleeve weights against policy targets, with inner (flag) and outer (mandatory) rebalance bands.",
                moves: "The blended split is an OUTPUT of funding the claims, never a target. Bands are already counter-cyclical: they mechanically sell what rose and buy what fell.",
                watch: "Outer-band breaches are mandatory to correct; inner-band breaches are only flags. Locked and gated holdings sit outside the bands and the rest absorbs their drift.")
        case "alts":
            return BlockHelp(
                what: "Alternatives sized by FUNCTION — convexity, shaped payoff, illiquidity premium — not by product, and mapped to the cheapest wrapper the household's eligibility tier can actually access.",
                moves: "Illiquidity premium does not get to borrow the correlation argument: private credit is credit beta with smoothed marks and fails the same shock bonds fail. It earns its place on illiquidity premium alone.",
                watch: "If no eligible wrapper exists at this tier, the unfunded weight falls back to a named sleeve. Watch the fee against the function's budget — against 5bp bonds the hurdle is real.")
        case "constraints":
            return BlockHelp(
                what: "Every seeded hard/soft rule across all modules, evaluated against this household. Hard rules block; soft rules flag.",
                moves: "The value is as much in what does NOT fire as in what does. A rule that stays silent on a household that could trip it is the system working.",
                watch: "Hard violations first. Most are structural (step-up, liquidity, employer credit) and worth more over decades than any market call.")
        case "salt":
            return BlockHelp(
                what: "Whether the household itemizes, the SALT deduction after any phase-down, and the marginal value of the next dollar of mortgage interest.",
                moves: "In the current window a high-tax-state homeowner is SALT-capped on state and property tax alone, making mortgage interest fully incremental. Muni interest stays out of MAGI, dodging the phase-down band, IRMAA and NIIT.",
                watch: "Inside the phase-down band each extra dollar of income also erodes the deduction, so the effective marginal rate is higher than the bracket. Mind the 2030 SALT reversion.")
        case "disposition":
            return BlockHelp(
                what: "What happens to each taxable lot at death, and whether to hold it for the step-up or gift it during life.",
                moves: "Below the estate exemption you never gift an appreciated lot — the step-up erases the gain for free. Above it, gift high-basis lots and hold low-basis ones. Disposition at death inverts lifetime asset location: the charity should get the IRA, the heirs the brokerage account.",
                watch: "A taxable sale of a hold-to-step-up lot is a violation, not a budgeted cost — over decades it dwarfs any tilt.")
        case "tilts":
            return BlockHelp(
                what: "The tactical overlay: small, logged, thesis-bearing sector or geography tilts, scored against their funding leg — plus the layer budget that caps them.",
                moves: "This is the weakest-evidence component in the system, so it is budgeted accordingly: capped share, capped concurrent tilts, and a rolling cost budget. A country tilt is unavoidably also a sector tilt — cross-exposure is acknowledged at entry.",
                watch: "Every tilt needs a written thesis and a forced review date, or it becomes permanent by inertia. It is scored against the leg that funded it, not against zero.")
        case "ladder":
            return BlockHelp(
                what: "Years of net outflows pre-funded by a bond ladder. Length is an OUTPUT of the funded-liability gap — spending need less Social Security, pension and other income — not a risk-tolerance conversation.",
                moves: "A client needing income does not need coupons yielding that number; they need cash on known dates. Building the portfolio to YIELD the number rather than FUND it is how you reach for credit risk.",
                watch: "A separate liquid reserve exists purely for rebalancing ammunition. Daily-liquid assets must still cover the ladder, the reserve, and a year of outflows.")
        case "paydown":
            return BlockHelp(
                what: "Pay down debt or invest? Paying down debt is buying a bond yielding the after-tax debt rate, with zero credit and zero duration risk.",
                moves: "So the comparison is after-tax debt rate vs after-tax fixed-income yield, risk-matched — not mortgage rate vs expected equity return. In the SALT window a deductible mortgage's after-tax rate drops, weakening the paydown case.",
                watch: "Revocable lines (HELOC, SBLOC) are the exception: they disappear in exactly the drawdown you'd need them in, so retiring them buys real safety.")
        default:
            return BlockHelp(what: "", moves: "", watch: "")
        }
    }

    // MARK: - Guided lessons

    public static let lessons: [Lesson] = [
        Lesson(number: 1, title: "Allocation is an output",
               goal: "See why the household's blended stock/bond/alt split is never a target.",
               steps: ["Open Required Return — the plan's anchor is a return, computed with no market forecast.",
                       "Open Allocation — the sleeve weights that fund that return are what the split ‘looks like’.",
                       "Change a goal's amount and watch both move together."],
               takeaway: "You fund claims; the allocation is the residue. Nobody targets 60/40 — it falls out."),
        Lesson(number: 2, title: "The number no statement shows",
               goal: "Find net fixed income and after-tax net worth.",
               steps: ["Open Balance Sheet.", "Read Net Fixed Income — bonds minus the mortgage.",
                       "Compare gross to after-tax net worth — the embedded tax the statement counts as yours."],
               takeaway: "A mortgage is a short bond. Gross net worth overstates real wealth, often by 15–25%."),
        Lesson(number: 3, title: "Flexibility beats risk",
               goal: "Watch the required return fall when a goal flexes.",
               steps: ["Open Required Return.", "Read the required real return, then the one WITH flexibility.",
                       "The gap is what deferring or scaling a goal buys you — for free."],
               takeaway: "Deferring a goal beats taking more risk. Flexibility is the strongest lever on the board."),
        Lesson(number: 4, title: "Disposition inverts location",
               goal: "See why the charity should get the IRA.",
               steps: ["Open Disposition.", "Note taxable appreciated lots recommend hold-to-step-up.",
                       "Read the constraint: charitable bequests should be funded from IRD (the IRA), not taxable."],
               takeaway: "Death treatment drives lifetime holding. The heirs get the brokerage account; the charity gets the IRA."),
        Lesson(number: 5, title: "Alts are a function, not a product",
               goal: "See alts sized by job and mapped to a wrapper the household can access.",
               steps: ["Open Allocation → Alternatives.", "Each function resolves to the cheapest eligible wrapper at the tier.",
                       "Illiquidity premium is flagged as smoothed marks — modeled with a vol override."],
               takeaway: "Buy convexity, shaped payoff, illiquidity premium — never a label. The wrapper is downstream of the tier."),
        Lesson(number: 6, title: "The system stays silent, too",
               goal: "Appreciate the constraints that DON'T fire.",
               steps: ["Open Constraints.", "See the hard employer-credit flag.",
                       "Notice muni-in-a-sheltered-account and capital-call coverage stay quiet — the household passes them."],
               takeaway: "A rule that stays silent on a household that could trip it is the engine working, not idle."),
    ]

    // MARK: - Glossary (plain / desk registers)

    public static let glossary: [GlossaryTerm] = [
        GlossaryTerm(name: "Goal claim", plain: "A specific thing your money has to pay for — retirement spending, a legacy, an emergency reserve.", desk: "A dated liability against a perpetual corpus. Allocation emerges from funding the set of claims; it is never an input."),
        GlossaryTerm(name: "Required real return", plain: "The growth rate, above inflation, your money must earn to cover the plan.", desk: "The IRR that funds the net-liability stream to horizon. Computed without CMAs; reported before any plausibility overlay."),
        GlossaryTerm(name: "Net fixed income", plain: "Your bonds minus your debt.", desk: "FI assets less debt. A fixed mortgage is negative duration; a household can be net short despite a bond sleeve."),
        GlossaryTerm(name: "Step-up", plain: "Heirs inherit an asset at today's value, erasing the taxable gain.", desk: "Basis reset at death under §1014. A hold-to-step-up earmark makes a taxable sale a violation, not a budgeted cost."),
        GlossaryTerm(name: "IRD", plain: "Money that's still taxable after you die — like a traditional IRA.", desk: "Income in respect of a decedent. No step-up; the heir pays ordinary rates. Route it to charity, which pays none."),
        GlossaryTerm(name: "SALT phase-down", plain: "Above an income line, your state-and-local-tax deduction shrinks.", desk: "Each dollar over the threshold erodes the cap at a fixed rate, so the effective marginal rate in-band exceeds the bracket."),
        GlossaryTerm(name: "Illiquidity premium", plain: "Extra return for locking money up.", desk: "Compensation for giving up access — not a diversifier. Private credit is credit beta with smoothed marks."),
        GlossaryTerm(name: "Convexity", plain: "A payoff that grows fast in exactly the bad scenario.", desk: "Trend / commodities / gold — the alt function that works in the inflation shock where bonds fail."),
        GlossaryTerm(name: "Ladder", plain: "A row of bonds maturing in successive years to pay known bills.", desk: "Liability-matched FI whose length is the funded-liability gap, not a risk-tolerance output."),
        GlossaryTerm(name: "Glide", plain: "Slowly shifting toward safer assets as a goal approaches.", desk: "A ratcheting, valuation-modulated equity path with a hard deadline — spending claim only; the legacy claim never glides."),
    ]

    public static let disclosure = "A teaching and analysis tool. Nothing here is investment advice or a recommendation. Figures use editable, effective-dated assumptions that must be verified before any client use."
}
