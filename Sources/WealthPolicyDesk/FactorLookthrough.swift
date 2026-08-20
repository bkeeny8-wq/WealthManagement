//  FactorLookthrough.swift
//  WealthPolicyDesk
//
//  The FACTOR look-through — the systematic-risk analog of the country×sector matrix.
//  A book can look diversified by sector AND region yet carry a large unintended
//  factor bet: crowded into momentum, short value (i.e. long growth), or piled into
//  low-vol defensives. This decomposes every equity holding into its implied loadings
//  on a small factor set, weights them by share of equity, and reports the NET tilt
//  each factor carries relative to the cap-weighted market (which is 0 by construction).
//
//  This is DESCRIPTIVE — a structural characteristic of what the holdings are, like
//  sector or country — not a return forecast. It never feeds resolveTargets; it is an
//  analysis lens only. Loadings are a dated snapshot (≈2026) to VERIFY. Broad-market
//  index funds load 0 on every factor by definition; a concentrated single name inherits
//  its sector's factor character (so a tech-heavy single-name book reads as the
//  growth/momentum bet it is), which is an approximation — an idiosyncratic name can
//  diverge from its sector average.

import Foundation

public enum FactorAxis: String, CaseIterable, Sendable, Hashable {
    case value, momentum, quality, size, lowVol

    public var label: String {
        switch self {
        case .value: return "Value"
        case .momentum: return "Momentum"
        case .quality: return "Quality"
        case .size: return "Size"
        case .lowVol: return "Low volatility"
        }
    }
    /// The name of the positive (long) end of the axis.
    public var longName: String {
        switch self {
        case .value: return "value"
        case .momentum: return "momentum"
        case .quality: return "quality"
        case .size: return "small-cap"
        case .lowVol: return "defensive"
        }
    }
    /// The name of the negative (short) end of the axis.
    public var shortName: String {
        switch self {
        case .value: return "growth"
        case .momentum: return "laggards"
        case .quality: return "low-quality"
        case .size: return "mega-cap"
        case .lowVol: return "high-beta"
        }
    }
}

enum FactorRef {
    // Pure/tilted factor funds — loadings relative to the market (~[-1, 1]; a single-
    // factor ETF loads ≈0.9 on its factor). Dated ≈2026 — verify.
    static let byTicker: [String: [FactorAxis: Double]] = [
        "VLUE": [.value: 0.9],
        "MTUM": [.momentum: 0.9],
        "QUAL": [.quality: 0.9],
        "USMV": [.lowVol: 0.9, .quality: 0.2],
        "VO":   [.size: 0.4], "IJH": [.size: 0.4],               // mid-cap (IJH ≡ VO, its TLH partner)
        "VB":   [.size: 0.8], "IJR": [.size: 0.8],               // small-cap (IJR ≡ VB, its TLH partner)
        "IWM":  [.size: 0.8],                                    // Russell 2000 — the "Small-cap (Size)" sleeve's instrument
        "VUG":  [.value: -0.6, .quality: 0.2, .momentum: 0.2, .size: -0.15],  // growth = anti-value, large/mega-cap
        "VNQ":  [.value: 0.2], "IYR": [.value: 0.2],             // REITs lean value
        "VEA":  [.value: 0.15], "VXUS": [.value: 0.15], "IEFA": [.value: 0.15], "IXUS": [.value: 0.15],
        "VWO":  [.value: 0.25, .size: 0.1], "IEMG": [.value: 0.25, .size: 0.1],
        "VSS":  [.size: 0.5, .value: 0.15],
    ]
    // Sector SPDRs carry factor character (mapped via Sector.fromSpdr).
    // lowVol is signed: high-beta/cyclical sectors carry a negative (high-beta) loading so
    // the axis is genuinely bidirectional and a growth/cyclical book reads as high-beta.
    static let bySector: [Sector: [FactorAxis: Double]] = [
        .technology:             [.momentum: 0.3, .value: -0.4, .quality: 0.2, .lowVol: -0.2],
        .communicationServices:  [.momentum: 0.2, .value: -0.1, .lowVol: -0.1],
        .consumerDiscretionary:  [.momentum: 0.2, .value: -0.1, .lowVol: -0.15],
        .consumerStaples:        [.lowVol: 0.4, .quality: 0.3, .value: 0.1],
        .utilities:              [.lowVol: 0.5, .value: 0.3],
        .energy:                 [.value: 0.5, .lowVol: -0.15],
        .financials:             [.value: 0.4],
        .healthcare:             [.quality: 0.2, .lowVol: 0.2],
        .industrials:            [.value: 0.1],
        .materials:              [.value: 0.3, .lowVol: -0.1],
        .realEstate:             [.value: 0.2],
    ]

    /// A holding's factor loadings: ticker table first, then sector SPDR, then a single
    /// name inherits its sector's factor character (so a concentrated tech position reads
    /// as the growth/momentum bet it is — an approximation; an idiosyncratic name may
    /// differ from its sector). Broad-market index funds have no sector → market (0).
    static func loading(for p: Position) -> [FactorAxis: Double] {
        let t = p.ticker.uppercased()
        if let byT = byTicker[t] { return byT }
        if let s = Sector.fromSpdr(t) { return bySector[s] ?? [:] }
        if let s = p.effectiveSector { return bySector[s] ?? [:] }   // single stock → its sector's factor character
        return [:]                                                   // broad-market index / unknown → market (0)
    }
}

public struct FactorTilt: Identifiable, Sendable, Hashable {
    public var axis: FactorAxis
    public var tilt: Double                 // market-relative, ~[-1, 1]
    public var id: String { axis.rawValue }
    public var notable: Bool { abs(tilt) >= 0.20 }
}

public struct FactorTiltView: Sendable {
    public var equityUsd: Usd
    public var tilts: [FactorTilt]          // FactorAxis.allCases order
    public var summary: String              // plain-language net bet
    public var asOf: IsoDate
}

public extension Engine {

    /// The net factor tilt the equity book implies, weighted by share of equity.
    static func factorExposure(_ h: Household, asOf: IsoDate = Engine.planningAsOf) -> FactorTiltView {
        var equityUsd: Usd = 0
        var usdLoad: [FactorAxis: Usd] = [:]        // Σ marketValue × loading
        for p in h.positions where isEquity(p) {
            let v = p.marketValueUsd
            guard v > 0 else { continue }
            equityUsd += v
            for (f, l) in FactorRef.loading(for: p) { usdLoad[f, default: 0] += v * l }
        }
        let total = max(1, equityUsd)
        let tilts = FactorAxis.allCases.map { FactorTilt(axis: $0, tilt: (usdLoad[$0] ?? 0) / total) }

        // Plain-language read: name the directional end of each material tilt, biggest first.
        let ranked = tilts.filter { abs($0.tilt) >= 0.08 }.sorted { abs($0.tilt) > abs($1.tilt) }
        let summary: String
        if equityUsd <= 0 {
            summary = "No equity to decompose."
        } else if ranked.isEmpty {
            summary = "Close to the market on every factor — no material systematic tilt."
        } else {
            let names = ranked.prefix(3).map { $0.tilt >= 0 ? $0.axis.longName : $0.axis.shortName }
            summary = "Leans " + Self.joinList(names) + " — the systematic bet a sleeve-label view misses."
        }
        return FactorTiltView(equityUsd: equityUsd, tilts: tilts, summary: summary, asOf: asOf)
    }

    /// "a", "a and b", or "a, b, and c".
    private static func joinList(_ xs: [String]) -> String {
        switch xs.count {
        case 0: return ""
        case 1: return xs[0]
        case 2: return "\(xs[0]) and \(xs[1])"
        default: return xs.dropLast().joined(separator: ", ") + ", and " + xs.last!
        }
    }
}
