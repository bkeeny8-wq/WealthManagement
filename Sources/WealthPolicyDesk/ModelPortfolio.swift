//  ModelPortfolio.swift
//  WealthPolicyDesk
//
//  THE MODEL PORTFOLIO LIBRARY — named house models (Conservative, Balanced, Growth,
//  your own) that a client can be assigned to.
//
//  THE TENSION, AND HOW IT IS RESOLVED. This app's thesis is that allocation is an
//  OUTPUT: `resolveTargets` derives the equity level from the household's own funded
//  ratio, risk ceiling and liability-sized liquidity floor, with no return forecast. A
//  model portfolio is an INPUT. If assigning one overwrote the derived target, the app
//  would become the thing it was built to argue against.
//
//  So a model is split along the two axes it actually conflates:
//
//    • COMPOSITION (an input, and legitimately the house's): WHICH sleeves exist and
//      their RELATIVE weights within a role — "we hold no EM debt", "we want 12%
//      commodities", "no single-sector bets". The model becomes the `base` template
//      `resolveTargets` starts from, replacing Seed.legacyPolicy's weights. The solver
//      then does exactly what it did before: it rescales growth to the derived growth
//      target and non-growth to what is left. The model's ABSOLUTE equity level is
//      DISCARDED by that rescale — it only ever served as the denominator for relative
//      weights. This is why the template is safe: `growthTarget ≤ growthCeiling =
//      equityCeiling − altEquiv`, so no declared weight can raise total equity exposure
//      above the household's own ceiling.
//
//    • LEVEL (an output, and never the model's to declare): the equity share. The model
//      records the drawdown tolerance it was BUILT FOR, and the UI may offer to write
//      that into `HouseholdOverrides.toleranceMaxDrawdownBps` — the household's own
//      visible, clearable, already-existing input. Capacity still caps it, the funded
//      ratio still glides it. Assignment alone never moves it; that is a second,
//      separate, recorded act.
//
//  And because the model's declared level is discarded, it is free to serve as the
//  BENCHMARK: `compareToModel` measures the derived target against the model AS
//  DECLARED, and `model_target_divergence` fires when they disagree materially, naming
//  WHICH derived input (capacity, tolerance, the funded glide, the liquidity floor)
//  explains the gap. The app shows its thesis instead of hiding it.
//
//  RiskScaleTab's six rungs stay where they are. They are the LEVEL library and they are
//  already derived (the same solver re-run at each tolerance), so this feature sits
//  BESIDE them and points at them: the rung is how you move the level, the model is how
//  you move the composition.
//
//  A model declares WEIGHTS ONLY. Instruments, bands, maxBps, location preference, tax
//  efficiency and liquidity class stay the firm's (Seed.sleeves), so no model can invent
//  a sleeve or re-point one at a different fund.

import Foundation

// MARK: - The model type

public struct ModelSleeveWeight: Codable, Sendable, Hashable, Identifiable {
    public var sleeveId: String
    public var weightBps: Bps
    public var id: String { sleeveId }
    public init(sleeveId: String, weightBps: Bps) { self.sleeveId = sleeveId; self.weightBps = weightBps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sleeveId = ((try? c.decodeIfPresent(String.self, forKey: .sleeveId)) ?? nil) ?? ""
        weightBps = ((try? c.decodeIfPresent(Bps.self, forKey: .weightBps)) ?? nil) ?? 0
    }
}

public struct ModelAltWeight: Codable, Sendable, Hashable, Identifiable {
    public var fn: AltFunction
    public var weightBps: Bps
    public var id: String { fn.rawValue }
    public init(fn: AltFunction, weightBps: Bps) { self.fn = fn; self.weightBps = weightBps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fn = ((try? c.decodeIfPresent(AltFunction.self, forKey: .fn)) ?? nil) ?? .convexity
        weightBps = ((try? c.decodeIfPresent(Bps.self, forKey: .weightBps)) ?? nil) ?? 0
    }
}

/// One named model in the library.
public struct ModelPortfolio: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// The house's reason this model exists. Becomes IPS language, like `Sleeve.rationale`.
    public var rationale: String
    /// Bumped on every edit, so an assignment can name the revision it froze.
    public var version: Int
    /// A shipped house model. Editing one in the library writes a custom copy under the
    /// same id; the built-in definition in code is never mutated.
    public var isBuiltIn: Bool
    public var sleeveWeights: [ModelSleeveWeight]
    public var altWeights: [ModelAltWeight]
    /// The drawdown tolerance this model was BUILT FOR (bps; 0 = none stated). Advisory
    /// ONLY. Nothing in the engine reads it: the UI may offer to write it into
    /// `HouseholdOverrides.toleranceMaxDrawdownBps`, which is the household's own input.
    /// It never reaches the target.
    public var builtForMaxDrawdownBps: Bps

    public init(id: String, name: String, rationale: String = "", version: Int = 1, isBuiltIn: Bool = false,
                sleeveWeights: [ModelSleeveWeight], altWeights: [ModelAltWeight] = [],
                builtForMaxDrawdownBps: Bps = 0) {
        self.id = id; self.name = name; self.rationale = rationale; self.version = version
        self.isBuiltIn = isBuiltIn; self.sleeveWeights = sleeveWeights; self.altWeights = altWeights
        self.builtForMaxDrawdownBps = builtForMaxDrawdownBps
    }

    /// Defaults-first decode: a missing field never drops the model, and an unreadable
    /// element never takes the array with it (each is decoded inside a `try?`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? UUID().uuidString
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? "Unnamed model"
        rationale = ((try? c.decodeIfPresent(String.self, forKey: .rationale)) ?? nil) ?? ""
        version = ((try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? 1
        isBuiltIn = ((try? c.decodeIfPresent(Bool.self, forKey: .isBuiltIn)) ?? nil) ?? false
        sleeveWeights = ((try? c.decodeIfPresent([ModelSleeveWeight].self, forKey: .sleeveWeights)) ?? nil) ?? []
        altWeights = ((try? c.decodeIfPresent([ModelAltWeight].self, forKey: .altWeights)) ?? nil) ?? []
        builtForMaxDrawdownBps = ((try? c.decodeIfPresent(Bps.self, forKey: .builtForMaxDrawdownBps)) ?? nil) ?? 0
    }

    public func weightBps(_ sleeveId: String) -> Bps { sleeveWeights.first { $0.sleeveId == sleeveId }?.weightBps ?? 0 }
    public func altWeightBps(_ fn: AltFunction) -> Bps { altWeights.first { $0.fn == fn }?.weightBps ?? 0 }
    public var declaredSleeveTotalBps: Bps { sleeveWeights.reduce(0) { $0 + $1.weightBps } }
    public var declaredAltTotalBps: Bps { altWeights.reduce(0) { $0 + $1.weightBps } }
    public var declaredTotalBps: Bps { declaredSleeveTotalBps + declaredAltTotalBps }

    /// Declared growth-sleeve weight, by the FIRM's role map (a model declares weights,
    /// never roles).
    public var declaredGrowthBps: Bps {
        sleeveWeights.reduce(0) { $0 + (Seed.legacyPolicy.sleeve($1.sleeveId)?.role == .growth ? $1.weightBps : 0) }
    }

    /// Declared TOTAL-portfolio equity EXPOSURE: growth sleeves plus the alt budget's own
    /// equity/credit beta. The same basis `resolveTargets` caps and the same basis the
    /// `equity_exceeds_binding` rule measures — two bases is how the alt reservation gets
    /// granted twice.
    public var declaredEquityExposureBps: Bps {
        declaredGrowthBps + altWeights.reduce(0) { $0 + Int((Double($1.weightBps) * Engine.altEquityBeta($1.fn)).rounded()) }
    }
}

// MARK: - Validation: the one hole a model could open

/// `resolveTargets` returns `base` UNCHANGED when the template has no growth sleeve or no
/// non-growth sleeve (`guard baseGrowth > 0, !nonGrowth.isEmpty`). On the seed that guard
/// is unreachable; on a hand-authored model it is one typo away, and when it trips the
/// model BECOMES the target — the exact doctrine failure this feature must not introduce.
/// So an unusable model is never fed to the solver: `basePolicy(for:)` falls back to the
/// firm menu and `model_unusable` fires, loudly, rather than silently.
public struct ModelValidation: Sendable, Hashable {
    public enum Problem: String, Sendable, Hashable, CaseIterable {
        case unknownSleeve        // names a sleeve the firm menu does not have
        case negativeWeight
        case noGrowthSleeve       // solver would bail → the model becomes the target
        case noNonGrowthSleeve    // same hole, other side
        case noCashSleeve         // nothing to carry the near-term liquidity floor
        case doesNotSumToOneHundred
        public var label: String {
            switch self {
            case .unknownSleeve: return "names a sleeve outside the firm menu"
            case .negativeWeight: return "has a negative weight"
            case .noGrowthSleeve: return "has no growth sleeve"
            case .noNonGrowthSleeve: return "has no defensive, real or cash sleeve"
            case .noCashSleeve: return "has no cash sleeve to carry the liquidity floor"
            case .doesNotSumToOneHundred: return "does not sum to 100%"
            }
        }
    }
    public var problems: [Problem]
    /// Blocking problems only. `doesNotSumToOneHundred` and `noCashSleeve` are shown but
    /// survivable: the comparison renormalizes, and the solver's cash floor still applies.
    public var isUsable: Bool {
        !problems.contains(.unknownSleeve) && !problems.contains(.negativeWeight)
            && !problems.contains(.noGrowthSleeve) && !problems.contains(.noNonGrowthSleeve)
    }
    public var blocking: [Problem] {
        problems.filter { $0 == .unknownSleeve || $0 == .negativeWeight || $0 == .noGrowthSleeve || $0 == .noNonGrowthSleeve }
    }
}

public extension Engine {
    static func validate(_ m: ModelPortfolio) -> ModelValidation {
        var p: [ModelValidation.Problem] = []
        let menu = Seed.legacyPolicy.sleeves
        if m.sleeveWeights.contains(where: { w in !menu.contains { $0.id == w.sleeveId } }) { p.append(.unknownSleeve) }
        if m.sleeveWeights.contains(where: { $0.weightBps < 0 }) || m.altWeights.contains(where: { $0.weightBps < 0 }) {
            p.append(.negativeWeight)
        }
        func total(_ role: AssetRole) -> Bps {
            m.sleeveWeights.reduce(0) { acc, w in
                acc + (menu.first { $0.id == w.sleeveId }?.role == role ? w.weightBps : 0)
            }
        }
        if total(.growth) <= 0 { p.append(.noGrowthSleeve) }
        if total(.defensive) + total(.realDiversifier) + total(.cash) <= 0 { p.append(.noNonGrowthSleeve) }
        if total(.cash) <= 0 { p.append(.noCashSleeve) }
        if m.declaredTotalBps != 10_000 { p.append(.doesNotSumToOneHundred) }
        return ModelValidation(problems: p)
    }

    /// The `base` InvestmentPolicy `resolveTargets` starts from. The model supplies sleeve
    /// weights and the alt function budget; EVERYTHING else stays `Seed.legacyPolicy`'s —
    /// instruments, bands, maxBps, location preference, tax efficiency, liquidity class,
    /// rationale, wrappers, tiers, ladder/rebalance/withdrawal policy and constraints.
    ///
    /// A sleeve the model gives no weight is kept at targetBps 0 rather than DROPPED. A
    /// dropped sleeve would vanish from `policy.sleeves`, and `resolveAllocation` walks
    /// exactly that list — so a position attributed to it would leave the numerator while
    /// still counting in `portfolioValueUsd`, which is precisely the every-sleeve-reads-
    /// underweight bug `effectiveSleeveId` exists to prevent.
    static func basePolicy(for model: ModelPortfolio?) -> InvestmentPolicy {
        guard let m = model, validate(m).isUsable else { return Seed.legacyPolicy }
        var p = Seed.legacyPolicy
        p.sleeves = p.sleeves.map { s in var ns = s; ns.targetBps = m.weightBps(s.id); return ns }
        p.altBudgets = p.altBudgets.map { b in var nb = b; nb.targetBps = m.altWeightBps(b.fn); return nb }
        return p
    }
}

// MARK: - Assignment (frozen on the client record)

/// A client's model assignment. The model is FROZEN here, not referenced into the library:
/// `ClientRecord.household()` must stay free of file reads so the plan of record reproduces,
/// and editing a library model must never silently rewrite a plan already delivered. The
/// library is the picking surface; this is the record.
public struct ModelAssignment: Codable, Sendable, Hashable {
    /// The library row this was copied from, so the UI can notice the library moved on.
    public var modelId: String
    /// The model as frozen at assignment. AUTHORITATIVE for evaluation.
    public var model: ModelPortfolio
    /// Stamped in the VIEW layer via `todayIsoDate(Date())` — never a clock read in the engine.
    public var assignedAt: IsoDate
    /// Why this client is on this model. A model is an input, and the one discipline an
    /// input owes the file is a reason.
    public var reason: String

    public init(modelId: String, model: ModelPortfolio, assignedAt: IsoDate, reason: String = "") {
        self.modelId = modelId; self.model = model; self.assignedAt = assignedAt; self.reason = reason
    }

    /// `model` is the whole point of the record, so its absence THROWS and the parent's
    /// `try?` turns the assignment into nil — the firm default — rather than an empty
    /// model that would read as "assigned" while meaning nothing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(ModelPortfolio.self, forKey: .model)
        modelId = ((try? c.decodeIfPresent(String.self, forKey: .modelId)) ?? nil) ?? model.id
        assignedAt = ((try? c.decodeIfPresent(IsoDate.self, forKey: .assignedAt)) ?? nil) ?? Engine.planningAsOf
        reason = ((try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil) ?? ""
    }
}

// MARK: - The library and its store

public struct ModelLibrary: Codable, Sendable, Hashable {
    /// Advisor-authored models, plus any edited copy of a built-in (same id).
    public var custom: [ModelPortfolio]
    public init(custom: [ModelPortfolio] = []) { self.custom = custom }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        custom = ((try? c.decodeIfPresent([ModelPortfolio].self, forKey: .custom)) ?? nil) ?? []
    }
    /// Built-ins first, each replaced in place by a custom copy of the same id.
    public var all: [ModelPortfolio] {
        let overridden = Dictionary(custom.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let builtIns = Seed.modelPortfolios.map { overridden[$0.id] ?? $0 }
        let extras = custom.filter { c in !Seed.modelPortfolios.contains { $0.id == c.id } }
        return builtIns + extras
    }
    public func model(_ id: String) -> ModelPortfolio? { all.first { $0.id == id } }
}

// MARK: - The shipped house models

public extension Seed {
    static let firmDefaultModelId = "model_house_core"

    /// The house library. `model_house_core` restates Seed's own weights exactly, so
    /// "on the house model" is an explicit assignment with a benchmark, not an absence.
    static let modelPortfolios: [ModelPortfolio] = [
        ModelPortfolio(
            id: firmDefaultModelId, name: "House Core",
            rationale: "The firm sleeve menu as written: full satellite set, 20% alt function budget. Composition identical to the unassigned default, so the model comparison reads as pure level.",
            isBuiltIn: true,
            sleeveWeights: Seed.legacyPolicy.sleeves.map { .init(sleeveId: $0.id, weightBps: $0.targetBps) },
            altWeights: Seed.legacyPolicy.altBudgets.map { .init(fn: $0.fn, weightBps: $0.targetBps) },
            builtForMaxDrawdownBps: 3000),
        ModelPortfolio(
            id: "model_conservative", name: "Conservative",
            rationale: "No tactical satellites — no factor bet, no sector bet. Core beta, a long defensive sleeve weighted to TIPS, and the convexity function carried for the inflation shock where bonds fail.",
            isBuiltIn: true,
            sleeveWeights: [
                .init(sleeveId: "us_large_core", weightBps: 1600), .init(sleeveId: "us_factor_tilt", weightBps: 0),
                .init(sleeveId: "us_sector_tilt", weightBps: 0), .init(sleeveId: "us_mid_small", weightBps: 500),
                .init(sleeveId: "intl_developed", weightBps: 900), .init(sleeveId: "intl_small", weightBps: 0),
                .init(sleeveId: "emerging", weightBps: 200), .init(sleeveId: "real_assets", weightBps: 300),
                .init(sleeveId: "fixed_income_liquid", weightBps: 2600), .init(sleeveId: "tips", weightBps: 1200),
                .init(sleeveId: "credit_hy", weightBps: 200), .init(sleeveId: "em_debt", weightBps: 0),
                .init(sleeveId: "commodities", weightBps: 500), .init(sleeveId: "cash", weightBps: 1000),
            ],
            altWeights: [.init(fn: .convexity, weightBps: 600), .init(fn: .shapedPayoff, weightBps: 400),
                         .init(fn: .illiquidityPremium, weightBps: 0)],
            builtForMaxDrawdownBps: 1500),
        ModelPortfolio(
            id: "model_balanced", name: "Balanced",
            rationale: "The house menu with the single-sector bet folded back into cap-weighted core: one factor satellite kept, no permanent sector view.",
            isBuiltIn: true,
            sleeveWeights: [
                .init(sleeveId: "us_large_core", weightBps: 2350), .init(sleeveId: "us_factor_tilt", weightBps: 350),
                .init(sleeveId: "us_sector_tilt", weightBps: 0), .init(sleeveId: "us_mid_small", weightBps: 700),
                .init(sleeveId: "intl_developed", weightBps: 800), .init(sleeveId: "intl_small", weightBps: 400),
                .init(sleeveId: "emerging", weightBps: 600), .init(sleeveId: "real_assets", weightBps: 400),
                .init(sleeveId: "fixed_income_liquid", weightBps: 900), .init(sleeveId: "tips", weightBps: 400),
                .init(sleeveId: "credit_hy", weightBps: 300), .init(sleeveId: "em_debt", weightBps: 200),
                .init(sleeveId: "commodities", weightBps: 300), .init(sleeveId: "cash", weightBps: 300),
            ],
            altWeights: [.init(fn: .convexity, weightBps: 700), .init(fn: .shapedPayoff, weightBps: 800),
                         .init(fn: .illiquidityPremium, weightBps: 500)],
            builtForMaxDrawdownBps: 3000),
        ModelPortfolio(
            id: "model_growth", name: "Growth",
            rationale: "Completion-heavy equity — mid/small and international carried at full weight — with the defensive sleeve cut to ballast and the alt budget halved. The accumulation composition.",
            isBuiltIn: true,
            sleeveWeights: [
                .init(sleeveId: "us_large_core", weightBps: 2600), .init(sleeveId: "us_factor_tilt", weightBps: 500),
                .init(sleeveId: "us_sector_tilt", weightBps: 700), .init(sleeveId: "us_mid_small", weightBps: 1000),
                .init(sleeveId: "intl_developed", weightBps: 1200), .init(sleeveId: "intl_small", weightBps: 500),
                .init(sleeveId: "emerging", weightBps: 800), .init(sleeveId: "real_assets", weightBps: 200),
                .init(sleeveId: "fixed_income_liquid", weightBps: 700), .init(sleeveId: "tips", weightBps: 300),
                .init(sleeveId: "credit_hy", weightBps: 0), .init(sleeveId: "em_debt", weightBps: 0),
                .init(sleeveId: "commodities", weightBps: 300), .init(sleeveId: "cash", weightBps: 200),
            ],
            altWeights: [.init(fn: .convexity, weightBps: 500), .init(fn: .shapedPayoff, weightBps: 300),
                         .init(fn: .illiquidityPremium, weightBps: 200)],
            builtForMaxDrawdownBps: 4000),
    ]
}

// MARK: - The comparison the UI needs

public struct ModelDriftRow: Identifiable, Sendable, Hashable {
    public var sleeveId: String
    public var label: String
    public var role: AssetRole
    public var modelBps: Bps        // the model AS DECLARED, renormalized to 100%
    public var derivedBps: Bps      // the plan's derived STRATEGIC target (pre-tilt)
    public var driftBps: Bps        // derived − model
    public var id: String { sleeveId }
}

public struct ModelAltDriftRow: Identifiable, Sendable, Hashable {
    public var fn: AltFunction
    public var modelBps: Bps
    public var derivedBps: Bps
    public var driftBps: Bps
    public var id: String { fn.rawValue }
}

/// How far the plan's DERIVED target sits from the assigned model. Same shape as the
/// Allocation tab's drift rows, with the reference moved: there, target vs the book; here,
/// the model vs the target.
public struct ModelComparison: Sendable, Hashable {
    public var modelId: String
    public var modelName: String
    public var modelVersion: Int
    public var assignedAt: IsoDate
    public var reason: String
    public var validation: ModelValidation
    /// False when `basePolicy(for:)` rejected the model and the firm menu was solved instead.
    public var applied: Bool
    public var modelEquityBps: Bps       // declared growth + alt beta, renormalized
    public var derivedEquityBps: Bps     // derived growth + derived alt beta
    public var equityGapBps: Bps         // derived − model
    // Why the derived level differs — named from the plan, not described in prose.
    public var bindingCeilingBps: Bps
    public var bindingIsCapacity: Bool
    public var toleranceElicited: Bool
    /// False when the client's stated limit is below every portfolio the menu contains, so
    /// `bindingCeilingBps` came from neither capacity nor tolerance — it is the menu's own
    /// floor. Without this the divergence finding fell through to the tolerance branch and
    /// told the advisor to close the gap by "moving the stated drawdown tolerance", an
    /// instruction that cannot work: every value below the floor resolves to the same
    /// ceiling, so they would move the dial and watch nothing change.
    public var hasTolerableBand: Bool
    public var fundedRatioBps: Bps
    public var glideActive: Bool         // funded ratio past fully-funded → equity gliding down
    /// The near-term liquidity floor pushed cash ABOVE its structural share, squeezing the
    /// rest of non-growth. The only place the derived composition can disagree with the
    /// model's relative weights; everywhere else the drift is pure level.
    public var cashFloorBinding: Bool
    public var rows: [ModelDriftRow]
    public var altRows: [ModelAltDriftRow]
    /// One number for "how far from the model": Σ|drift| over sleeves and alt functions.
    public var totalAbsoluteDriftBps: Bps
}

public extension Engine {
    /// Materiality for `model_target_divergence`: 5 points of total equity exposure.
    static let modelDivergenceToleranceBps: Bps = 500

    /// Compare an evaluated plan's derived target against its assigned model. Pure: reads
    /// only the Evaluation. nil when no model is assigned.
    static func compareToModel(_ e: Evaluation) -> ModelComparison? {
        guard let a = e.household.assignedModel else { return nil }
        let m = a.model
        let v = validate(m)
        let applied = v.isUsable

        // Renormalize the declared weights so sleeves + alts sum to 100%, or a hand-edited
        // 90%-total model would read as 10 points of phantom underweight on every row.
        let declared = max(1, m.declaredTotalBps)
        func norm(_ bps: Bps) -> Bps { Int((Double(bps) * 10_000.0 / Double(declared)).rounded()) }

        let derivedStrategic = Dictionary(e.allocation.map { ($0.sleeveId, $0.strategicTargetBps) },
                                          uniquingKeysWith: { a, _ in a })
        let rows: [ModelDriftRow] = Seed.legacyPolicy.sleeves.map { s in
            let mb = norm(m.weightBps(s.id))
            let db = derivedStrategic[s.id] ?? e.legacyPolicy.sleeve(s.id)?.targetBps ?? 0
            return ModelDriftRow(sleeveId: s.id, label: s.label, role: s.role,
                                 modelBps: mb, derivedBps: db, driftBps: db - mb)
        }
        let altRows: [ModelAltDriftRow] = e.legacyPolicy.altBudgets.map { b in
            let mb = norm(m.altWeightBps(b.fn))
            return ModelAltDriftRow(fn: b.fn, modelBps: mb, derivedBps: b.targetBps, driftBps: b.targetBps - mb)
        }

        let modelEquity = norm(m.declaredGrowthBps)
            + m.altWeights.reduce(0) { $0 + Int((Double(norm($1.weightBps)) * altEquityBeta($1.fn)).rounded()) }
        let derivedEquity = e.legacyPolicy.sleeves.filter { $0.role == .growth }.reduce(0) { $0 + $1.targetBps }
            + altEquityEquivalentBps(e.legacyPolicy)

        // Did the liquidity floor push cash above its structural share of non-growth?
        let base = basePolicy(for: applied ? m : nil)
        let sleeveBudget = base.sleeves.reduce(0) { $0 + $1.targetBps }
        let derivedCash = e.legacyPolicy.sleeves.filter { $0.role == .cash }.reduce(0) { $0 + $1.targetBps }
        let nonGrowthBudget = max(0, sleeveBudget - e.legacyPolicy.sleeves.filter { $0.role == .growth }.reduce(0) { $0 + $1.targetBps })
        let baseNonGrowth = base.sleeves.filter { $0.role != .growth }.reduce(0) { $0 + $1.targetBps }
        let baseCash = base.sleeves.filter { $0.role == .cash }.reduce(0) { $0 + $1.targetBps }
        let structuralCash = baseNonGrowth > 0 ? Int(Double(nonGrowthBudget) * Double(baseCash) / Double(baseNonGrowth)) : 0

        return ModelComparison(
            modelId: a.modelId, modelName: m.name, modelVersion: m.version, assignedAt: a.assignedAt,
            reason: a.reason, validation: v, applied: applied,
            modelEquityBps: modelEquity, derivedEquityBps: derivedEquity,
            equityGapBps: derivedEquity - modelEquity,
            bindingCeilingBps: e.riskProfile?.bindingEquityBps ?? 0,
            bindingIsCapacity: e.riskProfile?.bindingIsCapacity ?? false,
            toleranceElicited: e.riskProfile != nil,
            hasTolerableBand: e.riskProfile?.hasTolerableBand ?? true,
            fundedRatioBps: e.balanceSheet.fundedRatioBps,
            glideActive: e.balanceSheet.fundedRatioBps > fundedFloorBps,
            cashFloorBinding: derivedCash > structuralCash,
            rows: rows, altRows: altRows,
            totalAbsoluteDriftBps: rows.reduce(0) { $0 + abs($1.driftBps) } + altRows.reduce(0) { $0 + abs($1.driftBps) })
    }

    /// The findings a model assignment can raise. Called from `evaluateConstraints`, which
    /// receives the comparison only when the plan is SOLVABLE — on an unsolvable plan the
    /// derived target is the seed template or a funded-ratio clamp's glide, so any gap
    /// against the model is an artifact, not a finding.
    static func modelFindings(_ c: ModelComparison?, portfolioUsd: Usd) -> [Finding] {
        guard let c else { return [] }
        var out: [Finding] = []
        if !c.applied {
            out.append(Finding(
                ruleId: "model_unusable", module: .policy, severity: .hard,
                title: "Assigned model could not be applied: \(c.modelName)",
                detail: "The model \(c.validation.blocking.map { $0.label }.joined(separator: " and ")). The plan was solved on the firm sleeve menu instead, so this client is NOT on the model the record says they are. Fix the model's weights or reassign."))
            return out
        }
        let gap = c.equityGapBps
        if abs(gap) > modelDivergenceToleranceBps {
            let why: String
            if !c.toleranceElicited {
                why = "no drawdown tolerance has been elicited, so the ceiling is the firm template's own equity total"
            } else if !c.hasTolerableBand {
                // Tested ahead of capacity and the glide: when no portfolio meets the stated
                // limit the ceiling is the menu's floor, and every other branch would name a
                // cause that is not the cause.
                why = "the stated drawdown limit is below every portfolio this desk can build, so the ceiling is the most defensive mix available (\(Fmt.pctBps(c.bindingCeilingBps))) — moving the tolerance dial will not change it"
            } else if c.bindingIsCapacity {
                why = "equity binds on CAPACITY (\(Fmt.pctBps(c.bindingCeilingBps))) — what the situation affords, not what the model prefers"
            } else if c.glideActive {
                why = "the plan is \(Fmt.pctBps(c.fundedRatioBps)) funded, so the funded-status glide is de-risking equity toward the floor"
            } else {
                why = "equity binds on stated TOLERANCE (\(Fmt.pctBps(c.bindingCeilingBps)))"
            }
            out.append(Finding(
                ruleId: "model_target_divergence", module: .policy, severity: .soft,
                title: gap > 0 ? "Derived target carries more equity than \(c.modelName)"
                              : "Derived target carries less equity than \(c.modelName)",
                detail: "\(c.modelName) declares \(Fmt.pctBps(c.modelEquityBps)) total equity exposure; this household's plan derives \(Fmt.pctBps(c.derivedEquityBps)) — \(Fmt.bpsSigned(gap)). The gap is not an error: \(why). The model is the house's composition view and the benchmark; the LEVEL is this household's own. Close it by moving a goal, the savings rate or the stated drawdown tolerance — not by overwriting the derived target.",
                magnitudeUsd: abs(gap).frac * portfolioUsd))
        }
        if c.cashFloorBinding {
            out.append(Finding(
                ruleId: "model_cash_floor_override", module: .policy, severity: .soft,
                title: "Liquidity floor raised cash above \(c.modelName)",
                detail: "The near-term liquidity floor (rebalance reserve plus twelve months of net outflow) needs more cash than \(c.modelName) declares, so cash was raised and the rest of the defensive sleeves were squeezed proportionally. Cash is sized to what is spent soon, not to a strategic weight."))
        }
        return out
    }
}
