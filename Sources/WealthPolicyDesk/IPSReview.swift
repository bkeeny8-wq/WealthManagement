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
    /// Section keys the advisor confirmed "still applicable" while walking the statement.
    public var confirmedSections: [String]
    // Headline figures captured at review time.
    public var requiredRealReturnBps: Bps
    public var fundedRatioBps: Bps
    public var equityCeilingBps: Bps
    public var afterTaxNetWorthUsd: Usd
    public var goalCount: Int
    public var overrides: HouseholdOverrides

    public init(id: String = UUID().uuidString, createdAt: Date, note: String = "", confirmedSections: [String] = [],
                requiredRealReturnBps: Bps, fundedRatioBps: Bps, equityCeilingBps: Bps,
                afterTaxNetWorthUsd: Usd, goalCount: Int, overrides: HouseholdOverrides = HouseholdOverrides()) {
        self.id = id; self.createdAt = createdAt; self.note = note; self.confirmedSections = confirmedSections
        self.requiredRealReturnBps = requiredRealReturnBps; self.fundedRatioBps = fundedRatioBps
        self.equityCeilingBps = equityCeilingBps; self.afterTaxNetWorthUsd = afterTaxNetWorthUsd
        self.goalCount = goalCount; self.overrides = overrides
    }

    /// Forward/backward-compatible decode: a missing field never drops the record.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? UUID().uuidString
        createdAt = ((try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil) ?? Date()
        note = ((try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil) ?? ""
        confirmedSections = ((try? c.decodeIfPresent([String].self, forKey: .confirmedSections)) ?? nil) ?? []
        requiredRealReturnBps = ((try? c.decodeIfPresent(Bps.self, forKey: .requiredRealReturnBps)) ?? nil) ?? 0
        fundedRatioBps = ((try? c.decodeIfPresent(Bps.self, forKey: .fundedRatioBps)) ?? nil) ?? 0
        equityCeilingBps = ((try? c.decodeIfPresent(Bps.self, forKey: .equityCeilingBps)) ?? nil) ?? 0
        afterTaxNetWorthUsd = ((try? c.decodeIfPresent(Usd.self, forKey: .afterTaxNetWorthUsd)) ?? nil) ?? 0
        goalCount = ((try? c.decodeIfPresent(Int.self, forKey: .goalCount)) ?? nil) ?? 0
        overrides = ((try? c.decodeIfPresent(HouseholdOverrides.self, forKey: .overrides)) ?? nil) ?? HouseholdOverrides()
    }

    /// Snapshot the headline figures from an evaluated plan.
    public static func from(_ e: Evaluation, overrides: HouseholdOverrides, at date: Date,
                            note: String = "", confirmedSections: [String] = []) -> IPSReview {
        IPSReview(createdAt: date, note: note, confirmedSections: confirmedSections,
                  requiredRealReturnBps: e.requiredReturn.requiredRealReturnBps,
                  fundedRatioBps: e.balanceSheet.fundedRatioBps,
                  equityCeilingBps: e.riskProfile?.bindingEquityBps ?? 0,
                  afterTaxNetWorthUsd: e.balanceSheet.afterTaxNetWorthUsd,
                  goalCount: e.household.goals.filter { $0.kind == .spending }.count,
                  overrides: overrides)
    }
}
