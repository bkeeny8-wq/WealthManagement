//  EquityStyleModel.swift
//  WealthPolicyDesk
//
//  The US-equity STYLE overlay — the value ↔ growth axis, chosen per size bucket
//  (large / mid / small). This is a COMPOSITION tilt, not a risk bet: it changes only
//  which flavor of each size exposure is held (the ETF), never how much equity, which
//  size, or the equity/bond split the forecast-free solver set. Because the factor
//  look-through and the rebalancer read the position TICKERS, re-flavoring the held ETF
//  is all it takes for the value/growth posture to flow through the whole desk.
//
//  Implemented with real, liquid Vanguard style ETFs so "what is held" is honest.

import Foundation

/// A US-equity style: the value ↔ growth axis, with blend (cap-weighted) as the neutral.
public enum EquityStyle: String, Codable, CaseIterable, Sendable, Hashable {
    case value, blend, growth
    public var label: String {
        switch self { case .value: return "Value"; case .blend: return "Blend"; case .growth: return "Growth" }
    }
    /// Sign on the value(+)/growth(−) factor axis — blend is 0.
    public var valueSign: Int {
        switch self { case .value: return 1; case .blend: return 0; case .growth: return -1 }
    }
}

/// The US size ladder. Each bucket maps to a policy sleeve — large → `us_large_core`,
/// mid & small → the two instruments of `us_mid_small` — and to the real style ETF held
/// for each value/blend/growth choice.
public enum USSizeBucket: String, CaseIterable, Sendable, Hashable {
    case large, mid, small
    public var label: String {
        switch self { case .large: return "Large cap"; case .mid: return "Mid cap"; case .small: return "Small cap" }
    }
    public var sleeveId: String { self == .large ? "us_large_core" : "us_mid_small" }

    /// The ETF held for a given style — real, liquid Vanguard style funds.
    public func ticker(for style: EquityStyle) -> String {
        switch (self, style) {
        case (.large, .value):  return "VTV"
        case (.large, .blend):  return "VOO"
        case (.large, .growth): return "VUG"
        case (.mid, .value):    return "VOE"
        case (.mid, .blend):    return "VO"
        case (.mid, .growth):   return "VOT"
        case (.small, .value):  return "VBR"
        case (.small, .blend):  return "VB"
        case (.small, .growth): return "VBK"
        }
    }
    /// The cap-weighted (blend) ticker for this bucket.
    public var blendTicker: String { ticker(for: .blend) }

    /// Which size bucket a broad US-equity ticker belongs to (any style flavor + TLH
    /// partners). Returns nil for anything that isn't a broad US size exposure, so only
    /// those holdings are ever re-flavored.
    public static func bucket(forTicker raw: String) -> USSizeBucket? {
        switch raw.uppercased() {
        case "VOO", "SPLG", "VV", "IVV", "VTV", "VUG": return .large
        case "VO", "IJH", "VOE", "VOT", "IJK", "IJJ":  return .mid
        case "VB", "IJR", "VBR", "VBK":                return .small
        default: return nil
        }
    }
}

/// The client's US-equity style posture across the size ladder. Neutral = all blend.
public struct USEquityStyleTilt: Codable, Sendable, Hashable {
    public var large: EquityStyle = .blend
    public var mid: EquityStyle = .blend
    public var small: EquityStyle = .blend

    public init(large: EquityStyle = .blend, mid: EquityStyle = .blend, small: EquityStyle = .blend) {
        self.large = large; self.mid = mid; self.small = small
    }

    public func style(for b: USSizeBucket) -> EquityStyle {
        switch b { case .large: return large; case .mid: return mid; case .small: return small }
    }
    public mutating func set(_ style: EquityStyle, for b: USSizeBucket) {
        switch b { case .large: large = style; case .mid: mid = style; case .small: small = style }
    }
    public var isNeutral: Bool { large == .blend && mid == .blend && small == .blend }

    /// A one-line read of the posture, e.g. "Large growth · Small value".
    public var summary: String {
        let parts = USSizeBucket.allCases.compactMap { b -> String? in
            let s = style(for: b); return s == .blend ? nil : "\(b.label) \(s.label.lowercased())"
        }
        return parts.isEmpty ? "Cap-weighted blend across the US size ladder" : parts.joined(separator: " · ")
    }
}

public extension Household {
    /// Re-flavor US-equity holdings to the chosen value/blend/growth style. Pure composition:
    /// only the ticker (the ETF flavor) changes, so dollars, sleeve, size, and the risk split
    /// are all untouched — the factor look-through and rebalancing then reflect the style.
    func withEquityStyle(_ st: USEquityStyleTilt) -> Household {
        var h = self
        h.equityStyle = st
        // Re-flavor only the SYNTHESIZED, policy-shaped holdings (sleeveId set). A client's
        // real entered holding (itemized, sleeveId == nil) is left exactly as entered — we
        // never silently rename what they actually hold. Runs even for a neutral tilt, so a
        // reset to blend maps a previously-styled proxy ticker back to its blend ETF (the map
        // is idempotent for blend: VUG → VOO, VOO → VOO).
        h.positions = h.positions.map { p in
            guard p.sleeveId != nil, let bucket = USSizeBucket.bucket(forTicker: p.ticker) else { return p }
            var np = p
            np.ticker = bucket.ticker(for: st.style(for: bucket))
            return np
        }
        return h
    }
}
