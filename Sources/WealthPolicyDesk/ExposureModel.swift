//  ExposureModel.swift
//  WealthPolicyDesk
//
//  Ported from src/exposure-matrix-module.ts and the Sector/SECTOR_ETF types of
//  src/sector-tilt-module.ts.
//
//  Equity exposure is a JOINT Country x Sector matrix. A country tilt is
//  unavoidably also a sector tilt: a technology overweight plus a Taiwan
//  overweight each read compliant per-axis while jointly forming a large
//  undeclared semiconductor bet. Only constraints on matrix CELLS — not just the
//  margins — catch this. The live look-through works off String-keyed cells
//  (ExposureLookthrough.swift); the geo-tree / axis-rule / fund-lineup scaffolding
//  this file once carried was never wired and has been retired.

import Foundation

// MARK: - Sectors (GICS)

public enum Sector: String, CaseIterable, Identifiable, Sendable, Hashable {
    case technology, financials, healthcare
    case consumerDiscretionary = "consumer_discretionary", consumerStaples = "consumer_staples"
    case industrials, energy, materials, utilities
    case realEstate = "real_estate", communicationServices = "communication_services"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .technology: return "Technology"
        case .financials: return "Financials"
        case .healthcare: return "Health Care"
        case .consumerDiscretionary: return "Consumer Discretionary"
        case .consumerStaples: return "Consumer Staples"
        case .industrials: return "Industrials"
        case .energy: return "Energy"
        case .materials: return "Materials"
        case .utilities: return "Utilities"
        case .realEstate: return "Real Estate"
        case .communicationServices: return "Communication Services"
        }
    }
    /// The Select Sector SPDR ETF for this sector.
    public var spdrTicker: String {
        switch self {
        case .technology: return "XLK"
        case .financials: return "XLF"
        case .healthcare: return "XLV"
        case .consumerDiscretionary: return "XLY"
        case .consumerStaples: return "XLP"
        case .industrials: return "XLI"
        case .energy: return "XLE"
        case .materials: return "XLB"
        case .utilities: return "XLU"
        case .realEstate: return "XLRE"
        case .communicationServices: return "XLC"
        }
    }
}

// MARK: - Matrix constraints (the country×sector look-through caps)

public struct MatrixConstraint: Identifiable, Sendable, Hashable {
    public enum Scope: String, Sendable, Hashable { case cell, geoMargin = "geo_margin", sectorMargin = "sector_margin" }
    public var id: String
    public var severity: Severity
    public var scope: Scope
    public var limitBps: Bps
    public var description: String
    public init(id: String, severity: Severity, scope: Scope, limitBps: Bps, description: String) {
        self.id = id; self.severity = severity; self.scope = scope; self.limitBps = limitBps; self.description = description
    }
}

// MARK: - Tactical sector-overlay policy (the per-client tilt BUDGET)

/// The firm-wide deviation caps governing the per-client tactical tilts. Kept
/// small: tactical rotation is the weakest-evidence component and is budgeted
/// accordingly. Tilts themselves are per-client (Household.tacticalTilts).
public struct TiltPolicy: Sendable, Hashable {
    public var enabled: Bool
    public var mode: String
    public var coreShareOfEquityBps: Bps
    public var maxTotalAbsoluteDeviationBps: Bps
    public var maxSingleSectorDeviationBps: Bps
    public var maxLookThroughSectorBps: Bps
    public var restrictToTreatments: [AccountTaxTreatment]
    public init(enabled: Bool, mode: String, coreShareOfEquityBps: Bps, maxTotalAbsoluteDeviationBps: Bps, maxSingleSectorDeviationBps: Bps, maxLookThroughSectorBps: Bps, restrictToTreatments: [AccountTaxTreatment]) {
        self.enabled = enabled; self.mode = mode; self.coreShareOfEquityBps = coreShareOfEquityBps
        self.maxTotalAbsoluteDeviationBps = maxTotalAbsoluteDeviationBps
        self.maxSingleSectorDeviationBps = maxSingleSectorDeviationBps
        self.maxLookThroughSectorBps = maxLookThroughSectorBps
        self.restrictToTreatments = restrictToTreatments
    }
}
