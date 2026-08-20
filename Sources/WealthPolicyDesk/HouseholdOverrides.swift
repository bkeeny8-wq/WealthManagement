//  HouseholdOverrides.swift
//  WealthPolicyDesk
//
//  The editable layer on top of the standardized, question-derived household. The intake
//  answers produce a standard plan; a driver override lets the advisor adjust a foundational
//  assumption straight from the Policy Statement — the legacy floor, the risk-tolerance
//  ceiling, retirement spending, or the GOALS themselves (add a college / home / travel goal
//  beyond retirement, or drop one) — and have the whole plan (required return, funded ratio,
//  allocation, shortfall) re-derive. Overrides sit ON TOP of the intake-built household, so
//  the standardized answer is never lost; clearing an override returns to it. Every field
//  feeds Engine.evaluate directly, so an override re-derives everything with no rebuild.
//
//  `Goal` isn't Codable (it carries engine-only schedule types), so an added goal is stored
//  as a small Codable PARAMETER set (GoalEdit) and the Goal is constructed at apply time.

import Foundation

/// A client goal beyond retirement, entered from the Policy Statement. Parameters only —
/// the engine Goal is built in `withDriverOverrides`.
public struct GoalEdit: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var annualUsd: Usd
    public var startYear: Int        // years from now (≥1)
    public var years: Int            // duration in years (≥1; 1 = one-time)
    public init(id: String, label: String, annualUsd: Usd, startYear: Int, years: Int) {
        self.id = id; self.label = label; self.annualUsd = annualUsd
        self.startYear = max(1, startYear); self.years = max(1, years)
    }
    /// The engine goal id this edit becomes once applied.
    public var goalId: String { "ov_\(id)" }
}

public struct HouseholdOverrides: Codable, Sendable, Hashable {
    public var legacyFloorUsd: Usd? = nil
    public var toleranceMaxDrawdownBps: Bps? = nil
    public var retirementSpendingUsd: Usd? = nil       // absolute annual retirement spend (replaces g_spending)
    public var addedGoals: [GoalEdit] = []             // goals beyond retirement to fund
    public var removedGoalIds: [String] = []           // goal ids to drop (added or standard)

    public init(legacyFloorUsd: Usd? = nil, toleranceMaxDrawdownBps: Bps? = nil,
                retirementSpendingUsd: Usd? = nil, addedGoals: [GoalEdit] = [], removedGoalIds: [String] = []) {
        self.legacyFloorUsd = legacyFloorUsd; self.toleranceMaxDrawdownBps = toleranceMaxDrawdownBps
        self.retirementSpendingUsd = retirementSpendingUsd; self.addedGoals = addedGoals; self.removedGoalIds = removedGoalIds
    }

    /// Forward/backward-compatible decode: a missing field never drops the record.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        legacyFloorUsd = (try? c.decodeIfPresent(Usd.self, forKey: .legacyFloorUsd)) ?? nil
        toleranceMaxDrawdownBps = (try? c.decodeIfPresent(Bps.self, forKey: .toleranceMaxDrawdownBps)) ?? nil
        retirementSpendingUsd = (try? c.decodeIfPresent(Usd.self, forKey: .retirementSpendingUsd)) ?? nil
        addedGoals = ((try? c.decodeIfPresent([GoalEdit].self, forKey: .addedGoals)) ?? nil) ?? []
        removedGoalIds = ((try? c.decodeIfPresent([String].self, forKey: .removedGoalIds)) ?? nil) ?? []
    }

    public var isEmpty: Bool {
        legacyFloorUsd == nil && toleranceMaxDrawdownBps == nil && retirementSpendingUsd == nil
            && addedGoals.isEmpty && removedGoalIds.isEmpty
    }
    public var count: Int {
        (legacyFloorUsd == nil ? 0 : 1) + (toleranceMaxDrawdownBps == nil ? 0 : 1)
            + (retirementSpendingUsd == nil ? 0 : 1) + addedGoals.count + removedGoalIds.count
    }

    /// Fold another set of overrides in — scalar fields: non-nil wins; collections append.
    public mutating func merge(_ o: HouseholdOverrides) {
        if let v = o.legacyFloorUsd { legacyFloorUsd = v }
        if let v = o.toleranceMaxDrawdownBps { toleranceMaxDrawdownBps = v }
        if let v = o.retirementSpendingUsd { retirementSpendingUsd = v }
        addedGoals.append(contentsOf: o.addedGoals)
        removedGoalIds.append(contentsOf: o.removedGoalIds)
    }
}

public extension Household {
    /// Apply driver overrides to a copy — every field feeds Engine.evaluate directly, so the
    /// whole plan re-derives from the overridden values.
    func withDriverOverrides(_ o: HouseholdOverrides) -> Household {
        var h = self
        if let v = o.legacyFloorUsd { h.legacyFloorUsd = v }
        if let v = o.toleranceMaxDrawdownBps { h.statedToleranceMaxDrawdownBps = v }
        if let v = o.retirementSpendingUsd {
            h.goals = h.goals.map { g in
                guard g.id == "g_spending" else { return g }
                var ng = g
                ng.outflows = g.outflows.map { var of = $0; of.amountUsd = v; return of }
                return ng
            }
        }
        for ge in o.addedGoals where ge.annualUsd > 0 {
            let start = max(1, ge.startYear), yrs = max(1, ge.years)
            let outflows = (0..<yrs).map { Outflow(year: start + $0, amountUsd: ge.annualUsd, inflationLinked: true) }
            h.goals.append(Goal(id: ge.goalId, label: ge.label, kind: .spending, tier: .lifestyle,
                                horizonYears: start + yrs - 1, outflows: outflows, inflationSeries: .cpi,
                                maxShortfallProbabilityBps: 1500, holdToStepUp: false,
                                flexibility: GoalFlexibility(deferrableYears: 3, scalableDownBps: 5000, abandonable: true),
                                policyId: "spending-glide"))
        }
        if !o.removedGoalIds.isEmpty { h.goals.removeAll { o.removedGoalIds.contains($0.id) } }
        return h
    }
}
