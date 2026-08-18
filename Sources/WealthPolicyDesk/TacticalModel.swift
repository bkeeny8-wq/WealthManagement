//  TacticalModel.swift
//  WealthPolicyDesk
//
//  The equity & bond SENTIMENT engine — the second forward-looking model. It
//  scores tactical tilt candidates (sectors, factors, regions, fixed-income
//  slices) on four dimensions — Value (what's cheap), Momentum (when to enter),
//  Sentiment (contrarian only at extremes), and Cycle fit (does the macro inning
//  favor it) — and nets them into an overweight / neutral / underweight stance
//  with a conviction and a thesis.
//
//  Its output feeds the app's ALREADY-budgeted tactical TILT layer (deviation
//  cap + mandatory thesis + review date), never the forecast-free strategic
//  target. Tactical timing is weak-evidence; the discipline (small budget,
//  composite signals, cycle-conditioning) is the product, the signals are
//  commodities. Values are a dated snapshot to VERIFY; the app stays offline.

import Foundation

public enum TiltStance: String, Sendable, Hashable {
    case overweight, leanOver, neutral, leanUnder, underweight
    public var label: String {
        switch self {
        case .overweight: return "Overweight"
        case .leanOver: return "Lean overweight"
        case .neutral: return "Neutral"
        case .leanUnder: return "Lean underweight"
        case .underweight: return "Underweight"
        }
    }
    public var short: String {
        switch self {
        case .overweight: return "OW"
        case .leanOver: return "lean OW"
        case .neutral: return "—"
        case .leanUnder: return "lean UW"
        case .underweight: return "UW"
        }
    }
    /// The strong, action-threshold tilts (a governed overweight/underweight).
    public var isGoverned: Bool { self == .overweight || self == .underweight }
}

/// One scoring dimension of a tilt candidate. Score −2…+2 (+ argues to overweight).
public struct TiltDimension: Identifiable, Sendable, Hashable {
    public var name: String     // Value · Momentum · Sentiment · Cycle fit
    public var reading: String
    public var score: Int
    public var note: String
    public var id: String { name }
    public init(_ name: String, _ reading: String, _ score: Int, _ note: String) {
        self.name = name; self.reading = reading; self.score = score; self.note = note
    }
}

/// A tactical tilt candidate: a tradable exposure scored across the four dimensions.
public struct TacticalTilt: Identifiable, Sendable, Hashable {
    public var name: String
    public var group: String
    public var ticker: String
    public var thesis: String
    public var dimensions: [TiltDimension]
    public var id: String { name }
    public init(_ name: String, group: String, ticker: String, thesis: String, dimensions: [TiltDimension]) {
        self.name = name; self.group = group; self.ticker = ticker; self.thesis = thesis; self.dimensions = dimensions
    }
    /// Net of the four dimension scores (−8…+8).
    public var netScore: Int { dimensions.reduce(0) { $0 + $1.score } }
    /// A five-tier stance so the chip never contradicts a directional thesis: a
    /// strong ±3 nets a governed OVER/UNDERWEIGHT (the action bar), ±1…2 a LEAN,
    /// and only a genuinely flat 0 reads NEUTRAL. Every non-zero net gets a
    /// directional chip — matching what the thesis prose already concluded.
    public var stance: TiltStance {
        switch netScore {
        case 3...:        return .overweight
        case 1...2:       return .leanOver
        case (-2)...(-1): return .leanUnder
        default:          return netScore <= -3 ? .underweight : .neutral
        }
    }
    public var conviction: String {
        switch abs(netScore) { case 5...: return "High"; case 3...4: return "Moderate"; default: return "Low" }
    }
    public func dim(_ n: String) -> TiltDimension? { dimensions.first { $0.name == n } }
}

public extension Engine {
    /// Average stance across a set of candidates — for the broad equity / bond gauges.
    static func tiltAggregate(_ tilts: [TacticalTilt]) -> (net: Double, stance: TiltStance) {
        guard !tilts.isEmpty else { return (0, .neutral) }
        let avg = Double(tilts.reduce(0) { $0 + $1.netScore }) / Double(tilts.count)
        let stance: TiltStance = avg >= 1.0 ? .overweight : (avg <= -1.0 ? .underweight : .neutral)
        return (avg, stance)
    }
}
