import XCTest
@testable import WealthPolicyDesk

/// A model portfolio is an INPUT in an app whose thesis is that allocation is an OUTPUT.
/// These tests pin the line: a model may set COMPOSITION (which sleeves, relative weights
/// within a role) and may never set the LEVEL (the equity share).
final class ModelPortfolioTests: XCTestCase {

    private func household() -> Household {
        var h = Seed.sampleHousehold
        h.statedToleranceMaxDrawdownBps = 2500
        return h
    }

    private func assign(_ h: Household, _ m: ModelPortfolio) -> Household {
        var nh = h
        nh.assignedModel = ModelAssignment(modelId: m.id, model: m, assignedAt: "2026-08-11", reason: "test")
        return nh
    }

    private func growth(_ e: Evaluation) -> Bps {
        e.legacyPolicy.sleeves.filter { $0.role == .growth }.reduce(0) { $0 + $1.targetBps }
    }
    private func target(_ e: Evaluation, _ id: String) -> Bps { e.legacyPolicy.sleeve(id)?.targetBps ?? -1 }

    /// A model that moves weight WITHIN growth changes the split and NOT the level.
    /// Reverting `base: basePolicy(for:)` to `Seed.legacyPolicy` makes the split assertion fail.
    func testModelSetsCompositionNotTheEquityLevel() {
        let h = household()
        let before = Engine.evaluate(h)
        // Same growth total (5600) and same non-growth/alt weights as the seed — only the
        // split inside growth moves: the sector tilt's 700 goes to intl_developed.
        var weights = Seed.legacyPolicy.sleeves.map { ModelSleeveWeight(sleeveId: $0.id, weightBps: $0.targetBps) }
        for i in weights.indices {
            if weights[i].sleeveId == "us_sector_tilt" { weights[i].weightBps = 0 }
            if weights[i].sleeveId == "intl_developed" { weights[i].weightBps = 1500 }
        }
        let m = ModelPortfolio(id: "m_shift", name: "Shift", sleeveWeights: weights,
                               altWeights: Seed.legacyPolicy.altBudgets.map { .init(fn: $0.fn, weightBps: $0.targetBps) })
        XCTAssertTrue(Engine.validate(m).isUsable)
        let after = Engine.evaluate(assign(h, m))

        XCTAssertEqual(growth(after), growth(before), "the derived equity LEVEL must not move with the model")
        XCTAssertEqual(target(after, "us_sector_tilt"), 0, "the model's composition must reach the target")
        XCTAssertGreaterThan(target(after, "intl_developed"), target(before, "intl_developed"))
    }

    /// The doctrine test: a model declaring 95% equity cannot lift the derived target above
    /// the household's own binding risk ceiling, measured on the SAME basis the solver caps
    /// (growth + the alt budget's equity beta).
    func testModelCannotRaiseEquityAboveTheRiskCeiling() {
        let h = household()
        let m = ModelPortfolio(id: "m_hot", name: "Hot",
                               sleeveWeights: [.init(sleeveId: "us_large_core", weightBps: 9500),
                                               .init(sleeveId: "cash", weightBps: 500)],
                               altWeights: [])
        XCTAssertTrue(Engine.validate(m).isUsable, "usable, just aggressive — the point is the solver tames it")
        let e = Engine.evaluate(assign(h, m))
        let ceiling = try! XCTUnwrap(e.riskProfile).bindingEquityBps
        let exposure = growth(e) + Engine.altEquityEquivalentBps(e.legacyPolicy)
        XCTAssertLessThanOrEqual(exposure, ceiling,
                                 "a declared 95% must not become the target: derived \(exposure) vs ceiling \(ceiling)")
        XCTAssertGreaterThan(exposure, 0, "and it must not collapse to nothing either")
    }

    /// A model with no growth sleeve is the one input that could make `resolveTargets` return
    /// its `base` UNCHANGED — the model becoming the target. It must be refused AND said out
    /// loud. Both halves asserted: a silent fallback is the failure shape here.
    func testModelWithNoGrowthSleeveIsRefusedAndReported() {
        let h = household()
        let m = ModelPortfolio(id: "m_bonds", name: "All bonds",
                               sleeveWeights: [.init(sleeveId: "fixed_income_liquid", weightBps: 9000),
                                               .init(sleeveId: "cash", weightBps: 1000)],
                               altWeights: [])
        XCTAssertFalse(Engine.validate(m).isUsable)
        let e = Engine.evaluate(assign(h, m))
        XCTAssertGreaterThan(growth(e), 0, "the firm menu must be solved instead, not the model")
        XCTAssertEqual(target(e, "us_large_core"), Engine.evaluate(h).legacyPolicy.sleeve("us_large_core")?.targetBps)
        XCTAssertTrue(e.findings.contains { $0.ruleId == "model_unusable" && $0.severity == .hard },
                      "and the advisor must be told the client is not on the assigned model")
        XCTAssertEqual(e.modelComparison?.applied, false, "the comparison must report the model was NOT applied")
    }

    /// The finding fires when the model's declared level is not the derived level...
    func testDivergenceFindingFiresWhenLevelsDisagree() {
        let h = household()
        let m = ModelPortfolio(id: "m_defensive", name: "Very defensive",
                               sleeveWeights: [.init(sleeveId: "us_large_core", weightBps: 1000),
                                               .init(sleeveId: "fixed_income_liquid", weightBps: 8000),
                                               .init(sleeveId: "cash", weightBps: 1000)],
                               altWeights: [])
        let e = Engine.evaluate(assign(h, m))
        let c = try! XCTUnwrap(e.modelComparison)
        XCTAssertGreaterThan(abs(c.equityGapBps), Engine.modelDivergenceToleranceBps)
        XCTAssertTrue(e.findings.contains { $0.ruleId == "model_target_divergence" })
    }

    /// ...and stays SILENT when they agree. The mirror case: a rule that only ever fires is
    /// not a rule. The model is built AT the derived level the plan already reached.
    func testDivergenceFindingSilentWhenLevelsAgree() {
        let h = household()
        let e0 = Engine.evaluate(h)
        // Rebuild the seed weights scaled to the derived level, so declared ≈ derived.
        let derivedGrowth = growth(e0)
        let seedGrowth = Seed.legacyPolicy.sleeves.filter { $0.role == .growth }.reduce(0) { $0 + $1.targetBps }
        var weights: [ModelSleeveWeight] = []
        var total = 0
        for s in Seed.legacyPolicy.sleeves where s.role == .growth {
            let w = Int((Double(derivedGrowth) * Double(s.targetBps) / Double(seedGrowth)).rounded())
            weights.append(.init(sleeveId: s.id, weightBps: w)); total += w
        }
        let alts = Seed.legacyPolicy.altBudgets.map { ModelAltWeight(fn: $0.fn, weightBps: $0.targetBps) }
        let altTotal = alts.reduce(0) { $0 + $1.weightBps }
        // Everything else to bonds and cash, mirroring the derived cash weight.
        let derivedCash = e0.legacyPolicy.sleeves.filter { $0.role == .cash }.reduce(0) { $0 + $1.targetBps }
        weights.append(.init(sleeveId: "cash", weightBps: derivedCash))
        weights.append(.init(sleeveId: "fixed_income_liquid", weightBps: 10_000 - total - altTotal - derivedCash))
        let m = ModelPortfolio(id: "m_atlevel", name: "At level", sleeveWeights: weights, altWeights: alts)
        XCTAssertTrue(Engine.validate(m).isUsable)
        let e = Engine.evaluate(assign(h, m))
        let c = try! XCTUnwrap(e.modelComparison)
        XCTAssertLessThanOrEqual(abs(c.equityGapBps), Engine.modelDivergenceToleranceBps,
                                 "fixture must actually reach agreement, or the silence below proves nothing")
        XCTAssertFalse(e.findings.contains { $0.ruleId == "model_target_divergence" })
    }

    /// Assigning a model must never move the household's stated drawdown tolerance. The
    /// level stays the client's own input; `builtForMaxDrawdownBps` is advisory only.
    func testAssignmentNeverMovesTheStatedTolerance() {
        let h = household()
        var m = Seed.modelPortfolios.first { $0.id == "model_growth" }!
        m.builtForMaxDrawdownBps = 5000
        let a = assign(h, m)
        XCTAssertEqual(a.statedToleranceMaxDrawdownBps, h.statedToleranceMaxDrawdownBps)
        XCTAssertEqual(Engine.evaluate(a).riskProfile?.bindingEquityBps,
                       Engine.evaluate(h).riskProfile?.bindingEquityBps)
    }

    /// Every shipped model must be usable and sum to 100%, or the library ships a trap.
    func testShippedModelsAreUsableAndSumToOneHundred() {
        for m in Seed.modelPortfolios {
            XCTAssertTrue(Engine.validate(m).isUsable, "\(m.name) is not usable")
            XCTAssertEqual(m.declaredTotalBps, 10_000, "\(m.name) sums to \(m.declaredTotalBps)")
        }
    }

    /// House Core restates the seed exactly, so assigning it must change nothing.
    func testHouseCoreModelIsTheIdentityAssignment() {
        let h = household()
        let before = Engine.evaluate(h).legacyPolicy.sleeves.map { $0.targetBps }
        let m = Seed.modelPortfolios.first { $0.id == Seed.firmDefaultModelId }!
        let after = Engine.evaluate(assign(h, m)).legacyPolicy.sleeves.map { $0.targetBps }
        XCTAssertEqual(after, before)
    }

    /// A hand-edited model that does not sum to 100% is renormalized for the comparison,
    /// so no row reads as phantom under/overweight.
    func testComparisonRenormalizesADeclaredTotalThatIsNotOneHundred() {
        let h = household()
        let m = ModelPortfolio(id: "m_half", name: "Half",
                               sleeveWeights: [.init(sleeveId: "us_large_core", weightBps: 2800),
                                               .init(sleeveId: "fixed_income_liquid", weightBps: 1700),
                                               .init(sleeveId: "cash", weightBps: 500)],
                               altWeights: [])
        XCTAssertEqual(m.declaredTotalBps, 5000)
        let c = try! XCTUnwrap(Engine.evaluate(assign(h, m)).modelComparison)
        let rowSum = c.rows.reduce(0) { $0 + $1.modelBps } + c.altRows.reduce(0) { $0 + $1.modelBps }
        XCTAssertEqual(rowSum, 10_000, accuracy: 2)
    }

    /// A ClientRecord written before the field existed decodes to the firm default and
    /// evaluates exactly as an unassigned client.
    func testRecordWithoutAnAssignmentIsTheFirmDefault() throws {
        var rec = ClientRecord(intake: IntakeModel(), practice: PracticeMetadata())
        rec.intake.taxableUsd = 500_000
        rec.intake.retirementSpendingUsd = 120_000
        let data = try JSONEncoder().encode(rec)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "modelAssignment")
        let back = try JSONDecoder().decode(ClientRecord.self, from: try JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(back.modelAssignment)
        XCTAssertNil(back.household().assignedModel)
        XCTAssertNil(Engine.evaluate(back.household()).modelComparison)
    }

    /// An assignment whose `model` key is gone decodes to nil — the firm default — rather
    /// than an empty model that would read as "assigned" while meaning nothing.
    func testAssignmentWithoutItsModelDecodesToNil() throws {
        var rec = ClientRecord(intake: IntakeModel(), practice: PracticeMetadata())
        let m = Seed.modelPortfolios[1]
        rec.modelAssignment = ModelAssignment(modelId: m.id, model: m, assignedAt: "2026-08-11", reason: "r")
        let data = try JSONEncoder().encode(rec)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var asn = try XCTUnwrap(obj["modelAssignment"] as? [String: Any])
        asn.removeValue(forKey: "model")
        obj["modelAssignment"] = asn
        let back = try JSONDecoder().decode(ClientRecord.self, from: try JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(back.modelAssignment)
    }

    func testAssignmentRoundTrips() throws {
        let m = Seed.modelPortfolios[2]
        let a = ModelAssignment(modelId: m.id, model: m, assignedAt: "2027-03-01", reason: "accumulating, high savings rate")
        let back = try JSONDecoder().decode(ModelAssignment.self, from: try JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
    }

    /// With NO drawdown tolerance elicited, the ceiling fallback must stay the FIRM
    /// template's growth total. Reading it off the model instead would make the model's own
    /// declared level the ceiling — the model becoming the target through the back door.
    func testNoToleranceCeilingFallbackIsNotTheModelsOwnLevel() {
        var h = Seed.sampleHousehold
        h.statedToleranceMaxDrawdownBps = 0
        let m = ModelPortfolio(id: "m_hot2", name: "Hot",
                               sleeveWeights: [.init(sleeveId: "us_large_core", weightBps: 9500),
                                               .init(sleeveId: "cash", weightBps: 500)], altWeights: [])
        let e = Engine.evaluate(assign(h, m))
        XCTAssertNil(e.riskProfile, "fixture check: no tolerance means no risk profile, so the fallback is in play")
        let firmFallback = Seed.legacyPolicy.sleeves.filter { $0.role == .growth }.reduce(0) { $0 + $1.targetBps }
        let exposure = growth(e) + Engine.altEquityEquivalentBps(e.legacyPolicy)
        XCTAssertLessThanOrEqual(exposure, firmFallback,
                                 "the model's declared 95% must not become the ceiling: derived \(exposure) vs firm fallback \(firmFallback)")
    }

    func testLibraryCustomCopyReplacesABuiltInInPlace() {
        var m = Seed.modelPortfolios.first { $0.id == "model_balanced" }!
        m.name = "Balanced (ours)"; m.version = 7
        let lib = ModelLibrary(custom: [m])
        XCTAssertEqual(lib.all.count, Seed.modelPortfolios.count)
        XCTAssertEqual(lib.model("model_balanced")?.name, "Balanced (ours)")
        XCTAssertEqual(lib.model("model_balanced")?.version, 7)
    }
}
