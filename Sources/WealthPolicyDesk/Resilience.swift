//  Resilience.swift
//  WealthPolicyDesk
//
//  The required return is one number; this asks the questions it can't: how fragile
//  is the plan? Two stresses, no market forecasts — only observables:
//   • Return sensitivity — how far does the terminal balance move if the REALIZED
//     return misses the required return by ±1–2 points.
//   • Sequence-of-returns risk — the plan's OWN required return, delivered in a
//     historically bad ORDER (retire into 2000 / 2008 / the 1966 stagflation),
//     re-centered so only the pattern bites and scaled by the portfolio's equity
//     share. Same average, worse order — the retiree's signature risk.
//  And a max-safe-spend: the largest spending that survives the worst of those.

import Foundation

public struct ReturnSensitivity: Identifiable, Sendable, Hashable {
    public var realReturnBps: Bps
    public var terminalBalanceUsd: Usd
    public var depletionAge: Int?          // nil = lasts the whole horizon
    public var id: Bps { realReturnBps }
}

public struct SequenceStress: Identifiable, Sendable, Hashable {
    public var name: String
    public var detail: String
    public var survives: Bool               // never fully depletes
    public var meetsFloor: Bool             // ends at/above the legacy floor
    public var terminalBalanceUsd: Usd
    public var depletionAge: Int?
    public var id: String { name }
}

public struct ResilienceAnalysis: Sendable, Hashable {
    public var requiredRealReturnBps: Bps
    public var legacyFloorUsd: Usd
    public var sensitivities: [ReturnSensitivity]
    public var stresses: [SequenceStress]
    public var maxSafeSpendUsd: Usd
    public var currentSpendUsd: Usd
    public var spendHeadroomBps: Bps        // (maxSafe − current)/current, in bps (can be negative)
    public var stressesSurvived: Int
    public var stressCount: Int
    public static let empty = ResilienceAnalysis(requiredRealReturnBps: 0, legacyFloorUsd: 0, sensitivities: [], stresses: [], maxSafeSpendUsd: 0, currentSpendUsd: 0, spendHeadroomBps: 0, stressesSurvived: 0, stressCount: 0)
}

public extension Engine {

    /// Stylized real-return sequences standing in for historically bad ORDERS. Only
    /// the shape matters — each is re-centered to the plan's required return at run
    /// time, so these are stress patterns, not market forecasts.
    static let stressSequences: [(name: String, detail: String, returns: [Double])] = [
        ("Retire into 2000", "Dot-com bust then 2008 — a lost decade up front",
         [-0.09, -0.12, -0.22, 0.26, 0.09, 0.03, 0.14, 0.04, -0.37, 0.26, 0.15, 0.02, 0.16, 0.32, 0.14, 0.01, 0.12, 0.22, -0.04, 0.31]),
        ("Retire into 2008", "A 37% drawdown in the very first year of retirement",
         [-0.37, 0.26, 0.15, 0.02, 0.16, 0.32, 0.14, 0.01, 0.12, 0.22, -0.04, 0.31, 0.18, 0.29, -0.18, 0.26, 0.19, 0.29, -0.25, 0.12]),
        ("1966 stagflation", "Fifteen years of poor real returns — the retiree's worst case",
         [-0.10, 0.24, 0.11, -0.08, 0.04, 0.14, 0.19, -0.15, -0.26, 0.37, 0.24, -0.07, 0.07, 0.19, 0.33, -0.05, 0.22, 0.23, 0.06, 0.32]),
    ]

    static func resilience(_ h: Household, tax: TaxParameterSet, rr: RequiredReturn, asOf: IsoDate, annualTaxUsd: [Int: Usd]) -> ResilienceAnalysis {
        guard let primary = h.primary else { return .empty }
        let primaryAge0 = age(birthDate: primary.birthDate, asOf: asOf)
        let horizon = max(1, h.goals.compactMap { $0.horizonYears }.max() ?? 30)
        let A = h.portfolioValueUsd
        let r = rr.requiredRealReturnBps.frac
        let floor = max(0, h.legacyFloorUsd)
        let (spend, other) = outflowComponents(h, asOf: asOf, annualTaxUsd: annualTaxUsd)
        let equityShare = A > 0 ? min(1.0, h.positions.filter { isEquity($0) }.reduce(0) { $0 + $1.marketValueUsd } / A) : 0.6

        // Run the corpus at a per-year return, scaling the spending component by `mult`.
        func run(_ ret: (Int) -> Double, mult: Double = 1) -> (terminal: Usd, depletion: Int?) {
            var b = A, dep: Int? = nil
            for t in 1...horizon {
                let outflow = mult * (t <= spend.count ? spend[t - 1] : 0) + (t <= other.count ? other[t - 1] : 0)
                b = b * (1 + ret(t)) - outflow
                if b <= 0 && dep == nil { dep = t; b = 0 }
            }
            return (max(0, b), dep)
        }

        // Return sensitivity: the realized return misses the required return by ±.
        let sensitivities = [-200, -100, 0, 100, 200].map { d -> ReturnSensitivity in
            let (term, dep) = run { _ in r + d.frac }
            return ReturnSensitivity(realReturnBps: rr.requiredRealReturnBps + d, terminalBalanceUsd: term, depletionAge: dep.map { primaryAge0 + $0 })
        }

        // Sequence stress: the required return, re-centered into each bad order.
        let stresses = stressSequences.map { seq -> SequenceStress in
            let mean = seq.returns.reduce(0, +) / Double(seq.returns.count)
            let (term, dep) = run { t in r + (seq.returns[(t - 1) % seq.returns.count] - mean) * equityShare }
            return SequenceStress(name: seq.name, detail: seq.detail, survives: dep == nil, meetsFloor: dep == nil && term >= floor,
                                  terminalBalanceUsd: term, depletionAge: dep.map { primaryAge0 + $0 })
        }

        // Max safe spend: bisect the spending multiplier that just survives the worst stress.
        let worst = stressSequences.min { a, b in
            let ma = a.returns.reduce(0, +) / Double(a.returns.count), mb = b.returns.reduce(0, +) / Double(b.returns.count)
            return run({ t in r + (a.returns[(t - 1) % a.returns.count] - ma) * equityShare }).terminal
                 < run({ t in r + (b.returns[(t - 1) % b.returns.count] - mb) * equityShare }).terminal
        }
        var maxMult = 1.0
        if let w = worst {
            let mean = w.returns.reduce(0, +) / Double(w.returns.count)
            let ret: (Int) -> Double = { t in r + (w.returns[(t - 1) % w.returns.count] - mean) * equityShare }
            var lo = 0.0, hi = 3.0
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if run(ret, mult: mid).depletion == nil && run(ret, mult: mid).terminal >= floor { lo = mid } else { hi = mid }
            }
            maxMult = lo
        }
        let currentSpend = spend.max() ?? 0
        let maxSafeSpend = currentSpend * maxMult
        let headroom = currentSpend > 0 ? ((maxSafeSpend - currentSpend) / currentSpend).bps : 0

        return ResilienceAnalysis(
            requiredRealReturnBps: rr.requiredRealReturnBps, legacyFloorUsd: floor,
            sensitivities: sensitivities, stresses: stresses,
            maxSafeSpendUsd: maxSafeSpend, currentSpendUsd: currentSpend, spendHeadroomBps: headroom,
            stressesSurvived: stresses.filter { $0.survives }.count, stressCount: stresses.count)
    }

    /// The spending and the (tax − external income) components of net outflow, per plan
    /// year — split so the spending can be scaled independently for the safe-spend solve.
    static func outflowComponents(_ h: Household, asOf: IsoDate, annualTaxUsd: [Int: Usd]) -> (spend: [Usd], other: [Usd]) {
        let saveYears = h.primary.map { max(0, $0.expectedRetirementAge - age(birthDate: $0.birthDate, asOf: asOf)) } ?? 0
        let horizon = max(1, h.goals.compactMap { $0.horizonYears }.max() ?? 30)
        var spend: [Usd] = [], other: [Usd] = []
        for t in 1...horizon {
            var s: Usd = 0
            for g in h.goals where g.kind == .spending || g.kind == .reserve {
                let excess = g.inflationSeries.realExcessBps.frac
                for o in g.outflows where o.year == t {
                    s += o.amountUsd * (o.inflationLinked ? pow(1 + excess, Double(max(0, t - 1))) : 1.0)
                }
            }
            var inflow: Usd = (t <= saveYears ? h.annualSavingsUsd : 0)
            inflow += socialSecurityAnnual(h, year: t, asOf: asOf) + pensionAnnual(h, year: t) + homeEquityOffset(h, year: t)
            spend.append(s)
            other.append((annualTaxUsd[t] ?? 0) - inflow)
        }
        return (spend, other)
    }
}
