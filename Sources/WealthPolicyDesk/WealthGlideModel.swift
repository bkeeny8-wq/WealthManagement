//  WealthGlideModel.swift
//  WealthPolicyDesk
//
//  The lifetime wealth glide — the picture a required-return NUMBER can't show:
//  where the money is over a life. Two bands stacked, year by year, in today's
//  real dollars:
//    • Human capital — the present value of earnings still ahead. High when young,
//      it converts into financial capital as you save, and reaches zero at retirement.
//    • Financial capital — the portfolio. It grows through accumulation (returns plus
//      the savings human capital funds), peaks near retirement, then draws down to
//      fund spending, landing at the legacy floor.
//
//  The financial line is the plan's OWN required-return projection (the on-plan path
//  that, by construction, ends at the floor) — not a market forecast. Whether real
//  returns can DELIVER that path is the Resilience / Shortfall question; this shows
//  the shape the plan intends. Pure and deterministic like the rest of the engine.

import Foundation

public struct WealthGlidePoint: Identifiable, Sendable, Hashable {
    public var year: Int
    public var age: Int
    public var financialUsd: Usd
    public var humanCapitalUsd: Usd
    public var id: Int { year }
    public var totalUsd: Usd { financialUsd + humanCapitalUsd }
}

public struct WealthGlide: Sendable {
    public var points: [WealthGlidePoint]
    public var retirementAge: Int
    public var retirementYear: Int
    public var peakTotalUsd: Usd
    public var peakTotalAge: Int
    public var currentTotalUsd: Usd
    public var legacyFloorUsd: Usd
    public var depletionAge: Int?          // first age the portfolio hits zero after retirement (nil = lasts)
    public var hasHumanCapital: Bool
    public static let empty = WealthGlide(points: [], retirementAge: 0, retirementYear: 0, peakTotalUsd: 0, peakTotalAge: 0, currentTotalUsd: 0, legacyFloorUsd: 0, depletionAge: nil, hasHumanCapital: false)
}

public extension Engine {

    /// The financial + human capital trajectory over the plan horizon (today's real $).
    static func wealthGlide(_ eval: Evaluation) -> WealthGlide {
        let h = eval.household
        guard let primary = h.primary, !eval.requiredReturn.projection.isEmpty else { return .empty }
        let age0 = age(birthDate: primary.birthDate, asOf: eval.asOf)
        let year0 = year(eval.asOf)
        let retireAge = primary.expectedRetirementAge
        let hasHC = h.humanCapital.contains { $0.yearsRemaining > 0 }

        var points: [WealthGlidePoint] = []
        for yb in eval.requiredReturn.projection {
            let k = yb.year - year0                                   // years from now
            guard k >= 0 else { continue }
            points.append(WealthGlidePoint(year: yb.year, age: age0 + k,
                financialUsd: max(0, yb.balanceUsd),
                humanCapitalUsd: humanCapitalAtYear(h, yearsFromNow: k)))
        }

        let peak = points.max { $0.totalUsd < $1.totalUsd }
        // A GENUINE early run-out floors to 0 for years before the horizon ends. The
        // required-return path is solved to land exactly at the legacy floor, so with a
        // zero floor it touches 0 only at the terminal node — exclude that last point so
        // an on-plan landing isn't mislabeled a shortfall (and doesn't flip on rounding).
        let depletion = points.dropLast().first { $0.age > retireAge && $0.financialUsd <= 0 }?.age

        return WealthGlide(
            points: points, retirementAge: retireAge, retirementYear: year0 + max(0, retireAge - age0),
            peakTotalUsd: peak?.totalUsd ?? 0, peakTotalAge: peak?.age ?? age0,
            currentTotalUsd: points.first?.totalUsd ?? 0, legacyFloorUsd: max(0, h.legacyFloorUsd),
            depletionAge: depletion, hasHumanCapital: hasHC)
    }

    /// Present value, AT year k (in year-k real dollars), of the earnings still ahead —
    /// the same discounted-earnings model the balance sheet uses at k = 0.
    static func humanCapitalAtYear(_ h: Household, yearsFromNow k: Int) -> Usd {
        var pv: Usd = 0
        for hc in h.humanCapital where hc.yearsRemaining > k {
            let g = hc.realGrowthRateBps.frac
            for t in (k + 1)...hc.yearsRemaining {
                pv += hc.annualIncomeUsd * pow(1 + g, Double(t - 1)) / pow(1 + humanCapitalDiscount, Double(t - k))
            }
        }
        return pv
    }
}
