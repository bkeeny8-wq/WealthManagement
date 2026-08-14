//  LayerModel.swift
//  WealthPolicyDesk
//
//  Ported from src/layer-separation-module.ts.
//
//  A portfolio splits into independently-rebalanced LAYERS: strategic policy
//  sleeves, tactical view-expressing overlays, and a held-to-maturity ladder.
//  A slow strategic rebalancer and a fast tactical overlay run against the same
//  book without unwinding each other. A deliberate short-term tilt and a
//  perpetual policy allocation are different jobs — they must never share a tax
//  lot or a rebalancing engine.

import Foundation

/// The tag every holding carries. A position may not be in two layers.
public enum Layer: String, CaseIterable, Identifiable, Sendable, Hashable {
    case strategic, tactical, ladder
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// Per-axis discipline: reviewBy (is the thesis valid?) separated from a hard
/// maxHoldingDays ceiling. A fresh thesis is required on re-entry.
public struct HoldingPeriodPolicy: Identifiable, Sendable, Hashable {
    public var axis: TiltAxis
    public var reviewIntervalDays: Int
    public var maxHoldingDays: Int
    public var requiresFreshThesisOnReentry: Bool
    public var reentryCooldownDays: Int
    public var id: String { axis.rawValue }
    public init(axis: TiltAxis, reviewIntervalDays: Int, maxHoldingDays: Int, requiresFreshThesisOnReentry: Bool, reentryCooldownDays: Int) {
        self.axis = axis; self.reviewIntervalDays = reviewIntervalDays; self.maxHoldingDays = maxHoldingDays
        self.requiresFreshThesisOnReentry = requiresFreshThesisOnReentry; self.reentryCooldownDays = reentryCooldownDays
    }
}

/// Ceiling on the tactical layer. Small, capped, self-funding on net results —
/// tactical rotation has the weakest evidence base.
public struct LayerBudget: Sendable, Hashable {
    public var maxTacticalShareOfEquityBps: Bps
    public var maxTacticalShareOfPortfolioBps: Bps
    public var maxConcurrentTilts: Int
    /// Rolling 12-month realized-cost ceiling.
    public var annualCostBudgetBps: Bps
    public init(maxTacticalShareOfEquityBps: Bps, maxTacticalShareOfPortfolioBps: Bps, maxConcurrentTilts: Int, annualCostBudgetBps: Bps) {
        self.maxTacticalShareOfEquityBps = maxTacticalShareOfEquityBps
        self.maxTacticalShareOfPortfolioBps = maxTacticalShareOfPortfolioBps
        self.maxConcurrentTilts = maxConcurrentTilts; self.annualCostBudgetBps = annualCostBudgetBps
    }
}

/// Entry-time friction estimate for a tilt, annualized to the holding period.
public struct RoundTripCost: Sendable, Hashable {
    public var feeDifferentialBps: Bps
    public var estimatedSpreadBps: Bps
    public var estimatedPremiumDiscountSlippageBps: Bps
    public var expectedHoldingDays: Int
    public var totalEstimatedBps: Bps
    public var estimatedTaxCostBps: Bps
    public init(feeDifferentialBps: Bps, estimatedSpreadBps: Bps, estimatedPremiumDiscountSlippageBps: Bps, expectedHoldingDays: Int, totalEstimatedBps: Bps, estimatedTaxCostBps: Bps) {
        self.feeDifferentialBps = feeDifferentialBps; self.estimatedSpreadBps = estimatedSpreadBps
        self.estimatedPremiumDiscountSlippageBps = estimatedPremiumDiscountSlippageBps
        self.expectedHoldingDays = expectedHoldingDays; self.totalEstimatedBps = totalEstimatedBps
        self.estimatedTaxCostBps = estimatedTaxCostBps
    }
}

/// Hard gate: adviser's expected relative return vs the round-trip cost.
public struct EntryGate: Sendable, Hashable {
    public var expectedRelativeReturnBps: Bps
    public var estimatedCost: RoundTripCost
    public var passes: Bool
    public var overrideReason: String?
    public init(expectedRelativeReturnBps: Bps, estimatedCost: RoundTripCost, passes: Bool, overrideReason: String? = nil) {
        self.expectedRelativeReturnBps = expectedRelativeReturnBps; self.estimatedCost = estimatedCost
        self.passes = passes; self.overrideReason = overrideReason
    }
}

/// Per-layer performance reporting. Tactical is scored against its FUNDING leg,
/// not against zero — the scorecard that decides whether the layer survives.
public struct LayerAttribution: Sendable, Hashable {
    public var strategicReturnBps: Bps
    public var tacticalRelativeReturnBps: Bps
    public var tacticalCostBps: Bps
    public var tacticalNetContributionBps: Bps
    public var tiltsClosed: Int
    public var tiltsProfitable: Int
    public init(strategicReturnBps: Bps, tacticalRelativeReturnBps: Bps, tacticalCostBps: Bps, tacticalNetContributionBps: Bps, tiltsClosed: Int, tiltsProfitable: Int) {
        self.strategicReturnBps = strategicReturnBps; self.tacticalRelativeReturnBps = tacticalRelativeReturnBps
        self.tacticalCostBps = tacticalCostBps; self.tacticalNetContributionBps = tacticalNetContributionBps
        self.tiltsClosed = tiltsClosed; self.tiltsProfitable = tiltsProfitable
    }
    public var hitRateBps: Bps { tiltsClosed > 0 ? (Double(tiltsProfitable) / Double(tiltsClosed)).bps : 0 }
}
