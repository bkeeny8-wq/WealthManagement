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

// MARK: - Sentiment candidate → the app's sleeve model

public extension TacticalTilt {
    /// Which sleeve this candidate tilts. A sector or factor bet rides the active
    /// US-equity satellite (us_sector_tilt); a region maps to its own sleeve; a
    /// fixed-income view maps to the matching bond sleeve. nil ⇒ not stageable.
    var tiltSleeveId: String? {
        switch ticker {
        case "XLK", "XLF", "XLE", "XLV", "XLY", "XLP", "XLI", "XLB", "XLU", "XLRE", "XLC": return "us_sector_tilt"
        case "VLUE", "MTUM", "QUAL", "USMV", "VUG": return "us_factor_tilt"   // factor via the dedicated factor sleeve
        case "VOO", "VT": return "us_large_core"
        case "IWM": return "us_mid_small"
        case "VEA": return "intl_developed"
        case "VWO": return "emerging"
        case "VNQ": return "real_assets"
        case "TLT", "BND", "AGG": return "fixed_income_liquid"
        case "SCHP": return "tips"
        case "LQD", "HYG": return "credit_hy"
        case "EMB": return "em_debt"
        // Cash (SGOV) and commodities are single-sleeve roles — a within-role-funded
        // tilt has nothing to fund from, so they are not offered as tactical tilts.
        default: return nil
        }
    }

    /// The signed deviation (bps) this candidate proposes, capped at the single-tilt
    /// budget — a governed ±3 stance gets the full cap, a ±1–2 lean gets half.
    func proposedDeviationBps(maxSingleBps: Bps) -> Bps {
        guard stance != .neutral else { return 0 }
        let sign = (stance == .overweight || stance == .leanOver) ? 1 : -1
        let mag = stance.isGoverned ? maxSingleBps : max(50, maxSingleBps / 2)
        return sign * mag
    }

    var isStageable: Bool { tiltSleeveId != nil && stance != .neutral }
}

/// A governed per-client tactical tilt — a signed deviation of ONE sleeve from its
/// strategic target, sourced from a sentiment candidate, carrying a mandatory thesis
/// and a review date. Staged on Planning, committed onto the client's plan of record,
/// then applied to deviate the tactical allocation within the tilt budget.
public struct TacticalTiltAction: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable, Hashable { case staged, committed }
    public var id: UUID
    public var createdAt: Date
    public var sleeveId: String
    public var deviationBps: Bps          // signed (overweight +, underweight −)
    public var sourceName: String         // the sentiment candidate it came from
    public var thesis: String
    public var reviewDate: Date?
    public var status: Status

    public init(id: UUID = UUID(), createdAt: Date = Date(), sleeveId: String, deviationBps: Bps, sourceName: String, thesis: String, reviewDate: Date? = nil, status: Status = .staged) {
        self.id = id; self.createdAt = createdAt; self.sleeveId = sleeveId; self.deviationBps = deviationBps
        self.sourceName = sourceName; self.thesis = thesis; self.reviewDate = reviewDate; self.status = status
    }

    /// Forward-compatible decode: a missing/renamed field never drops the tilt.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        createdAt = ((try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil) ?? Date()
        sleeveId = ((try? c.decodeIfPresent(String.self, forKey: .sleeveId)) ?? nil) ?? ""
        deviationBps = ((try? c.decodeIfPresent(Bps.self, forKey: .deviationBps)) ?? nil) ?? 0
        sourceName = ((try? c.decodeIfPresent(String.self, forKey: .sourceName)) ?? nil) ?? ""
        thesis = ((try? c.decodeIfPresent(String.self, forKey: .thesis)) ?? nil) ?? ""
        reviewDate = (try? c.decodeIfPresent(Date.self, forKey: .reviewDate)) ?? nil
        status = ((try? c.decodeIfPresent(Status.self, forKey: .status)) ?? nil) ?? .committed
    }

    public var short: String { "\(deviationBps >= 0 ? "OW" : "UW") \(Fmt.bpsSigned(deviationBps))" }
}

public extension Engine {

    /// Deviate a policy's sleeve targets by the committed tactical tilts — the
    /// tactical target. Each tilt is capped at the single-tilt budget, the set is
    /// scaled to fit the total budget, and every deviation is funded PRO-RATA from
    /// the other sleeves of the SAME role — so a tilt changes composition, never the
    /// equity/bond risk split the forecast-free solver set. The strategic target is
    /// left untouched (the caller keeps it for the before/after readout).
    static func applyTacticalTilts(_ policy: InvestmentPolicy, tilts: [TacticalTiltAction], budget: TiltPolicy = Seed.tiltPolicy) -> InvestmentPolicy {
        let committed = tilts.filter { $0.status == .committed }
        guard !committed.isEmpty else { return policy }
        var sleeves = policy.sleeves

        // Aggregate to ONE signed deviation per sleeve (two tilts on the same sleeve
        // stack), cap each sleeve's net at the single-tilt budget, then scale the set
        // to the total budget.
        var bySleeve: [String: Bps] = [:]
        for t in committed where sleeves.contains(where: { $0.id == t.sleeveId }) {
            bySleeve[t.sleeveId, default: 0] += t.deviationBps
        }
        for (k, v) in bySleeve {
            bySleeve[k] = max(-budget.maxSingleSectorDeviationBps, min(budget.maxSingleSectorDeviationBps, v))
        }
        let totalAbs = bySleeve.values.reduce(0) { $0 + abs($1) }
        let scale = (totalAbs > budget.maxTotalAbsoluteDeviationBps && totalAbs > 0)
            ? Double(budget.maxTotalAbsoluteDeviationBps) / Double(totalAbs) : 1.0

        for sid in bySleeve.keys.sorted() {
            guard let i = sleeves.firstIndex(where: { $0.id == sid }) else { continue }
            let role = sleeves[i].role
            // Same-role funding sources. A single-sleeve role (cash) has none → skip,
            // never a half-apply that leaves the total off 100%.
            let others = sleeves.indices.filter { $0 != i && sleeves[$0].role == role && sleeves[$0].targetBps > 0 }
            let othersTotal = others.reduce(0) { $0 + sleeves[$1].targetBps }
            guard othersTotal > 0 else { continue }
            // Clamp so the tilted sleeve stays in a valid band: an underweight can't
            // drive it below 0, and an overweight can't exceed what the funders can
            // supply or the sleeve's own maxBps. The funders are driven by the SAME
            // clamped dev, so the deviation still nets to zero within the role.
            let owHeadroom = sleeves[i].maxBps.map { min(othersTotal, max(0, $0 - sleeves[i].targetBps)) } ?? othersTotal
            var dev = Int((Double(bySleeve[sid]!) * scale).rounded())
            dev = min(owHeadroom, max(-sleeves[i].targetBps, dev))
            guard dev != 0 else { continue }
            sleeves[i].targetBps += dev
            var remaining = dev
            for (k, j) in others.enumerated() {
                let share = (k == others.count - 1) ? remaining : Int((Double(dev) * Double(sleeves[j].targetBps) / Double(othersTotal)).rounded())
                sleeves[j].targetBps = max(0, sleeves[j].targetBps - share)
                remaining -= share
            }
        }
        var p = policy
        p.sleeves = sleeves
        return p
    }

    /// Governance findings for the committed tactical tilts: mandatory thesis, the
    /// single-tilt cap, and the total-deviation budget.
    static func validateTacticalTilts(_ tilts: [TacticalTiltAction], budget: TiltPolicy = Seed.tiltPolicy) -> [Finding] {
        let committed = tilts.filter { $0.status == .committed }
        guard !committed.isEmpty else { return [] }
        var out: [Finding] = []
        // Aggregate by sleeve — two tilts on one sleeve stack against the caps.
        var bySleeve: [String: (dev: Bps, sources: [String])] = [:]
        for t in committed {
            var e = bySleeve[t.sleeveId] ?? (0, [])
            e.dev += t.deviationBps; e.sources.append(t.sourceName)
            bySleeve[t.sleeveId] = e
        }
        let total = bySleeve.values.reduce(0) { $0 + abs($1.dev) }
        if total > budget.maxTotalAbsoluteDeviationBps {
            out.append(Finding(ruleId: "tactical_over_budget", module: .tilt, severity: .soft,
                               title: "Tactical tilts over budget",
                               detail: "Net |deviation| across sleeves is \(Fmt.bps(total)), above the \(Fmt.bps(budget.maxTotalAbsoluteDeviationBps)) tactical budget — the applied tilts are scaled to fit.",
                               magnitudeUsd: 0))
        }
        for (sid, e) in bySleeve.sorted(by: { $0.key < $1.key }) {
            if abs(e.dev) > budget.maxSingleSectorDeviationBps {
                out.append(Finding(ruleId: "tactical_single_over", module: .tilt, severity: .soft, key: sid,
                                   title: "Tilt over single cap: \(e.sources.joined(separator: " + "))",
                                   detail: "\(Fmt.bpsSigned(e.dev)) on this sleeve exceeds the \(Fmt.bps(budget.maxSingleSectorDeviationBps)) single-tilt cap; it is clamped when applied."))
            }
        }
        for t in committed where t.thesis.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(Finding(ruleId: "tactical_no_thesis", module: .tilt, severity: .hard, key: t.id.uuidString,
                               title: "Tilt missing thesis",
                               detail: "Every tactical tilt must carry a written thesis — tactical timing is weak-evidence, so the discipline is the price of the bet."))
        }
        return out
    }
}
