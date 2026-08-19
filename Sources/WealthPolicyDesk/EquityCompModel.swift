//  EquityCompModel.swift
//  WealthPolicyDesk
//
//  Decision-grade equity-comp + protection numbers — turning the qualitative "model
//  the crossover" / "verify QSBS" flags into figures a client can act on:
//   • ISO → AMT: the tax an exercise-and-hold actually triggers (cash due with NO
//     proceeds), and the crossover — the bargain element exercisable before AMT bites.
//   • §1202 QSBS: the exclusion cap and the federal tax it can erase.
//   • Protection: the present value of an unfunded disability-income gap.
//
//  Pure and deterministic. AMT parameters are dated 2026 estimates under OBBBA
//  (P.L. 119-21) — verify before use.

import Foundation

public struct IsoAmtResult: Sendable, Hashable {
    public var bargainElementUsd: Usd
    public var regularTaxableUsd: Usd
    public var amtiUsd: Usd
    public var amtExemptionUsd: Usd
    public var tentativeMinTaxUsd: Usd
    public var regularTaxUsd: Usd
    public var amtOwedUsd: Usd             // tentative minimum tax over regular tax — cash due, no shares sold
    public var crossoverBargainUsd: Usd    // bargain element exercisable this year before AMT starts
    public var effectiveAmtRateBps: Bps    // amtOwed ÷ bargain element
}

public struct QsbsExclusion: Sendable, Hashable {
    public var status: QsbsStatus
    public var perIssuerCapUsd: Usd        // the greater of $10M or 10× basis (10× not modelled → $10M shown)
    public var maxFederalTaxExcludedUsd: Usd  // cap × (LTCG + NIIT) — the ceiling on what §1202 can save
}

public extension Engine {
    // 2026 AMT parameters under OBBBA (P.L. 119-21) — dated estimates, VERIFY. OBBBA keeps
    // the higher exemption but reverts the phase-out: 50% (was 25%) starting ~$500k / $1M.
    static let amtExemptionUsd: [FilingStatus: Usd] = [.single: 88_100, .mfj: 137_000, .mfs: 68_500, .hoh: 88_100]
    static let amtPhaseoutStartUsd: [FilingStatus: Usd] = [.single: 500_000, .mfj: 1_000_000, .mfs: 500_000, .hoh: 500_000]
    static let amtExemptionPhaseoutRate = 0.50      // OBBBA 2026 (TCJA was 0.25)
    static let amt28ThresholdUsd: Usd = 232_600     // AMT base above this taxed at 28%, below at 26% (halved for MFS)

    /// The AMT an ISO exercise-and-hold triggers, and the AMT-free crossover bargain
    /// element. nil when no exercise-and-hold with a bargain element is planned.
    static func isoAmt(_ h: Household, asOf: IsoDate = planningAsOf) -> IsoAmtResult? {
        guard let ec = h.equityComp, ec.plannedExerciseAndHold, ec.isoBargainElementUsd > 0 else { return nil }
        let filing = h.filingStatus
        let tax = Seed.tax2026
        let bargain = ec.isoBargainElementUsd
        let (grossOrdinary, regularTaxable) = currentOrdinaryIncome(h, asOf: asOf, capGains: 0)
        let regularTax = progressiveTax(regularTaxable, brackets: tax.ordinaryBrackets[filing] ?? [])
        let threshold28 = filing == .mfs ? amt28ThresholdUsd / 2 : amt28ThresholdUsd

        // Tentative minimum tax on a given AMTI: exemption (phased out over the threshold),
        // then 26% to the 28%-bracket edge and 28% above.
        func tmt(_ amti: Usd) -> Usd {
            let exempt = max(0, (amtExemptionUsd[filing] ?? 88_100) - amtExemptionPhaseoutRate * max(0, amti - (amtPhaseoutStartUsd[filing] ?? 500_000)))
            let base = max(0, amti - exempt)
            return base <= threshold28 ? base * 0.26 : threshold28 * 0.26 + (base - threshold28) * 0.28
        }
        // AMT disallows the standard deduction, so AMTI is built from GROSS ordinary income
        // (this model always takes the standard deduction — there is no itemized path) plus
        // the ISO bargain-element preference.
        let amti = grossOrdinary + bargain
        let TMT = tmt(amti)
        let amtOwed = max(0, TMT - regularTax)

        // Crossover: the largest bargain element whose TMT still doesn't exceed regular tax.
        var crossover: Usd = 0
        if tmt(grossOrdinary) < regularTax {
            var lo = 0.0, hi = 1.0
            while tmt(grossOrdinary + hi) < regularTax && hi < 50_000_000 { hi *= 2 }
            for _ in 0..<48 { let mid = (lo + hi) / 2; if tmt(grossOrdinary + mid) < regularTax { lo = mid } else { hi = mid } }
            crossover = lo
        }
        let exemptFinal = max(0, (amtExemptionUsd[filing] ?? 88_100) - amtExemptionPhaseoutRate * max(0, amti - (amtPhaseoutStartUsd[filing] ?? 500_000)))
        return IsoAmtResult(bargainElementUsd: bargain, regularTaxableUsd: regularTaxable, amtiUsd: amti,
            amtExemptionUsd: exemptFinal, tentativeMinTaxUsd: TMT, regularTaxUsd: regularTax, amtOwedUsd: amtOwed,
            crossoverBargainUsd: crossover, effectiveAmtRateBps: bargain > 0 ? (amtOwed / bargain).bps : 0)
    }

    /// The §1202 QSBS exclusion ceiling. nil when no QSBS is flagged.
    static func qsbsExclusion(_ h: Household) -> QsbsExclusion? {
        guard let ec = h.equityComp, ec.qsbs != .none else { return nil }
        let cap: Usd = 10_000_000                                   // greater of $10M or 10× basis; 10× not modelled
        let rate = (2000 + Seed.tax2026.niitRateBps).frac          // a $10M gain sits in the top 20% LTCG bracket + NIIT
        return QsbsExclusion(status: ec.qsbs, perIssuerCapUsd: cap, maxFederalTaxExcludedUsd: cap * rate)
    }

    /// Present value of the unfunded disability-income gap over the primary's working
    /// years, discounted at the safe real rate — the lump the gap is really worth.
    static func disabilityGapPv(_ h: Household, asOf: IsoDate = planningAsOf) -> Usd {
        guard let p = h.protection, p.disabilityGapMonthlyUsd > 0, let primary = h.primary else { return 0 }
        let years = max(0, primary.expectedRetirementAge - age(birthDate: primary.birthDate, asOf: asOf))
        guard years > 0 else { return 0 }
        let annual = p.disabilityGapMonthlyUsd * 12
        var pv: Usd = 0
        for t in 1...years { pv += annual / pow(1 + safeRealRate, Double(t)) }
        return pv
    }
}
