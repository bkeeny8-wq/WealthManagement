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
//  margins — catch this.

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

// MARK: - Tilts

public enum TiltAxis: String, CaseIterable, Identifiable, Sendable, Hashable {
    case sector, geo, style
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public enum TiltFunding: String, CaseIterable, Sendable, Hashable {
    case proRata = "pro_rata"   // funded from core, implicitly underweighting all others
    case paired                 // explicit named offsetting underweight (preferred)
    public var label: String { self == .proRata ? "Pro-rata" : "Paired" }
}

public enum CurrencyStance: String, CaseIterable, Sendable, Hashable {
    case unhedged, hedged, noView = "no_view"
    public var label: String { self == .noView ? "No view" : rawValue.capitalized }
}

/// A generalized signed deviation on any axis. Thesis is mandatory;
/// acknowledgedCrossExposure forces cross-axis realization at entry.
public struct Tilt: Identifiable, Sendable, Hashable {
    public var id: String
    public var axis: TiltAxis
    public var nodeId: String            // sector rawValue, geo node id, or style id
    public var deviationBps: Bps         // signed
    public var funding: TiltFunding
    public var offsetNodeId: String?
    public var currency: CurrencyStance
    public var thesis: String
    public var openedAt: IsoDate
    public var reviewBy: IsoDate
    public var exitCondition: String?
    public var acknowledgedCrossExposure: [String]
    public init(id: String, axis: TiltAxis, nodeId: String, deviationBps: Bps, funding: TiltFunding, offsetNodeId: String?, currency: CurrencyStance, thesis: String, openedAt: IsoDate, reviewBy: IsoDate, exitCondition: String?, acknowledgedCrossExposure: [String]) {
        self.id = id; self.axis = axis; self.nodeId = nodeId; self.deviationBps = deviationBps
        self.funding = funding; self.offsetNodeId = offsetNodeId; self.currency = currency; self.thesis = thesis
        self.openedAt = openedAt; self.reviewBy = reviewBy; self.exitCondition = exitCondition
        self.acknowledgedCrossExposure = acknowledgedCrossExposure
    }
}

// MARK: - Geography tree

public enum GeoLevel: String, CaseIterable, Sendable, Hashable {
    case global, bloc, region, country
}

public struct GeoNode: Identifiable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var level: GeoLevel
    public var parentId: String?
    public var isoCode: String?
    public init(id: String, label: String, level: GeoLevel, parentId: String?, isoCode: String? = nil) {
        self.id = id; self.label = label; self.level = level; self.parentId = parentId; self.isoCode = isoCode
    }
}

// MARK: - Rules and constraints

public struct AxisRules: Identifiable, Sendable, Hashable {
    public var axis: TiltAxis
    public var restrictToTreatments: [AccountTaxTreatment]
    public var minExpectedRelativeReturnBps: Bps    // hurdle
    public var maxSingleDeviationBps: Bps
    public var maxTotalAbsoluteDeviationBps: Bps
    public var id: String { axis.rawValue }
    public init(axis: TiltAxis, restrictToTreatments: [AccountTaxTreatment], minExpectedRelativeReturnBps: Bps, maxSingleDeviationBps: Bps, maxTotalAbsoluteDeviationBps: Bps) {
        self.axis = axis; self.restrictToTreatments = restrictToTreatments
        self.minExpectedRelativeReturnBps = minExpectedRelativeReturnBps
        self.maxSingleDeviationBps = maxSingleDeviationBps; self.maxTotalAbsoluteDeviationBps = maxTotalAbsoluteDeviationBps
    }
}

public struct MatrixConstraint: Identifiable, Sendable, Hashable {
    public enum Scope: String, Sendable, Hashable { case cell, geoMargin = "geo_margin", sectorMargin = "sector_margin", total }
    public var id: String
    public var severity: Severity
    public var scope: Scope
    public var limitBps: Bps
    public var description: String
    public init(id: String, severity: Severity, scope: Scope, limitBps: Bps, description: String) {
        self.id = id; self.severity = severity; self.scope = scope; self.limitBps = limitBps; self.description = description
    }
}

// MARK: - Live decomposition (fetched, never stored as policy)

public struct ExposureMatrix: Sendable, Hashable {
    public var asOf: IsoDate
    public var source: String
    public var maxAgeDays: Int
    /// cells[geoId][sector] in bps of total equity (joint exposure).
    public var cells: [String: [Sector: Bps]]
    public var byGeoBps: [String: Bps]
    public var bySectorBps: [Sector: Bps]
    public init(asOf: IsoDate, source: String, maxAgeDays: Int, cells: [String: [Sector: Bps]], byGeoBps: [String: Bps], bySectorBps: [Sector: Bps]) {
        self.asOf = asOf; self.source = source; self.maxAgeDays = maxAgeDays
        self.cells = cells; self.byGeoBps = byGeoBps; self.bySectorBps = bySectorBps
    }
}

// MARK: - Fund lineup

/// One-family-per-side lineup, preventing index-family reconciliation bugs
/// (FTSE vs MSCI Korea classification). Domestic = S&P family; international =
/// MSCI family. TLH partners are always a different family.
public struct FundLineup: Sendable, Hashable {
    public struct Vehicle: Sendable, Hashable {
        public var ticker: String
        public var label: String
        public var feeBps: Bps
        public init(ticker: String, label: String, feeBps: Bps) { self.ticker = ticker; self.label = label; self.feeBps = feeBps }
    }
    public var domesticCore: Vehicle
    public var domesticMid: Vehicle
    public var domesticSmall: Vehicle
    public var developedCore: Vehicle
    public var emergingCore: Vehicle
    public var tlhPartners: [String: String]     // primary ticker -> partner ticker
    public init(domesticCore: Vehicle, domesticMid: Vehicle, domesticSmall: Vehicle, developedCore: Vehicle, emergingCore: Vehicle, tlhPartners: [String: String]) {
        self.domesticCore = domesticCore; self.domesticMid = domesticMid; self.domesticSmall = domesticSmall
        self.developedCore = developedCore; self.emergingCore = emergingCore; self.tlhPartners = tlhPartners
    }
}

/// The tactical sector-overlay policy (from src/sector-tilt-module.ts). Kept
/// small: this is the weakest-evidence component and is budgeted accordingly.
public struct TiltPolicy: Sendable, Hashable {
    public var enabled: Bool
    public var mode: String
    public var coreShareOfEquityBps: Bps
    public var maxTotalAbsoluteDeviationBps: Bps
    public var maxSingleSectorDeviationBps: Bps
    public var maxLookThroughSectorBps: Bps
    public var restrictToTreatments: [AccountTaxTreatment]
    public var activeTilts: [Tilt]
    public init(enabled: Bool, mode: String, coreShareOfEquityBps: Bps, maxTotalAbsoluteDeviationBps: Bps, maxSingleSectorDeviationBps: Bps, maxLookThroughSectorBps: Bps, restrictToTreatments: [AccountTaxTreatment], activeTilts: [Tilt]) {
        self.enabled = enabled; self.mode = mode; self.coreShareOfEquityBps = coreShareOfEquityBps
        self.maxTotalAbsoluteDeviationBps = maxTotalAbsoluteDeviationBps
        self.maxSingleSectorDeviationBps = maxSingleSectorDeviationBps
        self.maxLookThroughSectorBps = maxLookThroughSectorBps
        self.restrictToTreatments = restrictToTreatments; self.activeTilts = activeTilts
    }
}
