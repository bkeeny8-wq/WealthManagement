//  IPSReview.swift
//  WealthPolicyDesk
//
//  A dated snapshot of the plan, taken when the advisor walks the Investment Policy
//  Statement and confirms it still fits — the "annual review." The intake drives the
//  first IPS; each review afterwards captures the headline figures (and the driver edits
//  in effect) at that moment, so the client record carries a year-over-year history of
//  how the objectives and funded status moved. Codable and lightweight — it stores the
//  figures and the override set, not the whole household.

import Foundation

public struct IPSReview: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var note: String
    // Headline figures captured at review time.
    public var requiredRealReturnBps: Bps
    public var fundedRatioBps: Bps
    public var equityCeilingBps: Bps
    public var afterTaxNetWorthUsd: Usd
    public var goalCount: Int
    public var overrides: HouseholdOverrides

    public init(id: String = UUID().uuidString, createdAt: Date, note: String = "",
                requiredRealReturnBps: Bps, fundedRatioBps: Bps, equityCeilingBps: Bps,
                afterTaxNetWorthUsd: Usd, goalCount: Int, overrides: HouseholdOverrides = HouseholdOverrides()) {
        self.id = id; self.createdAt = createdAt; self.note = note
        self.requiredRealReturnBps = requiredRealReturnBps; self.fundedRatioBps = fundedRatioBps
        self.equityCeilingBps = equityCeilingBps; self.afterTaxNetWorthUsd = afterTaxNetWorthUsd
        self.goalCount = goalCount; self.overrides = overrides
    }

    /// Snapshot the headline figures from an evaluated plan.
    public static func from(_ e: Evaluation, overrides: HouseholdOverrides, at date: Date, note: String = "") -> IPSReview {
        IPSReview(createdAt: date, note: note,
                  requiredRealReturnBps: e.requiredReturn.requiredRealReturnBps,
                  fundedRatioBps: e.balanceSheet.fundedRatioBps,
                  equityCeilingBps: e.riskProfile?.bindingEquityBps ?? 0,
                  afterTaxNetWorthUsd: e.balanceSheet.afterTaxNetWorthUsd,
                  goalCount: e.household.goals.filter { $0.kind == .spending }.count,
                  overrides: overrides)
    }
}
