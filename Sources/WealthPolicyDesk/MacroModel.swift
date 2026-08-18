//  MacroModel.swift
//  WealthPolicyDesk
//
//  The macro / business-cycle model — increment 1 of the CME track. It answers
//  one question: what INNING is the US cycle in? It reads a dated, sourced
//  snapshot of OBSERVABLE market/labor data (curve, credit, valuation, real
//  rates, the Sahm trigger) and maps it, through transparent rules, to a cycle
//  phase (Early · Mid · Late · Recession), an inning (1–9), and recession odds.
//
//  This is a REGIME / CONTEXT read, never a market-timing trade. Downstream it
//  will condition the capital-market expectations (mean-reversion, correlations)
//  and inform which sectors a tactical tilt favors — but it does NOT set the
//  forecast-free strategic target. Every signal is shown with its reading and
//  which way it leans, so the inning is auditable, not a black box. The snapshot
//  is a point-in-time input to VERIFY before client use — the app stays offline;
//  the numbers are refreshed out-of-band (FRED / Treasury / a market source).

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
        case .early: return "early"
        case .neutral: return "neutral"
        case .late: return "late"
        case .recession: return "recession"
        }
    }
}

/// One observable indicator, its reading, and which cycle phase it leans toward.
public struct MacroSignal: Identifiable, Sendable, Hashable {
    public var name: String
    public var reading: String
    public var lean: SignalLean
    public var note: String
    public var id: String { name }
    public init(_ name: String, _ reading: String, _ lean: SignalLean, _ note: String) {
        self.name = name; self.reading = reading; self.lean = lean; self.note = note
    }
}

/// A dated, sourced snapshot of the observable macro inputs. Refreshed out-of-band.
public struct MacroSnapshot: Sendable, Hashable {
    public var asOf: IsoDate
    public var source: String
    public var termSpread10y3mBps: Bps    // 10y − 3m Treasury; <0 = inverted
    public var realRate10yBps: Bps        // 10y TIPS real yield
    public var breakevenBps: Bps          // 10y breakeven inflation
    public var hyOasBps: Bps              // ICE BofA US High-Yield OAS
    public var unemploymentBps: Bps       // U-3 rate (430 = 4.3%)
    public var sahmBps: Bps               // Sahm real-time indicator (50 = 0.50 trigger)
    public var cape: Double               // Shiller CAPE
    public var activityZ: Double          // coincident activity, z-score (0 = trend, <0 below)
    public init(asOf: IsoDate, source: String, termSpread10y3mBps: Bps, realRate10yBps: Bps, breakevenBps: Bps, hyOasBps: Bps, unemploymentBps: Bps, sahmBps: Bps, cape: Double, activityZ: Double) {
        self.asOf = asOf; self.source = source; self.termSpread10y3mBps = termSpread10y3mBps
        self.realRate10yBps = realRate10yBps; self.breakevenBps = breakevenBps; self.hyOasBps = hyOasBps
        self.unemploymentBps = unemploymentBps; self.sahmBps = sahmBps; self.cape = cape; self.activityZ = activityZ
    }
}

/// The model's read: phase, inning, recession odds, and the audit trail of signals.
public struct MacroRegime: Sendable, Hashable {
    public var phase: CyclePhase
    public var inning: Int            // 1–9 (recession is "extra innings")
    public var cycleScore: Int        // 0 (early) … 100 (late)
    public var recessionOddsBps: Bps
    public var signals: [MacroSignal]
    public var headline: String
    public var asOf: IsoDate
    public var source: String
}

public extension Engine {
    /// Map an observable snapshot to a cycle phase, inning, and recession odds
    /// through transparent, auditable rules. Late-leaning signals push the cycle
    /// score up; the Sahm trigger and deep stress flip it to recession outright.
    static func macroRegime(_ s: MacroSnapshot) -> MacroRegime {
        var signals: [MacroSignal] = []
        var score = 50            // 50 = mid; drifts toward 0 (early) or 100 (late)
        var odds = 5              // recession-odds accumulator, bps → later ×100

        // 1) Yield curve — the premier leading signal.
        let curve = s.termSpread10y3mBps
        if curve < 0 {
            score += 22; odds += min(30, -curve / 5)
            signals.append(.init("Yield curve (10y−3m)", "\(Fmt.pctBps(curve)) — inverted", .recession, "Inversion is the classic ~12-month recession lead."))
        } else if curve < 50 {
            score += 12; odds += 8
            signals.append(.init("Yield curve (10y−3m)", "\(Fmt.pctBps(curve)) — flat", .late, "Flattening front end: policy is restrictive, late-cycle."))
        } else if curve <= 150 {
            signals.append(.init("Yield curve (10y−3m)", "\(Fmt.pctBps(curve)) — positive", .neutral, "Upward-sloping: no front-end recession warning."))
        } else {
            score -= 18
            signals.append(.init("Yield curve (10y−3m)", "\(Fmt.pctBps(curve)) — steep", .early, "A steep curve typically follows a trough — early cycle."))
        }

        // 2) Labor — the Sahm real-time recession trigger.
        if s.sahmBps >= 50 {
            odds += 60
            signals.append(.init("Labor (Sahm)", "\(Fmt.pctBps(s.sahmBps)) — TRIGGERED", .recession, "≥0.50: unemployment rising fast — a recession is likely underway."))
        } else if s.sahmBps >= 30 {
            score += 12; odds += 15
            signals.append(.init("Labor (Sahm)", "\(Fmt.pctBps(s.sahmBps)) — softening", .late, "Approaching the 0.50 trigger — watch the labor market."))
        } else {
            signals.append(.init("Labor (Sahm)", "\(Fmt.pctBps(s.sahmBps)) — healthy", .neutral, "Well below the 0.50 trigger; no labor recession signal."))
        }

        // 3) Credit spreads — stress vs. complacency.
        if s.hyOasBps > 600 {
            odds += 22
            signals.append(.init("Credit (HY OAS)", "\(Fmt.pctBps(s.hyOasBps)) — wide", .recession, "Stress: spreads this wide accompany or precede recessions."))
        } else if s.hyOasBps >= 450 {
            score += 10; odds += 8
            signals.append(.init("Credit (HY OAS)", "\(Fmt.pctBps(s.hyOasBps)) — widening", .late, "Credit tightening — late-cycle deterioration."))
        } else {
            score += 8
            signals.append(.init("Credit (HY OAS)", "\(Fmt.pctBps(s.hyOasBps)) — tight", .late, "Tight spreads = benign now, but late-cycle complacency."))
        }

        // 4) Equity valuation — a slow-moving late-cycle tell.
        if s.cape > 35 {
            score += 12
            signals.append(.init("Equity valuation (CAPE)", String(format: "%.1f — expensive", s.cape), .late, "Stretched valuations lower forward returns; a late-cycle marker."))
        } else if s.cape >= 26 {
            score += 5
            signals.append(.init("Equity valuation (CAPE)", String(format: "%.1f — elevated", s.cape), .late, "Above its long-run median."))
        } else if s.cape >= 18 {
            signals.append(.init("Equity valuation (CAPE)", String(format: "%.1f — fair", s.cape), .neutral, "Near its long-run median."))
        } else {
            score -= 8
            signals.append(.init("Equity valuation (CAPE)", String(format: "%.1f — cheap", s.cape), .early, "Cheap valuations raise forward returns — often post-trough."))
        }

        // 5) Real policy rate — accommodative vs. restrictive.
        if s.realRate10yBps >= 180 {
            score += 8
            signals.append(.init("Real policy rate (10y)", "\(Fmt.pctBps(s.realRate10yBps)) — restrictive", .late, "Positive real rates lean against growth — late-cycle."))
        } else if s.realRate10yBps >= 80 {
            signals.append(.init("Real policy rate (10y)", "\(Fmt.pctBps(s.realRate10yBps)) — neutral", .neutral, "A roughly neutral real rate."))
        } else {
            score -= 8; odds += 3
            signals.append(.init("Real policy rate (10y)", "\(Fmt.pctBps(s.realRate10yBps)) — easy", .early, "Low/negative real rates support recovery — early cycle."))
        }

        // 6) Growth / activity trend.
        if s.activityZ < -0.5 {
            score += 12; odds += 20
            signals.append(.init("Activity trend", String(format: "z = %+.1f — below trend", s.activityZ), .late, "Growth decelerating below trend — late/into recession."))
        } else if s.activityZ > 0.5 {
            score -= 10
            signals.append(.init("Activity trend", String(format: "z = %+.1f — above trend", s.activityZ), .early, "Growth accelerating above trend — early/mid expansion."))
        } else {
            signals.append(.init("Activity trend", String(format: "z = %+.1f — near trend", s.activityZ), .neutral, "Growth around trend."))
        }

        // Resolve phase, inning, odds.
        let recessionOdds = min(9500, max(200, odds * 100))
        score = min(100, max(0, score))
        let phase: CyclePhase
        if recessionOdds >= 5000 || s.sahmBps >= 50 { phase = .recession }
        else if score < 35 { phase = .early }
        else if score <= 65 { phase = .mid }
        else { phase = .late }
        let inning = min(9, max(1, 1 + Int((Double(score) / 100.0 * 8.0).rounded())))

        let headline: String
        switch phase {
        case .recession: headline = "The coincident data is contracting — the cycle has turned. Recession odds \(Fmt.pctBps(recessionOdds))."
        case .late: headline = "Late-cycle expansion — inning \(inning). No firm recession signal yet, but the late-leaning signals dominate."
        case .mid: headline = "Mid expansion — inning \(inning). Growth intact, policy near neutral, no cycle extreme in view."
        case .early: headline = "Early cycle — inning \(inning). The signals lean toward recovery off a trough."
        }

        return MacroRegime(phase: phase, inning: inning, cycleScore: score, recessionOddsBps: recessionOdds,
                           signals: signals, headline: headline, asOf: s.asOf, source: s.source)
    }
}
