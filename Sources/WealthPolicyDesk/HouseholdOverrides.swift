//  HouseholdOverrides.swift
//  WealthPolicyDesk
//
//  The editable layer on top of the standardized, question-derived household. The intake
//  answers produce a standard plan; a driver override lets the advisor adjust a foundational
//  assumption straight from the Policy Statement — the legacy floor, the risk-tolerance
//  ceiling — and have the whole plan (required return, allocation, shortfall) re-derive.
//  Overrides sit ON TOP of the intake-built household, so the standardized answer is never
//  lost; clearing an override returns to it. Both fields flow directly into Engine.evaluate,
//  so an override re-derives everything with no rebuild.

import Foundation

public struct HouseholdOverrides: Codable, Sendable, Hashable {
    public var legacyFloorUsd: Usd? = nil
    public var toleranceMaxDrawdownBps: Bps? = nil

    public init(legacyFloorUsd: Usd? = nil, toleranceMaxDrawdownBps: Bps? = nil) {
        self.legacyFloorUsd = legacyFloorUsd
        self.toleranceMaxDrawdownBps = toleranceMaxDrawdownBps
    }

    public var isEmpty: Bool { legacyFloorUsd == nil && toleranceMaxDrawdownBps == nil }
    public var count: Int { (legacyFloorUsd == nil ? 0 : 1) + (toleranceMaxDrawdownBps == nil ? 0 : 1) }

    /// Fold another set of overrides in — non-nil fields win.
    public mutating func merge(_ o: HouseholdOverrides) {
        if let v = o.legacyFloorUsd { legacyFloorUsd = v }
        if let v = o.toleranceMaxDrawdownBps { toleranceMaxDrawdownBps = v }
    }
}

public extension Household {
    /// Apply driver overrides to a copy. Both fields feed Engine.evaluate directly
    /// (legacy floor → required return; drawdown tolerance → risk profile → allocation),
    /// so the whole plan re-derives from the overridden values.
    func withDriverOverrides(_ o: HouseholdOverrides) -> Household {
        var h = self
        if let v = o.legacyFloorUsd { h.legacyFloorUsd = v }
        if let v = o.toleranceMaxDrawdownBps { h.statedToleranceMaxDrawdownBps = v }
        return h
    }
}
