//  ExposureLookthrough.swift
//  WealthPolicyDesk
//
//  The country×sector LOOK-THROUGH. A per-sleeve or per-axis view hides joint
//  concentration: a client can look diversified by sector AND by region yet hold
//  a huge US·Technology cell once you add the index weight, a Tech sector tilt, and
//  a concentrated single stock together. This decomposes every EQUITY holding into
//  (country × sector) cells, aggregates them as a share of total equity, and checks
//  the cell / sector / country / EM limits the per-axis view can't see.
//
//  Reference weights are a dated snapshot (≈2026) to VERIFY. Intl/EM cells use the
//  geo × sector marginal product (independence) — a documented approximation; US
//  holdings, sector SPDRs, and concentrated single stocks land in exact cells, which
//  is where the interesting concentration usually is.

import Foundation

enum LookThrough {
    // US large-cap sector weights (≈ S&P 500, bps of 10000 — verify).
    static let usLargeSector: [Sector: Bps] = [
        .technology: 3000, .financials: 1300, .healthcare: 1100, .consumerDiscretionary: 1000,
        .communicationServices: 900, .industrials: 800, .consumerStaples: 600, .energy: 400,
        .materials: 400, .realEstate: 250, .utilities: 250]
    // US mid/small sector weights.
    static let usSmallSector: [Sector: Bps] = [
        .industrials: 1900, .financials: 1600, .technology: 1300, .healthcare: 1200,
        .consumerDiscretionary: 1100, .realEstate: 900, .materials: 600, .energy: 500,
        .consumerStaples: 400, .utilities: 300, .communicationServices: 200]
    // International developed sector weights.
    static let intlSector: [Sector: Bps] = [
        .financials: 1900, .industrials: 1600, .healthcare: 1200, .consumerDiscretionary: 1100,
        .technology: 1000, .consumerStaples: 800, .materials: 700, .communicationServices: 500,
        .energy: 500, .utilities: 400, .realEstate: 300]
    // Emerging-market sector weights.
    static let emSector: [Sector: Bps] = [
        .technology: 2300, .financials: 2000, .consumerDiscretionary: 1300, .communicationServices: 1000,
        .materials: 800, .industrials: 700, .energy: 600, .consumerStaples: 500, .healthcare: 400,
        .realEstate: 200, .utilities: 200]
    // International developed country weights (FTSE Developed ex-US, incl. Canada).
    static let intlGeo: [(geo: String, bps: Bps)] = [
        ("Japan", 2100), ("UK", 1300), ("Canada", 900), ("France", 900), ("Switzerland", 800),
        ("Germany", 800), ("Australia", 700), ("Netherlands", 400), ("Other developed", 2100)]
    // Emerging-market country weights (FTSE EM — Korea classified developed).
    static let emGeo: [(geo: String, bps: Bps)] = [
        ("China", 3000), ("India", 2000), ("Taiwan", 2000), ("Brazil", 500),
        ("Saudi Arabia", 400), ("South Africa", 300), ("Other EM", 1800)]

    // Total-market and large-cap US funds carry the large-cap sector profile. VTI is
    // Vanguard Total Stock Market — cap-weighted, ~82% large — so it tracks usLargeSector,
    // NOT the mid/small table (misfiling it there understated the headline US·Tech cell).
    static let usBroad: Set<String> = ["VOO", "SPLG", "VLUE", "MTUM", "QUAL", "USMV", "VUG", "SPY", "IVV", "VTI"]
    static let usSmall: Set<String> = ["VO", "VB"]   // VO = mid-cap, VB = small-cap

    // Region-blend fractions for multi-region funds (dated ≈2026 snapshot — verify).
    // Without these, a total-international fund's EM sleeve is misattributed to developed
    // countries and vanishes from the EM ceiling.
    static let vxusEmFrac = 0.25    // Total International ex-US (VXUS) emerging-market share
    static let vssEmFrac  = 0.20    // ex-US Small-Cap (VSS) emerging-market share
    static let vtUsFrac   = 0.63    // Total World (VT) US share; its ex-US remainder is vxusEmFrac EM
}

public struct ExposureCell: Identifiable, Sendable, Hashable {
    public var geo: String
    public var sector: Sector
    public var bps: Bps                 // share of total equity
    public var id: String { "\(geo)|\(sector.rawValue)" }
}

public struct ExposureBreach: Identifiable, Sendable, Hashable {
    public var id: String
    public var severity: Severity
    public var label: String
    public var valueBps: Bps
    public var limitBps: Bps
    public var detail: String
}

public struct ExposureView: Sendable {
    public var equityUsd: Usd
    public var cells: [ExposureCell]           // non-zero, sorted desc
    public var bySector: [(sector: Sector, bps: Bps)]
    public var byGeo: [(geo: String, bps: Bps)]
    public var emBps: Bps
    public var breaches: [ExposureBreach]
    public var asOf: IsoDate
}

public extension Engine {

    /// Decompose the household's equity into country×sector cells (bps of equity).
    static func exposureMatrix(_ h: Household, asOf: IsoDate = "2026-08-15") -> ExposureView {
        var cellUsd: [String: (geo: String, sector: Sector, usd: Usd)] = [:]
        func add(_ geo: String, _ sector: Sector, _ usd: Usd) {
            guard usd > 0 else { return }
            let key = "\(geo)|\(sector.rawValue)"
            var e = cellUsd[key] ?? (geo, sector, 0)
            e.usd += usd; cellUsd[key] = e
        }
        // Spread a dollar amount across a geo×sector product (the independence approximation).
        // Both tables sum to 10000 bps, so the full `usd` is conserved.
        func spread(_ usd: Usd, _ geos: [(geo: String, bps: Bps)], _ secs: [Sector: Bps]) {
            for (g, gw) in geos { for (s, sw) in secs {
                add(g, s, usd * Double(gw) / 10000 * Double(sw) / 10000) } }
        }
        // Spread a US dollar amount across a US sector table (single geo).
        func spreadUS(_ usd: Usd, _ secs: [Sector: Bps]) {
            for (s, w) in secs { add("US", s, usd * Double(w) / 10000) }
        }
        var equityUsd: Usd = 0
        for p in h.positions where isEquity(p) {
            let v = p.marketValueUsd
            guard v > 0 else { continue }
            equityUsd += v
            let t = p.ticker.uppercased()
            let (dev, em) = (LookThrough.vxusEmFrac, LookThrough.vssEmFrac)
            if let sector = Sector.fromSpdr(t) {                     // a sector SPDR → one exact cell
                add("US", sector, v)
            } else if t == "VNQ" || t == "IYR" {
                add("US", .realEstate, v)
            } else if LookThrough.usBroad.contains(t) {              // total-market / large-cap US
                spreadUS(v, LookThrough.usLargeSector)
            } else if LookThrough.usSmall.contains(t) {              // mid/small US
                spreadUS(v, LookThrough.usSmallSector)
            } else if t == "VEA" || t == "IEFA" {                    // developed ex-US
                spread(v, LookThrough.intlGeo, LookThrough.intlSector)
            } else if t == "VWO" || t == "IEMG" {                    // emerging markets
                spread(v, LookThrough.emGeo, LookThrough.emSector)
            } else if t == "VXUS" || t == "IXUS" {                   // total international ≈ developed + EM
                spread(v * (1 - dev), LookThrough.intlGeo, LookThrough.intlSector)
                spread(v * dev, LookThrough.emGeo, LookThrough.emSector)
            } else if t == "VSS" {                                   // ex-US small ≈ developed + EM
                spread(v * (1 - em), LookThrough.intlGeo, LookThrough.intlSector)
                spread(v * em, LookThrough.emGeo, LookThrough.emSector)
            } else if t == "VT" || t == "VTWAX" {                    // total world ≈ US + ex-US (dev + EM)
                let us = LookThrough.vtUsFrac
                spreadUS(v * us, LookThrough.usLargeSector)
                spread(v * (1 - us) * (1 - dev), LookThrough.intlGeo, LookThrough.intlSector)
                spread(v * (1 - us) * dev, LookThrough.emGeo, LookThrough.emSector)
            } else if let sector = p.effectiveSector {               // concentrated single stock, known sector → one exact cell
                add("US", sector, v)                                 // NOTE: single names are assumed US-domiciled (no geo on Position)
            } else {                                                 // unknown sector → market-like US spread, never an arbitrary Tech dump
                spreadUS(v, LookThrough.usLargeSector)
            }
        }
        let total = max(1, equityUsd)
        // USD is conserved exactly; the per-cell bps are each independently rounded and
        // sub-half-bp cells drop, so the rounded cells sum to ~10000 ±a few bps (immaterial,
        // and consistent across the sector/geo marginals below).
        let cells = cellUsd.values
            .map { ExposureCell(geo: $0.geo, sector: $0.sector, bps: ($0.usd / total).bps) }
            .filter { $0.bps > 0 }.sorted { $0.bps > $1.bps }
        var bySector: [Sector: Bps] = [:], byGeo: [String: Bps] = [:]
        for c in cells { bySector[c.sector, default: 0] += c.bps; byGeo[c.geo, default: 0] += c.bps }
        let emGeoNames = Set(LookThrough.emGeo.map { $0.geo })
        let emBps = byGeo.filter { emGeoNames.contains($0.key) }.reduce(0) { $0 + $1.value }

        return ExposureView(
            equityUsd: equityUsd, cells: cells,
            bySector: Sector.allCases.map { (s: $0, bps: bySector[$0] ?? 0) }.filter { $0.bps > 0 }.sorted { $0.bps > $1.bps },
            byGeo: byGeo.map { (geo: $0.key, bps: $0.value) }.sorted { $0.bps > $1.bps },
            emBps: emBps, breaches: evaluateExposure(cells: cells, bySector: bySector, byGeo: byGeo, emBps: emBps),
            asOf: asOf)
    }

    /// Check the look-through cells + marginals against the matrix constraints.
    private static func evaluateExposure(cells: [ExposureCell], bySector: [Sector: Bps], byGeo: [String: Bps], emBps: Bps) -> [ExposureBreach] {
        var out: [ExposureBreach] = []
        for mc in Seed.matrixConstraints {
            switch mc.scope {
            case .cell:
                for c in cells where c.bps > mc.limitBps {
                    out.append(ExposureBreach(id: "cell-\(c.id)", severity: mc.severity,
                        label: "\(c.geo) · \(c.sector.label)", valueBps: c.bps, limitBps: mc.limitBps,
                        detail: "\(Fmt.pctBps(c.bps)) of equity in one country×sector cell — above the \(Fmt.pctBps(mc.limitBps)) cap. The joint concentration a per-axis view misses."))
                }
            case .sectorMargin:
                for (s, v) in bySector where v > mc.limitBps {
                    out.append(ExposureBreach(id: "sector-\(s.rawValue)", severity: mc.severity,
                        label: s.label, valueBps: v, limitBps: mc.limitBps,
                        detail: "\(Fmt.pctBps(v)) of equity in \(s.label), inclusive of the country-fund contribution — above the \(Fmt.pctBps(mc.limitBps)) look-through cap."))
                }
            case .geoMargin:
                // single-country cap applies to non-US countries; EM ceiling to the EM bloc.
                if mc.id == "em_ceiling" {
                    if emBps > mc.limitBps {
                        out.append(ExposureBreach(id: "em", severity: mc.severity, label: "Emerging markets",
                            valueBps: emBps, limitBps: mc.limitBps,
                            detail: "\(Fmt.pctBps(emBps)) of equity in EM — above the \(Fmt.pctBps(mc.limitBps)) ceiling."))
                    }
                } else {
                    for (g, v) in byGeo where g != "US" && v > mc.limitBps {
                        out.append(ExposureBreach(id: "geo-\(g)", severity: mc.severity, label: g,
                            valueBps: v, limitBps: mc.limitBps,
                            detail: "\(Fmt.pctBps(v)) of equity in a single country (\(g)) — above the \(Fmt.pctBps(mc.limitBps)) cap."))
                    }
                }
            case .total: break
            }
        }
        return out.sorted { $0.valueBps > $1.valueBps }
    }
}
