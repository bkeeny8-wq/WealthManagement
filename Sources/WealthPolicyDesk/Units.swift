//  Units.swift
//  WealthPolicyDesk
//
//  Primitive units, ported from the TypeScript policy layer's branded scalars.
//
//    Bps  — basis points, an Int. 10_000 bps = 100%. The source of truth stores
//           whole basis points (a 26% sleeve is `2600`), so we keep Int for
//           fidelity and readability and convert to a fraction only in math.
//    Usd  — US dollars, a Double.
//    IsoDate — a calendar date as "YYYY-MM-DD".
//
//  `Fmt` is the single place figures become strings, so the whole desk prints
//  money, percentages and basis points the same way.

import Foundation

public typealias Bps = Int
public typealias Usd = Double
public typealias IsoDate = String

public extension BinaryInteger {
    /// Basis points as a fraction: `2600.frac == 0.26`.
    var frac: Double { Double(self) / 10_000.0 }
}

public extension Double {
    /// A fraction expressed in basis points, rounded: `0.2634.bps == 2634`.
    var bps: Int { Int((self * 10_000.0).rounded()) }
    /// Clamp helper used throughout the engine.
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}

/// Formatting. Money uses grouped separators; percentages accept either a raw
/// fraction (`pct`) or whole basis points (`pctBps`).
public enum Fmt {

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    // MARK: money

    /// "$1,240,000" — whole dollars, grouped.
    public static func usd(_ x: Usd) -> String {
        let n = NSNumber(value: x.rounded())
        return "$" + (grouped.string(from: n) ?? String(format: "%.0f", x.rounded()))
    }

    /// Compact money for tight stat tiles: "$1.24M", "$980k", "$420".
    public static func usdShort(_ x: Usd) -> String {
        let a = abs(x)
        let sign = x < 0 ? "-" : ""
        switch a {
        case 1_000_000_000...: return sign + String(format: "$%.2fB", a / 1_000_000_000)
        case 1_000_000...:     return sign + String(format: "$%.2fM", a / 1_000_000)
        case 10_000...:        return sign + String(format: "$%.0fk", a / 1_000)
        case 1_000...:         return sign + String(format: "$%.1fk", a / 1_000)
        default:               return sign + "$" + String(format: "%.0f", a)
        }
    }

    /// Signed money, for deltas: "+$12,000" / "-$3,400".
    public static func usdSigned(_ x: Usd) -> String {
        (x >= 0 ? "+" : "-") + usd(abs(x))
    }

    // MARK: percentages

    /// A raw fraction as a percentage: `pct(0.263) == "26.3%"`.
    public static func pct(_ frac: Double, _ decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f%%", frac * 100)
    }

    /// Whole basis points as a percentage: `pctBps(2634) == "26.3%"`.
    public static func pctBps(_ b: Bps, _ decimals: Int = 1) -> String {
        pct(b.frac, decimals)
    }

    /// Signed percentage from a fraction: "+2.5%" / "-1.0%".
    public static func pctSigned(_ frac: Double, _ decimals: Int = 1) -> String {
        (frac >= 0 ? "+" : "") + pct(frac, decimals)
    }

    /// Basis points, labelled: `bps(300) == "300 bp"`.
    public static func bps(_ b: Bps) -> String { "\(b) bp" }

    /// Signed basis points: "+400 bp" / "-250 bp".
    public static func bpsSigned(_ b: Bps) -> String { (b >= 0 ? "+" : "") + "\(b) bp" }

    // MARK: misc

    public static func yrs(_ x: Double, _ decimals: Int = 1) -> String {
        String(format: "%.\(decimals)fy", x)
    }

    public static func x(_ x: Double, _ decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f×", x)
    }
}

/// A small severity type shared by every constraint set in the policy layer.
/// Mirrors the TS `severity: "hard" | "soft"`.
public enum Severity: String, CaseIterable, Sendable, Hashable {
    case hard
    case soft
}

/// A rule the engine can raise. The seeded `*_CONSTRAINTS` arrays are lists of
/// `PolicyRule`; when the engine finds one violated it emits a `Finding`.
public struct PolicyRule: Identifiable, Sendable, Hashable {
    public let id: String
    public let severity: Severity
    public let description: String
    public init(id: String, severity: Severity, description: String) {
        self.id = id; self.severity = severity; self.description = description
    }
}
