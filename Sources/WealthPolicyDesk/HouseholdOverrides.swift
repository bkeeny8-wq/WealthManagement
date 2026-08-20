//  HouseholdOverrides.swift
//  WealthPolicyDesk
//
//  The editable layer on top of the standardized, question-derived household. The intake
//  answers produce a standard plan; a driver override lets the advisor adjust a foundational
//  assumption straight from the Policy Statement — the legacy floor, the risk-tolerance
//  ceiling, or the GOALS themselves (add a college / home / travel goal beyond retirement,
//  resize any goal's amount, or drop one) — and have the whole plan (required return, funded
//  ratio, allocation, shortfall) re-derive. Overrides sit ON TOP of the intake-built
//  household, so the standardized answer is never lost; clearing an override returns to it.
//  Every field feeds Engine.evaluate directly, so an override re-derives everything with no
//  rebuild.
//
//  `Goal` isn't Codable (it carries engine-only schedule types), so an added goal is stored
//  as a small Codable PARAMETER set (GoalEdit) and the Goal is constructed at apply time; a
//  goal's amount is edited by a per-id override so retirement and any added goal share one path.

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

/// When a goal starts and how long it runs, edited from the Policy Statement.
public struct GoalTiming: Codable, Sendable, Hashable {
    public var startYear: Int    // years from now (≥1)
    public var years: Int        // duration (≥1)
    public init(startYear: Int, years: Int) { self.startYear = max(1, startYear); self.years = max(1, years) }
}

public struct HouseholdOverrides: Codable, Sendable, Hashable {
    public var legacyFloorUsd: Usd? = nil
    public var toleranceMaxDrawdownBps: Bps? = nil
    public var annualSavingsUsd: Usd? = nil             // real savings per year (funds goals directly)
    public var retirementAge: Int? = nil               // the primary's retirement age (shifts spend + human capital)
    public var addedGoals: [GoalEdit] = []              // goals beyond retirement to fund
    public var goalAmountOverrides: [String: Usd] = [:] // goalId → per-outflow amount (retirement or any goal)
    public var goalTimingOverrides: [String: GoalTiming] = [:]  // goalId → start year & duration
    public var removedGoalIds: [String] = []            // goal ids to drop (added or standard)

    public init(legacyFloorUsd: Usd? = nil, toleranceMaxDrawdownBps: Bps? = nil,
                annualSavingsUsd: Usd? = nil, retirementAge: Int? = nil,
                addedGoals: [GoalEdit] = [], goalAmountOverrides: [String: Usd] = [:],
                goalTimingOverrides: [String: GoalTiming] = [:], removedGoalIds: [String] = []) {
        self.legacyFloorUsd = legacyFloorUsd; self.toleranceMaxDrawdownBps = toleranceMaxDrawdownBps
        self.annualSavingsUsd = annualSavingsUsd; self.retirementAge = retirementAge
        self.addedGoals = addedGoals; self.goalAmountOverrides = goalAmountOverrides
        self.goalTimingOverrides = goalTimingOverrides; self.removedGoalIds = removedGoalIds
    }

    /// Forward/backward-compatible decode: a missing field never drops the record.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        legacyFloorUsd = (try? c.decodeIfPresent(Usd.self, forKey: .legacyFloorUsd)) ?? nil
        toleranceMaxDrawdownBps = (try? c.decodeIfPresent(Bps.self, forKey: .toleranceMaxDrawdownBps)) ?? nil
        annualSavingsUsd = (try? c.decodeIfPresent(Usd.self, forKey: .annualSavingsUsd)) ?? nil
        retirementAge = (try? c.decodeIfPresent(Int.self, forKey: .retirementAge)) ?? nil
        addedGoals = ((try? c.decodeIfPresent([GoalEdit].self, forKey: .addedGoals)) ?? nil) ?? []
        goalAmountOverrides = ((try? c.decodeIfPresent([String: Usd].self, forKey: .goalAmountOverrides)) ?? nil) ?? [:]
        goalTimingOverrides = ((try? c.decodeIfPresent([String: GoalTiming].self, forKey: .goalTimingOverrides)) ?? nil) ?? [:]
        removedGoalIds = ((try? c.decodeIfPresent([String].self, forKey: .removedGoalIds)) ?? nil) ?? []
    }

    public var isEmpty: Bool {
        legacyFloorUsd == nil && toleranceMaxDrawdownBps == nil && annualSavingsUsd == nil && retirementAge == nil
            && addedGoals.isEmpty && goalAmountOverrides.isEmpty && goalTimingOverrides.isEmpty && removedGoalIds.isEmpty
    }
    public var count: Int {
        (legacyFloorUsd == nil ? 0 : 1) + (toleranceMaxDrawdownBps == nil ? 0 : 1)
            + (annualSavingsUsd == nil ? 0 : 1) + (retirementAge == nil ? 0 : 1)
            + addedGoals.count + goalAmountOverrides.count + goalTimingOverrides.count + removedGoalIds.count
    }

    /// Fold another set of overrides in — scalars: non-nil wins; collections append; dicts: key wins.
    public mutating func merge(_ o: HouseholdOverrides) {
        if let v = o.legacyFloorUsd { legacyFloorUsd = v }
        if let v = o.toleranceMaxDrawdownBps { toleranceMaxDrawdownBps = v }
        if let v = o.annualSavingsUsd { annualSavingsUsd = v }
        if let v = o.retirementAge { retirementAge = v }
        addedGoals.append(contentsOf: o.addedGoals)
        for (k, v) in o.goalAmountOverrides { goalAmountOverrides[k] = v }
        for (k, v) in o.goalTimingOverrides { goalTimingOverrides[k] = v }
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
        if let v = o.annualSavingsUsd { h.annualSavingsUsd = v }   // feeds the corpus recursion directly
        // Retirement age: the primary retires at a new age → shift the spending schedule,
        // recompute working years (human capital), and update the person. saveYears and
        // decumulation read expectedRetirementAge directly, so they follow automatically.
        if let newAge = o.retirementAge, let p = h.primary {
            let pid = p.id
            let primaryAge = Engine.age(birthDate: p.birthDate, asOf: Engine.planningAsOf)
            h.people = h.people.map { var np = $0; if np.id == pid { np.expectedRetirementAge = newAge }; return np }
            h.humanCapital = h.humanCapital.map { var nhc = $0; if nhc.personId == pid { nhc.yearsRemaining = max(0, newAge - primaryAge) }; return nhc }
            h.goals = h.goals.map { g in
                guard g.id == "g_spending" else { return g }
                let end = g.horizonYears ?? (g.outflows.map { $0.year }.max() ?? 1)
                let start = max(1, newAge - primaryAge)
                guard start <= end else { return g }
                let amt = g.outflows.first?.amountUsd ?? 0
                var ng = g
                ng.outflows = (start...end).map { Outflow(year: $0, amountUsd: amt, inflationLinked: true) }
                return ng
            }
        }
        // Added goals first (so a later amount override can target them too).
        for ge in o.addedGoals where ge.annualUsd > 0 {
            let start = max(1, ge.startYear), yrs = max(1, ge.years)
            let outflows = (0..<yrs).map { Outflow(year: start + $0, amountUsd: ge.annualUsd, inflationLinked: true) }
            h.goals.append(Goal(id: ge.goalId, label: ge.label, kind: .spending, tier: .lifestyle,
                                horizonYears: start + yrs - 1, outflows: outflows, inflationSeries: .cpi,
                                maxShortfallProbabilityBps: 1500, holdToStepUp: false,
                                flexibility: GoalFlexibility(deferrableYears: 3, scalableDownBps: 5000, abandonable: true),
                                policyId: "spending-glide"))
        }
        // Per-goal amount overrides (retirement or any goal): set every outflow to the amount.
        if !o.goalAmountOverrides.isEmpty {
            h.goals = h.goals.map { g in
                guard let amt = o.goalAmountOverrides[g.id] else { return g }
                var ng = g
                ng.outflows = g.outflows.map { var of = $0; of.amountUsd = amt; return of }
                return ng
            }
        }
        // Per-goal timing overrides: lay the goal's amount over the new start/duration.
        if !o.goalTimingOverrides.isEmpty {
            h.goals = h.goals.map { g in
                guard let t = o.goalTimingOverrides[g.id] else { return g }
                let amt = g.outflows.first?.amountUsd ?? g.nominalTodayUsd
                let linked = g.outflows.first?.inflationLinked ?? true
                let start = max(1, t.startYear), yrs = max(1, t.years)
                var ng = g
                ng.outflows = (0..<yrs).map { Outflow(year: start + $0, amountUsd: amt, inflationLinked: linked) }
                ng.horizonYears = start + yrs - 1
                return ng
            }
        }
        if !o.removedGoalIds.isEmpty { h.goals.removeAll { o.removedGoalIds.contains($0.id) } }
        return h
    }
}
