//  MacroModel.swift
//  WealthPolicyDesk
//
//  The macro / business-cycle model — the CME track's foundation. It answers one
//  question: what INNING is the US cycle in? A declarative CATALOG of ~60
//  observable indicators (each mapping its current value, through explicit bands,
//  to a cycle lean) is aggregated by DIFFUSION — the importance-weighted balance
//  of early-vs-late leans across the whole board — into a cycle phase (Early ·
//  Mid · Late · Recession), an inning (1–9), recession odds, and a confidence
//  from how much the board agrees. This is how CFNAI and the LEI diffusion index
//  work: no single indicator can jerk the read.
//
//  A REGIME / CONTEXT read, never a market-timing trade. It will condition the
//  capital-market expectations and which sectors a tactical tilt favors — it does
//  NOT set the forecast-free strategic target. Every indicator is observable and
//  shown with its band, so the inning is auditable. Values are a dated snapshot to
//  VERIFY and refresh out-of-band; the app stays offline.

import Foundation

public enum CyclePhase: String, Sendable, Hashable {
    case early, mid, late, recession
    public var label: String {
        switch self {
        case .early: return "Early — recovery"
        case .mid: return "Mid — expansion"
        case .late: return "Late — slowing"
        case .recession: return "Recession — contraction"
        }
    }
}

public enum SignalLean: String, Sendable, Hashable {
    case early, neutral, late, recession
    public var label: String {
        switch self {
        case .early: return "early"; case .neutral: return "neutral"
        case .late: return "late"; case .recession: return "recession"
        }
    }
}

public enum MacroCategory: String, CaseIterable, Sendable, Hashable {
    case growth = "Growth & activity"
    case labor = "Labor"
    case housing = "Housing"
    case consumer = "Consumer"
    case inflation = "Inflation"
    case rates = "Rates & policy"
    case money = "Money & liquidity"
    case credit = "Credit"
    case market = "Equity & market"
}

/// Where an indicator sits in the cycle's timing chain. The pedagogical payoff:
/// leading signals roll over first, so when the leading group leans late while
/// the coincident group still reads steady, that divergence *is* the turn — a
/// signal the flat, all-in-one board hides.
public enum MacroTiming: String, CaseIterable, Sendable, Hashable {
    case leading = "Leading"
    case coincident = "Coincident"
    case lagging = "Lagging"
    /// One-line role in the cycle read (shown under the group header).
    public var blurb: String {
        switch self {
        case .leading:    return "move before the cycle turns"
        case .coincident: return "where the economy is right now"
        case .lagging:    return "confirm the trend after the fact"
        }
    }
}

public enum MacroUnit: String, Sendable, Hashable { case pct, bps, index, zscore, levelK, ratio, count }

/// A value threshold: at or below `upTo`, the indicator leans `lean` (labeled).
public struct MacroBand: Sendable, Hashable {
    public var upTo: Double
    public var lean: SignalLean
    public var label: String
    public init(_ upTo: Double, _ lean: SignalLean, _ label: String) { self.upTo = upTo; self.lean = lean; self.label = label }
}

/// One observable indicator: its current value + the bands that map it to a lean.
public struct MacroIndicator: Identifiable, Sendable, Hashable {
    public var name: String
    public var category: MacroCategory
    public var value: Double
    public var unit: MacroUnit
    public var importance: Int    // 1–3 (3 = premier leading indicator)
    public var oddsWeight: Int    // added to recession odds when in its worst (recession) band
    public var timing: MacroTiming
    public var source: String
    public var descriptor: String
    public var bands: [MacroBand]
    public var id: String { name }
    public init(_ name: String, _ category: MacroCategory, _ value: Double, _ unit: MacroUnit, importance: Int, oddsWeight: Int, timing: MacroTiming = .coincident, source: String, descriptor: String, bands: [MacroBand]) {
        self.name = name; self.category = category; self.value = value; self.unit = unit
        self.importance = importance; self.oddsWeight = oddsWeight; self.timing = timing; self.source = source
        self.descriptor = descriptor; self.bands = bands
    }
    /// The current band (first whose upTo the value clears, ascending).
    public var band: MacroBand {
        let sorted = bands.sorted { $0.upTo < $1.upTo }
        return sorted.first { value <= $0.upTo } ?? sorted.last ?? MacroBand(.infinity, .neutral, "—")
    }
    public var lean: SignalLean { band.lean }
    public var reading: String {
        let v: String
        switch unit {
        case .pct: v = String(format: "%.1f%%", value)
        case .bps: v = "\(Int(value.rounded())) bp"
        case .index: v = String(format: "%.1f", value)
        case .zscore: v = String(format: "z %+.1f", value)
        case .levelK: v = "\(Int(value.rounded()))k"
        case .ratio: v = String(format: "%.2f", value)
        case .count: v = "\(Int(value.rounded()))"
        }
        return "\(v) — \(band.label)"
    }
    /// Provenance: a value machine-refreshed from a public series (source is a data id,
    /// e.g. a FRED series or multpl) vs authored and pending verification (source ==
    /// "estimate"). `generate_cme_snapshot.py` is the source of truth and keeps `source`
    /// honest — a row it cannot pull is left "estimate", never a stale series id.
    public var isMachineRefreshed: Bool { source != "estimate" && !source.isEmpty }
    /// A compact provenance tag for the board ("FRED", "multpl", or "est.").
    public var provenanceTag: String {
        if !isMachineRefreshed { return "est." }
        return source.contains("multpl") || source.lowercased().contains("shiller") ? "multpl" : "FRED"
    }
}

public struct MacroRegime: Sendable, Hashable {
    public var phase: CyclePhase
    public var inning: Int
    public var cycleScore: Int          // 0 (early) … 100 (late)
    public var recessionOddsBps: Bps
    public var earlyCount: Int
    public var neutralCount: Int
    public var lateCount: Int
    public var recessionCount: Int
    public var confidence: String
    public var indicators: [MacroIndicator]
    public var headline: String
    public var asOf: IsoDate
    public var source: String
    /// How many of the board's rows carry a machine-refreshed value (the rest are
    /// authored estimates awaiting verification).
    public var machineRefreshedCount: Int { indicators.filter { $0.isMachineRefreshed }.count }
}

public extension Engine {
    /// Aggregate the indicator board by DIFFUSION: the importance-weighted balance
    /// of early-vs-late leans → cycle score → inning; recession odds accrue only
    /// from indicators actually in a recession band; confidence reflects agreement.
    static func macroRegime(_ indicators: [MacroIndicator], asOf: IsoDate = Seed.macroDataAsOf, source: String = "FRED · US Treasury · market data (verify)") -> MacroRegime {
        let leanVal: [SignalLean: Double] = [.early: -1, .neutral: 0, .late: 1, .recession: 2]
        var wl = 0.0, ws = 0.0, odds = 5
        var early = 0, neutral = 0, late = 0, rec = 0
        var earlyW = 0.0, lateW = 0.0
        for ind in indicators {
            let w = Double(max(1, ind.importance))
            switch ind.lean {
            case .early: early += 1; earlyW += w
            case .neutral: neutral += 1
            case .late: late += 1; lateW += w
            case .recession: rec += 1; lateW += w; odds += ind.oddsWeight
            }
            wl += w * (leanVal[ind.lean] ?? 0); ws += w
        }
        let netLean = ws > 0 ? wl / ws : 0
        let cycleScore = min(100, max(0, Int((50 + 55 * netLean).rounded())))
        let recessionOdds = min(9500, max(200, odds * 100))

        let phase: CyclePhase
        if recessionOdds >= 5000 || rec >= 2 { phase = .recession }
        else if cycleScore < 35 { phase = .early }
        else if cycleScore <= 65 { phase = .mid }
        else { phase = .late }
        let inning = min(9, max(1, 1 + Int((Double(cycleScore) / 100.0 * 8.0).rounded())))

        let directionalW = earlyW + lateW
        let dominant = directionalW > 0 ? max(earlyW, lateW) / directionalW : 0
        let confidence: String
        if ws > 0 && directionalW / ws < 0.35 { confidence = "Low — mostly neutral" }
        else if dominant > 0.70 { confidence = "High — the board agrees" }
        else { confidence = "Moderate — a split board" }

        let split = "\(early) early · \(neutral) neutral · \(late) late\(rec > 0 ? " · \(rec) recession" : "")"
        let headline: String
        switch phase {
        case .recession:
            headline = "The board has turned — \(rec) indicators in recession territory, odds \(Fmt.pctBps(recessionOdds)). \(split)."
        case .late:
            headline = "Late-cycle — inning \(inning). Late-leaning signals carry the board (\(split)); watch for the direction indicators to confirm a turn."
        case .mid:
            headline = "Mid expansion — inning \(inning). A genuinely mixed board (\(split)): the real economy leans healthy while valuations, credit, and rates lean late — no directional turn."
        case .early:
            headline = "Early cycle — inning \(inning). The board leans toward recovery (\(split))."
        }

        return MacroRegime(phase: phase, inning: inning, cycleScore: cycleScore, recessionOddsBps: recessionOdds,
                           earlyCount: early, neutralCount: neutral, lateCount: late, recessionCount: rec,
                           confidence: confidence, indicators: indicators, headline: headline, asOf: asOf, source: source)
    }
}
