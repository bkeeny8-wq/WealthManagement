//  LayerModel.swift
//  WealthPolicyDesk
//
//  A portfolio splits into independently-rebalanced LAYERS: strategic policy
//  sleeves, tactical view-expressing overlays, and a held-to-maturity ladder. A
//  deliberate short-term tilt and a perpetual policy allocation are different jobs
//  and must never share a tax lot. Every holding carries the `Layer` tag below; the
//  one enforced rule (no tactical step-up) reads it directly. The budgeting /
//  entry-gate / attribution scaffolding this file once carried was never wired and
//  has been retired.

import Foundation

/// The tag every holding carries. A position may not be in two layers.
public enum Layer: String, CaseIterable, Identifiable, Sendable, Hashable {
    case strategic, tactical, ladder
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}
