//  EngineAnalyses.swift
//  WealthPolicyDesk
//
//  The rest of the engine: allocation resolution, the SALT / itemization
//  engine, terminal disposition, ladder sizing, muni crossover, pay-down
//  analysis, and the cross-module constraint evaluator that walks every seeded
//  *_CONSTRAINTS set and emits the ones a real household actually trips — while
//  correctly staying silent on the ones it doesn't.

import Foundation

extension Engine {

    // MARK: - Allocation (current vs target; the emergent "what it looks like")

    public static func resolveAllocation(_ h: Household, policy: InvestmentPolicy) -> [AllocationRow] {
        let total = max(1, h.portfolioValueUsd)
        return policy.sleeves.map { s in
            let current = h.positions.filter { $0.sleeveId == s.id }.reduce(0) { $0 + $1.marketValueUsd }
            let currentBps = (current / total).bps
            let drift = currentBps - s.targetBps
            let inner = s.bandBps
            let outer = Int(Double(s.bandBps) * policy.rebalance.outerBandMultiplier)
            let status: AllocationRow.Status = abs(drift) >= outer ? .outerBreach : (abs(drift) >= inner ? .innerBreach : .within)
            return AllocationRow(sleeveId: s.id, label: s.label, tier: s.tier, targetBps: s.targetBps, currentBps: currentBps, driftBps: drift, innerBandBps: inner, outerBandBps: outer, status: status)
        }
    }

    /// Which wrapper each alt FUNCTION resolves to at the household's tier, and
    /// where the unfunded weight falls back when no eligible wrapper exists.
    public static func resolveAltSizing(_ h: Household, policy: InvestmentPolicy) -> [AltSizingRow] {
        let total = max(1, h.portfolioValueUsd)
        let tier = policy.tier(h.eligibilityTierId)
        return policy.altBudgets.map { b in
            let current = h.positions.filter { altFunction(ofTicker: $0.ticker) == b.fn }.reduce(0) { $0 + $1.marketValueUsd }
            // Cheapest eligible wrapper for this function at the household's tier.
            let eligibleWrappers = policy.altWrappers.filter { w in
                w.fn == b.fn && (tier?.availableWrapperIds.contains(w.id) ?? false)
            }.sorted { $0.feeBps < $1.feeBps }
            let chosen = eligibleWrappers.first
            return AltSizingRow(
                fn: b.fn, targetBps: b.targetBps, currentBps: (current / total).bps,
                chosenWrapperId: chosen?.id,
                chosenWrapperLabel: chosen?.label ?? "— none at this tier →",
                eligible: chosen != nil, fallbackSleeveId: b.fallbackSleeveId,
                wrapperFeeBps: chosen?.feeBps ?? 0,
                feeOverBudget: (chosen?.feeBps ?? 0) > b.maxFeeBps)
        }
    }

    static func altFunction(ofTicker t: String) -> AltFunction? {
        switch t {
        case "BUFR": return .shapedPayoff
        case "PCRED": return .illiquidityPremium
        case "DBMF", "KMLM", "CTA": return .convexity
        default: return nil
        }
    }

    // MARK: - Itemization / SALT window

    public static func estimatedMagi(_ h: Household, asOf: IsoDate) -> Usd {
        // While earning: wages. (A retired household would use portfolio draw +
        // SS taxable portion; the sample is pre-retirement.)
        let wages = h.humanCapital.reduce(0) { $0 + $1.annualIncomeUsd }
        return wages > 0 ? wages : h.goals.first { $0.kind == .spending }?.outflows.first?.amountUsd ?? 0
    }

    static func itemizationInput(for h: Household, asOf: IsoDate) -> ItemizationInput {
        let magi = estimatedMagi(h, asOf: asOf)
        let homeValue = h.externalAssets.filter { $0.kind == .homeEquity }.reduce(0) { $0 + $1.valueUsd }
            + h.liabilities.filter { $0.kind == .mortgagePrimary }.reduce(0) { $0 + $1.balanceUsd }
        let stateIncomeTax = magi * 0.06          // NJ-ish effective state rate
        let propertyTax = homeValue * 0.018        // NJ property tax is high
        let mortgageInterest = h.liabilities.filter { $0.kind == .mortgagePrimary }.reduce(0.0) { $0 + $1.balanceUsd * $1.rateBps.frac }
        return ItemizationInput(taxYear: year(asOf), filingStatus: h.filingStatus, magiUsd: magi,
                                stateIncomeTaxUsd: stateIncomeTax, propertyTaxUsd: propertyTax,
                                mortgageInterestUsd: mortgageInterest, charitableUsd: 20_000)
    }

    public static func analyzeItemization(_ input: ItemizationInput, tax: TaxParameterSet) -> ItemizationAnalysis {
        let f = input.filingStatus
        let cap = tax.salt.capUsd[f] ?? 10_000
        let threshold = tax.salt.phaseDownThresholdUsd[f] ?? 0
        let floor = tax.salt.phaseDownFloorUsd[f] ?? 10_000
        let rate = tax.salt.phaseDownRatePerDollar
        let overage = max(0, input.magiUsd - threshold)
        let capEff = max(floor, cap - overage * rate)
        let saltPaid = input.stateIncomeTaxUsd + input.propertyTaxUsd
        let saltDeductible = min(saltPaid, capEff)
        let stdDed = tax.standardDeduction[f] ?? 0
        let totalItemized = saltDeductible + input.mortgageInterestUsd + input.charitableUsd
        let itemizes = totalItemized > stdDed
        let taxableIncome = input.magiUsd - max(stdDed, totalItemized)
        let marginalRate = marginalOrdinaryRateBps(taxableIncome: taxableIncome, filing: f, tax: tax)
        let benefitCap = tax.salt.topBracketBenefitCapBps
        let marginalMortgage = itemizes ? min(marginalRate, benefitCap) : 0
        // Phase-down band: income where each extra dollar also erodes the cap.
        // Guard against a zero phase-down rate (a repealed phase-down → no band).
        let bandTop = rate > 0 ? threshold + (cap - floor) / rate : threshold
        let inBand = rate > 0 && input.magiUsd > threshold && input.magiUsd < bandTop
        let saltMaxedOut = saltPaid >= capEff
        let effInBand = (inBand && itemizes && saltMaxedOut)
            ? Int(Double(marginalRate) * (1 + rate)) : marginalRate
        // Years to the scheduled SALT reversion.
        let reversion = tax.scheduledChanges.first { $0.parameter == "salt.capUsd" }.map { max(0, year($0.effectiveFrom) - input.taxYear) }
        return ItemizationAnalysis(input: input, effectiveSaltCapUsd: capEff, saltDeductibleUsd: saltDeductible,
                                   totalItemizedUsd: totalItemized, standardDeductionUsd: stdDed, itemizes: itemizes,
                                   marginalValueOfMortgageInterestBps: marginalMortgage, inPhaseDownBand: inBand,
                                   effectiveMarginalRateInBandBps: effInBand, yearsUntilSaltReversion: reversion)
    }

    // MARK: - Terminal disposition

    public static func dispositions(_ h: Household, tax: TaxParameterSet) -> [DispositionDecision] {
        let persons = max(1, h.people.filter { $0.role != .dependent }.count)
        let exemption = tax.estate.lifetimeExemptionUsd * Double(persons)
        let grossEstate = h.portfolioValueUsd
            + h.externalAssets.filter { $0.kind == .homeEquity || $0.kind == .pension || $0.kind == .business }.reduce(0) { $0 + $1.valueUsd }
        let magi = estimatedMagi(h, asOf: h.people.first?.birthDate ?? "2026-01-01")
        let ltcg = marginalLtcgRateBps(taxableIncome: magi, filing: h.filingStatus, tax: tax)
        // Only taxable appreciated lots carry a basis-vs-estate decision.
        return h.positions
            .filter { h.treatment(of: $0) == .taxable && $0.unrealizedGainUsd > 0 }
            .map { recommendDisposition($0, grossEstate: grossEstate, exemption: exemption, ltcgRateBps: ltcg, topEstateRateBps: tax.estate.topRateBps) }
    }

    public static func recommendDisposition(_ p: Position, grossEstate: Usd, exemption: Usd, ltcgRateBps: Bps, topEstateRateBps: Bps) -> DispositionDecision {
        let above = grossEstate > exemption
        let gain = p.unrealizedGainUsd
        let basisRatio = p.basisRatioBps
        // Held to death: heirs get a step-up (no income tax on the gain). Estate
        // tax applies only above the exemption.
        let taxIfHeld = above ? p.marketValueUsd * topEstateRateBps.frac : 0
        // Gifted in life: carries over basis, so the heir eventually owes LTCG on
        // the gain; but the asset (and its growth) leaves the estate.
        let taxIfGifted = gain * ltcgRateBps.frac
        let estateTaxAvoided = above ? p.marketValueUsd * topEstateRateBps.frac : 0
        let rec: Disposition
        let why: String
        if !above {
            rec = .holdToStepUp
            why = "Below the \(Fmt.usdShort(exemption)) exemption: never gift an appreciated lot. Hold it — the step-up erases the \(Fmt.usdShort(gain)) gain and no estate tax is due."
        } else if basisRatio >= 7000 {
            rec = .giftDuringLife
            why = "Above the exemption and high-basis (\(Fmt.pctBps(basisRatio))): gift it. Little embedded gain to carry over, and \(Fmt.usdShort(estateTaxAvoided)) of estate tax leaves with it."
        } else {
            rec = .holdToStepUp
            why = "Above the exemption but low-basis (\(Fmt.pctBps(basisRatio))): hold it. Gifting would carry over a large gain; the step-up is worth more than the estate-tax saving."
        }
        return DispositionDecision(lotId: p.id, ticker: p.ticker, currentDisposition: p.disposition,
                                   estimatedEstateValueUsd: p.marketValueUsd, exemptionAvailableUsd: exemption,
                                   aboveExemption: above, unrealizedGainUsd: gain, basisRatioBps: basisRatio,
                                   taxIfHeldUsd: taxIfHeld, taxIfGiftedUsd: taxIfGifted, estateTaxAvoidedUsd: estateTaxAvoided,
                                   recommendation: rec, rationale: why)
    }

    // MARK: - Ladder sizing (an OUTPUT of the funded-liability gap)

    public static func ladder(_ h: Household, policy: InvestmentPolicy, asOf: IsoDate) -> LadderPlan {
        let years = policy.ladder.yearsCovered
        guard years > 0, let spending = h.goals.first(where: { $0.kind == .spending }) else {
            let reserve = policy.ladder.rebalanceReserveBps.frac * h.portfolioValueUsd
            let daily = dailyLiquidUsd(h)
            return LadderPlan(yearsCovered: 0, netAnnualOutflowUsd: 0, ladderSizeUsd: 0, rebalanceReserveUsd: reserve, twelveMonthFloorUsd: 0, requiredLiquidUsd: reserve, availableDailyLiquidUsd: daily, covered: daily >= reserve)
        }
        // Pre-fund only GENUINELY near-term outflows — those within the ladder's
        // horizon (`years`) measured from today. Using `prefix(years)` grabbed the
        // earliest N decumulation years even when retirement is decades away, which
        // over-sized the near-term bond floor for young accumulators.
        let outflowYears = spending.outflows.map { $0.year }.filter { $0 <= years }.sorted()
        var nets: [Usd] = []
        for y in outflowYears {
            let out = spending.outflows.first { $0.year == y }?.amountUsd ?? 0
            let ext = socialSecurityAnnual(h, year: y, asOf: asOf) + pensionAnnual(h, year: y) + homeEquityOffset(h, year: y)
            nets.append(max(0, out - ext))
        }
        let netAnnual = nets.isEmpty ? 0 : nets.reduce(0, +) / Double(nets.count)
        let ladderSize = nets.reduce(0, +)
        let reserve = policy.ladder.rebalanceReserveBps.frac * h.portfolioValueUsd
        let floor = netAnnual
        let required = ladderSize + reserve + floor
        let daily = dailyLiquidUsd(h)
        return LadderPlan(yearsCovered: years, netAnnualOutflowUsd: netAnnual, ladderSizeUsd: ladderSize,
                          rebalanceReserveUsd: reserve, twelveMonthFloorUsd: floor, requiredLiquidUsd: required,
                          availableDailyLiquidUsd: daily, covered: daily >= required)
    }

    static func dailyLiquidUsd(_ h: Household) -> Usd {
        h.positions.filter { $0.ticker != "PCRED" && $0.ticker != "PE" }.reduce(0) { $0 + $1.marketValueUsd }
    }

    // MARK: - Muni crossover

    public static func muniCrossover(_ h: Household, tax: TaxParameterSet, muniYieldBps: Bps, treasuryYieldBps: Bps, corporateYieldBps: Bps) -> MuniCrossover {
        let magi = estimatedMagi(h, asOf: "2026-01-01")
        let item = analyzeItemization(itemizationInput(for: h, asOf: "2026-08-11"), tax: tax)
        let taxableIncome = max(0, magi - (item.itemizes ? item.totalItemizedUsd : item.standardDeductionUsd))
        let marginal = marginalOrdinaryRateBps(taxableIncome: taxableIncome, filing: h.filingStatus, tax: tax)
        let niitApplies = magi > (tax.niitThreshold[h.filingStatus] ?? .greatestFiniteMagnitude)
        var effectiveRate = marginal.frac
        if niitApplies { effectiveRate += tax.niitRateBps.frac }
        // The phase-down only bites if the household actually itemizes.
        if item.inPhaseDownBand && item.itemizes { effectiveRate += tax.salt.phaseDownRatePerDollar * marginal.frac }
        let tey = Double(muniYieldBps) / max(0.01, 1 - effectiveRate)
        let teyBps = Int(tey.rounded())
        let preferred = teyBps > max(treasuryYieldBps, corporateYieldBps)
        return MuniCrossover(muniYieldBps: muniYieldBps, treasuryYieldBps: treasuryYieldBps, corporateYieldBps: corporateYieldBps,
                             marginalOrdinaryRateBps: marginal, niitApplies: niitApplies, inSaltPhaseDownBand: item.inPhaseDownBand,
                             taxableEquivalentYieldBps: teyBps, muniPreferred: preferred)
    }

    // MARK: - Pay down or invest

    public static func paydown(_ l: Liability, household h: Household, tax: TaxParameterSet) -> PaydownAnalysis {
        let magi = estimatedMagi(h, asOf: "2026-01-01")
        let item = analyzeItemization(itemizationInput(for: h, asOf: "2026-08-11"), tax: tax)
        let taxableIncome = max(0, magi - (item.itemizes ? item.totalItemizedUsd : item.standardDeductionUsd))
        let marginal = marginalOrdinaryRateBps(taxableIncome: taxableIncome, filing: h.filingStatus, tax: tax)
        // A mortgage in the SALT window has SALT capped on state+property alone,
        // so its interest is fully incremental (deductible at the margin).
        let saltWindowActive = item.itemizes && item.marginalValueOfMortgageInterestBps > 0
        let deductibleValue = (l.interestDeductible && saltWindowActive) ? item.marginalValueOfMortgageInterestBps : 0
        let afterTaxDebt = Int(Double(l.rateBps) * (1 - deductibleValue.frac))
        // Comparable FI is Treasury, after tax at the marginal rate (risk-matched).
        let comparableFi = Int(430.0 * (1 - marginal.frac))
        let spread = afterTaxDebt - comparableFi
        // Paying down converts liquid assets into an asset that can't be drawn on.
        let liquidityCost = l.balanceUsd
        let rec: PaydownAnalysis.Recommendation
        let why: String
        if l.revocable {
            rec = .payDown
            why = "Revocable, un-deductible, \(Fmt.pctBps(l.rateBps)). Retiring it is a risk-free \(Fmt.pctBps(l.rateBps)) bond that also removes a line that disappears in a drawdown."
        } else if spread > 50 {
            rec = .payDown
            why = "After-tax debt rate \(Fmt.pctBps(afterTaxDebt)) exceeds the risk-matched after-tax FI yield \(Fmt.pctBps(comparableFi)). Retiring the debt IS the fixed-income allocation."
        } else if spread < -50 {
            rec = .maintain
            why = saltWindowActive
                ? "In the SALT window the after-tax rate drops to \(Fmt.pctBps(afterTaxDebt)), below the \(Fmt.pctBps(comparableFi)) you earn on risk-matched FI. Keep the debt through the 2029 window — the opposite of default advice."
                : "After-tax debt rate \(Fmt.pctBps(afterTaxDebt)) is below the after-tax FI yield \(Fmt.pctBps(comparableFi)). Hold the debt; liquidity has option value."
        } else {
            rec = .maintain
            why = "After-tax debt and FI yields are within 50bp. A wash on rate — keep the debt for the liquidity option value."
        }
        return PaydownAnalysis(liabilityId: l.id, afterTaxDebtRateBps: afterTaxDebt, comparableFiYieldAfterTaxBps: comparableFi,
                               spreadBps: spread, liquidityCostOfPaydownUsd: liquidityCost, saltWindowActive: saltWindowActive,
                               recommendation: rec, rationale: why)
    }

    // MARK: - Tilt validation (validateTilts)

    public static func validateTilts(_ tp: TiltPolicy, asOf: IsoDate) -> [Finding] {
        guard tp.enabled else { return [] }
        var out: [Finding] = []
        let total = tp.activeTilts.reduce(0) { $0 + abs($1.deviationBps) }
        if total > tp.maxTotalAbsoluteDeviationBps {
            out.append(Finding(ruleId: "exceeds_total_deviation", module: .tilt, severity: .hard,
                               title: "Total active bet over budget",
                               detail: "Sum of |deviation| is \(Fmt.bps(total)), above the \(Fmt.bps(tp.maxTotalAbsoluteDeviationBps)) ceiling."))
        }
        for t in tp.activeTilts {
            if abs(t.deviationBps) > tp.maxSingleSectorDeviationBps {
                out.append(Finding(ruleId: "exceeds_single_sector", module: .tilt, severity: .hard, key: t.nodeId,
                                   title: "Single tilt over cap: \(t.nodeId)",
                                   detail: "\(Fmt.bpsSigned(t.deviationBps)) exceeds the \(Fmt.bps(tp.maxSingleSectorDeviationBps)) single-name cap."))
            }
            if t.funding == .paired && (t.offsetNodeId?.isEmpty ?? true) {
                out.append(Finding(ruleId: "unpaired_tilt", module: .tilt, severity: .hard, key: t.id, title: "Paired tilt missing offset", detail: "Tilt \(t.id) is paired but names no offsetting underweight."))
            }
            if t.thesis.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(Finding(ruleId: "missing_thesis", module: .tilt, severity: .hard, key: t.id, title: "Tilt missing thesis", detail: "Every tilt must carry a written thesis before it can be saved."))
            }
            if year(t.reviewBy) < year(asOf) || (year(t.reviewBy) == year(asOf) && t.reviewBy < asOf) {
                out.append(Finding(ruleId: "review_overdue", module: .tilt, severity: .soft, key: t.nodeId, title: "Tilt review overdue: \(t.nodeId)", detail: "reviewBy \(t.reviewBy) has passed. Re-decide or exit — tilts don't become permanent by inertia."))
            }
        }
        return out
    }

    // MARK: - Cross-module constraint evaluation

    public static func evaluateConstraints(_ h: Household, policy: InvestmentPolicy, tax: TaxParameterSet, asOf: IsoDate,
                                           balanceSheet bs: BalanceSheetView, allocation: [AllocationRow],
                                           altSizing: [AltSizingRow], ladder lad: LadderPlan,
                                           rothTaxSavedUsd: Usd = 0) -> [Finding] {
        var out: [Finding] = []
        let portfolio = max(1, h.portfolioValueUsd)

        // --- Fixed income & liabilities ---
        if bs.netFixedIncomeUsd < 0 {
            out.append(Finding(ruleId: "negative_net_fixed_income", module: .fixedIncome, severity: .soft,
                               title: "Net fixed income is negative",
                               detail: "FI assets less debt is \(Fmt.usdSigned(bs.netFixedIncomeUsd)). The household believes it holds a defensive allocation while running net short duration — a fact no brokerage statement shows.",
                               magnitudeUsd: abs(bs.netFixedIncomeUsd)))
        }
        for p in h.positions where muniTickers.contains(p.ticker) {
            let t = h.treatment(of: p)
            if t == .taxDeferred || t == .taxFree {
                out.append(Finding(ruleId: "muni_in_sheltered_account", module: .fixedIncome, severity: .hard, key: p.id,
                                   title: "Muni held in a sheltered account: \(p.ticker)",
                                   detail: "Paying for a tax exemption inside an already-sheltered account, then converting to ordinary income on withdrawal. Pure waste."))
            }
        }
        for p in h.positions where (p.ticker == "SCHP" || p.ticker == "VTIP") && h.treatment(of: p) == .taxable {
            out.append(Finding(ruleId: "tips_in_taxable", module: .fixedIncome, severity: .soft, key: p.id,
                               title: "TIPS in a taxable account: \(p.ticker)",
                               detail: "Inflation accruals are taxed currently without a cash distribution — tax due on money not received."))
        }

        // --- Policy: liquidity floor, capital-call coverage, smoothed marks, alt fee ---
        if !lad.covered {
            out.append(Finding(ruleId: "liquidity_floor", module: .policy, severity: .hard,
                               title: "Liquidity floor not covered",
                               detail: "Daily-liquid assets (\(Fmt.usdShort(lad.availableDailyLiquidUsd))) fall short of the ladder + reserve + 12 months of outflows (\(Fmt.usdShort(lad.requiredLiquidUsd)))."))
        }
        let unfunded = h.liabilities.filter { $0.kind == .unfundedCommitment }.reduce(0) { $0 + $1.balanceUsd }
        if unfunded > 0 {
            let liquid = dailyLiquidUsd(h)
            if unfunded > liquid {
                out.append(Finding(ruleId: "capital_call_coverage", module: .policy, severity: .hard,
                                   title: "Unfunded commitments exceed liquid assets",
                                   detail: "\(Fmt.usdShort(unfunded)) of unfunded capital calls against \(Fmt.usdShort(liquid)) of liquid assets. Unfunded commitments are a liability, not a weight."))
            }
        }
        if h.positions.contains(where: { $0.ticker == "PCRED" }) {
            out.append(Finding(ruleId: "smoothed_marks_guard", module: .policy, severity: .soft,
                               title: "Smoothed-mark wrapper held: PCRED",
                               detail: "Private-credit marks are appraisal-smoothed. Modeled with a 1200bp volatility override so the optimizer can't allocate 60% to it on understated risk."))
        }
        for row in altSizing where row.feeOverBudget {
            out.append(Finding(ruleId: "alt_fee_budget", module: .policy, severity: .soft,
                               title: "Alt fee over budget: \(row.fn.label)",
                               detail: "Chosen wrapper fee \(Fmt.bps(row.wrapperFeeBps)) exceeds the function's fee budget. Against 5bp bonds the hurdle is real."))
        }

        // --- Household intake ---
        // Human-capital sector stacking: income sector == employer-stock sector.
        for hc in h.humanCapital {
            guard let sector = hc.sector else { continue }
            // Does THIS earner hold employer stock whose sector matches their income sector?
            let stockSameSector = h.deferredComp.contains {
                $0.personId == hc.personId && ($0.kind == .rsu || $0.kind == .espp || $0.kind == .options)
                    && Engine.employerStockSector($0.ticker) == sector
            }
            let tiltSameSector = Seed.tiltPolicy.activeTilts.contains { $0.axis == .sector && $0.nodeId == sector.rawValue }
            if stockSameSector || tiltSameSector {
                out.append(Finding(ruleId: "human_capital_sector_stacking", module: .household, severity: .soft,
                                   title: "Human-capital sector stacking: \(sector.label)",
                                   detail: "\(h.people.first { $0.id == hc.personId }?.label ?? "Earner")'s income depends on \(sector.label); employer stock and any sector tilt stack onto the same undeclared bet."))
                break
            }
        }
        // Employer credit concentration (the only HARD household rule).
        // Union so a grant that is both RSU and credit-exposed counts once.
        let employerExposure = h.deferredComp.filter { $0.subjectToEmployerCredit || $0.kind == .rsu }.reduce(0) { $0 + $1.grantValueUsd }
        if employerExposure > 0.08 * max(1, bs.grossNetWorthUsd) {
            out.append(Finding(ruleId: "employer_credit_concentration", module: .household, severity: .hard,
                               title: "Single-employer concentration",
                               detail: "\(Fmt.usdShort(employerExposure)) of unsecured deferred cash + employer stock — \(Fmt.pctBps((employerExposure / max(1, bs.grossNetWorthUsd)).bps)) of net worth stacked on one balance sheet that also pays the salary.",
                               magnitudeUsd: employerExposure))
        }
        if h.incomeProfile.incomeCorrelation > 0.6 && !h.incomeProfile.survivableOnSingleIncome {
            out.append(Finding(ruleId: "correlated_dual_income", module: .household, severity: .soft,
                               title: "Correlated dual income, not survivable on one",
                               detail: "Both earners in correlated industries with no single-income survivability. Size the reserve to a joint income loss, not one salary."))
        }

        // --- Risk: does the book hold more equity than the household can afford or stomach? ---
        // The risk profile (capacity vs tolerance, bound to the lower) was previously
        // computed and only displayed; here it becomes a binding check on the allocation.
        if let rp = riskProfile(h, fundedRatioBps: bs.fundedRatioBps) {
            let equityUsd = h.positions.filter { isEquity($0) }.reduce(0) { $0 + $1.marketValueUsd }
            let equityBps = (equityUsd / portfolio).bps
            let over = equityBps - rp.bindingEquityBps
            if over > 300 {   // >3 points above the binding ceiling
                let capBound = rp.bindingIsCapacity
                out.append(Finding(ruleId: "equity_exceeds_binding", module: .policy, severity: capBound ? .hard : .soft,
                                   title: capBound ? "Equity above risk capacity" : "Equity above stated tolerance",
                                   detail: "The book holds \(Fmt.pctBps(equityBps)) equity against a binding ceiling of \(Fmt.pctBps(rp.bindingEquityBps)) — \(capBound ? "capacity, what the situation can afford" : "tolerance, what you'll stomach"). \(Fmt.pctBps(over)) over, about \(Fmt.usdShort(over.frac * portfolio)) of equity to trim.",
                                   magnitudeUsd: over.frac * portfolio))
            }
            // Closes the loop honestly: when the derived equity TARGET is already
            // pinned at the risk ceiling and the plan is still underfunded, more
            // equity is not the lever — the gap is a funding problem.
            // Total risk-asset target = sleeve equity + the alt budget's beta. Fire
            // only when THAT sits at the risk ceiling (not when equity is merely
            // liquidity-bound below it) and the plan is still underfunded.
            let sleeveEquityTarget = policy.sleeves.filter { $0.id != Engine.fiSleeveId }.reduce(0) { $0 + $1.targetBps }
            let totalRiskTarget = sleeveEquityTarget + Engine.altEquityEquivalentBps(policy)
            if bs.fundedRatioBps < 9_800, totalRiskTarget + 50 >= rp.bindingEquityBps {
                out.append(Finding(ruleId: "underfunded_at_risk_ceiling", module: .policy, severity: .soft,
                                   title: "At the risk ceiling, still underfunded",
                                   detail: "The target already carries the most equity your \(rp.bindingIsCapacity ? "capacity" : "tolerance") allows (\(Fmt.pctBps(rp.bindingEquityBps))), yet the plan funds only \(Fmt.pctBps(bs.fundedRatioBps)) of its claims. More equity is not the lever — close the gap by deferring or scaling a goal, or saving more.",
                                   magnitudeUsd: 0))
            }
        }

        // --- Disposition ---
        // Bequest routing (uses the per-asset-class routing table + the heirs' bracket):
        // tax-deferred (IRD) dollars left to heirs are taxed at the heirs' rate, often
        // compressed into the SECURE Act 10-year window. The charity pays none, so the
        // IRA should route to charity and Roth / stepped-up taxable lots to the heirs.
        if h.estate.heirCount > 0 {
            let profiles = Dictionary(uniqueKeysWithValues: Seed.assetDispositionProfiles.map { ($0.assetClass, $0) })
            let irdToHeirs = h.positions
                .filter { h.treatment(of: $0) == .taxDeferred && $0.disposition != .charitableAtDeath && $0.disposition != .consume }
                .reduce(0) { $0 + $1.marketValueUsd }   // .consume is spent down during life, not bequeathed
            if irdToHeirs > 0 {
                let heirBracket = h.estate.heirBracketBps > 0 ? h.estate.heirBracketBps : 2400   // ~24% if unstated
                let drag = irdToHeirs * heirBracket.frac
                let tenYear = profiles[.taxDeferred]?.subjectToTenYearRule ?? true
                out.append(Finding(ruleId: "ird_to_heirs_drag", module: .disposition, severity: .soft,
                                   title: "Inherited-IRA tax drag on heirs",
                                   detail: "\(Fmt.usdShort(irdToHeirs)) of tax-deferred (IRD) routes to heirs, who owe about \(Fmt.usdShort(drag)) of income tax at their \(Fmt.pctBps(heirBracket)) bracket\(tenYear ? ", compressed into the 10-year drawdown window" : ""). Send the IRA to charity (it pays none) and leave Roth and stepped-up taxable lots to the heirs.",
                                   magnitudeUsd: drag))
            }
        }
        // Step-up sale: a step-up-earmarked lot whose terminal disposition forfeits
        // the step-up (distinct from the tactical-layer check below).
        for p in h.positions where p.holdToStepUp && (p.disposition == .stepUpThenSell || p.disposition == .giftDuringLife) {
            out.append(Finding(ruleId: "step_up_sale", module: .disposition, severity: .hard, key: p.id,
                               title: "Step-up lot slated for sale: \(p.ticker)",
                               detail: "\(p.ticker) is earmarked hold-to-step-up yet its disposition (\(p.disposition.label)) forfeits it. A taxable sale of a step-up lot is a violation, not a budgeted cost."))
        }
        if bs.liabilities.projectedEstateTaxUsd > dailyLiquidUsd(h) {
            out.append(Finding(ruleId: "estate_liquidity", module: .disposition, severity: .hard,
                               title: "Estate-tax liquidity shortfall",
                               detail: "Projected estate tax \(Fmt.usdShort(bs.liabilities.projectedEstateTaxUsd)) exceeds liquid assets. The 9-month filing deadline would force a distressed sale.",
                               magnitudeUsd: bs.liabilities.projectedEstateTaxUsd))
        }

        // --- Layer separation ---
        for p in h.positions where p.layer == .tactical && p.holdToStepUp {
            out.append(Finding(ruleId: "no_tactical_step_up", module: .layer, severity: .hard, key: p.id,
                               title: "Tactical lot carries a step-up earmark: \(p.ticker)",
                               detail: "Tactical lots express a 6–18 month view and must never be earmarked to step-up."))
        }

        // --- Planning surface ---
        // Concentrated single-name held permanently without a hedge.
        for p in h.positions where p.isConcentrated && p.sleeveId == nil && p.holdToStepUp && !isFixedIncome(p) && altFunction(ofTicker: p.ticker) == nil {
            let share = (p.marketValueUsd / portfolio)
            if share > 0.08 {
                out.append(Finding(ruleId: "concentrated_permanent_hold", module: .planning, severity: .soft, key: p.id,
                                   title: "Concentrated permanent hold: \(p.ticker)",
                                   detail: "\(p.ticker) is \(Fmt.pct(share)) of the portfolio, low-basis and earmarked to step-up with no hedge. Permanent by intent — make sure it's permanent by decision.",
                                   magnitudeUsd: p.marketValueUsd))
            }
        }

        // Estate: core documents missing while there is estate intent.
        if !h.estate.docsComplete && (h.estate.heirCount > 0 || h.estate.bequestSource != .none) {
            out.append(Finding(ruleId: "estate_docs_incomplete", module: .planning, severity: .soft,
                               title: "Estate documents incomplete",
                               detail: "Missing: \(h.estate.missingDocs.joined(separator: ", ")). Without them the disposition routing passes through probate rather than the controlled, pre-designated path the plan assumes."))
        }

        // --- Protection (insurance coverage gaps) ---
        if let prot = h.protection {
            if prot.disabilityGapMonthlyUsd > 0.10 * max(1, prot.disabilityNeedMonthlyUsd) {
                out.append(Finding(ruleId: "disability_gap", module: .planning, severity: .hard,
                                   title: "Disability coverage gap",
                                   detail: "Monthly disability need \(Fmt.usdShort(prot.disabilityNeedMonthlyUsd)) vs coverage \(Fmt.usdShort(prot.disabilityCoverageMonthlyUsd)) — a \(Fmt.usdShort(prot.disabilityGapMonthlyUsd))/mo gap on the income that funds the whole plan.",
                                   magnitudeUsd: prot.disabilityGapMonthlyUsd * 12))
            }
            // Legacy intent = a real legacy floor. (A structural .legacy corpus goal is
            // always present, so it can't be the signal.) Without a bequest to protect,
            // an LTC event just spends a corpus that was already being spent down.
            if prot.ltcUnfundedUsd > 0 && h.legacyFloorUsd > 0 {
                out.append(Finding(ruleId: "ltc_unfunded", module: .planning, severity: .hard,
                                   title: "Long-term care unfunded",
                                   detail: "\(Fmt.usdShort(prot.ltcUnfundedUsd)) of LTC exposure is unfunded — the largest tail for a household carrying a legacy floor to protect.",
                                   magnitudeUsd: prot.ltcUnfundedUsd))
            }
            if prot.lifeGapUsd > 0.05 * max(1, prot.lifeNeedUsd) {
                out.append(Finding(ruleId: "life_underinsured", module: .planning, severity: .soft,
                                   title: "Life insurance shortfall",
                                   detail: "Estimated need \(Fmt.usdShort(prot.lifeNeedUsd)) vs \(Fmt.usdShort(prot.lifeInForceUsd)) in force — a \(Fmt.usdShort(prot.lifeGapUsd)) gap.",
                                   magnitudeUsd: prot.lifeGapUsd))
            }
            if prot.umbrellaLimitUsd > 0 && prot.umbrellaLimitUsd < bs.grossNetWorthUsd {
                out.append(Finding(ruleId: "umbrella_thin", module: .planning, severity: .soft,
                                   title: "Umbrella limit below net worth",
                                   detail: "Umbrella \(Fmt.usdShort(prot.umbrellaLimitUsd)) is below gross net worth \(Fmt.usdShort(bs.grossNetWorthUsd)) — the liability tail is under-covered.",
                                   magnitudeUsd: max(0, bs.grossNetWorthUsd - prot.umbrellaLimitUsd)))
            }
            if prot.disabilityGroupOnlyTaxable {
                out.append(Finding(ruleId: "disability_group_only_taxable", module: .planning, severity: .soft,
                                   title: "Disability coverage is group-only & taxable",
                                   detail: "Employer-paid group DI is taxed on the way out, so the real replacement is ~28% lower. A private, own-occ layer closes the after-tax gap."))
            }
        }

        // --- Equity compensation mechanics ---
        if let ec = h.equityComp {
            if !ec.pending83bGrantDate.isEmpty {
                out.append(Finding(ruleId: "83b_window", module: .planning, severity: .hard,
                                   title: "83(b) election window open",
                                   detail: "A grant dated \(ec.pending83bGrantDate) awaits an 83(b) election — a 30-day, irrevocable window. File before it closes."))
            }
            if ec.plannedExerciseAndHold && ec.isoBargainElementUsd > 0 {
                out.append(Finding(ruleId: "iso_amt_exposure", module: .planning, severity: .hard,
                                   title: "ISO exercise-and-hold AMT exposure",
                                   detail: "A \(Fmt.usdShort(ec.isoBargainElementUsd)) bargain element becomes an AMT preference item — tax due with no cash received. Model the crossover price before exercising.",
                                   magnitudeUsd: ec.isoBargainElementUsd))
            }
            if (ec.isInsider || ec.tradingWindow != .open) && !ec.has10b51Plan {
                out.append(Finding(ruleId: "blackout_diversification_unscheduled", module: .planning, severity: .soft,
                                   title: "Concentrated diversification not scheduled",
                                   detail: "Insider/blackout status with no 10b5-1 plan. Diversification must be scheduled ahead through the cooling-off period, not executed on demand."))
            }
            if ec.qsbs != .none {
                out.append(Finding(ruleId: "qsbs_verify", module: .planning, severity: .soft,
                                   title: "QSBS eligibility to verify",
                                   detail: "Possible QSBS flagged (\(ec.qsbs.label)). Exclusion rules are specific and were recently modified — verify holding-period and gross-asset tests before relying on it."))
            }
        }

        // Decumulation: a Roth-conversion window worth filling before RMDs begin.
        if rothTaxSavedUsd > 10_000 {
            out.append(Finding(ruleId: "roth_conversion_opportunity", module: .tax, severity: .soft,
                               title: "Roth-conversion window open",
                               detail: "Filling the low-bracket pre-RMD years with Roth conversions cuts projected lifetime federal tax by about \(Fmt.usdShort(rothTaxSavedUsd)). The Decumulation tab has the year-by-year plan.",
                               magnitudeUsd: rothTaxSavedUsd))
        }

        // Transition: scheduled realized gains outrunning the annual budget.
        if h.transitionGainBudgetUsd > 0 && h.transitionAnnualRealizedGainUsd > h.transitionGainBudgetUsd {
            out.append(Finding(ruleId: "transition_gain_budget_exceeded", module: .planning, severity: .hard,
                               title: "Unwind outruns the gain budget",
                               detail: "Scheduled realized gains of \(Fmt.usdShort(h.transitionAnnualRealizedGainUsd))/yr exceed the \(Fmt.usdShort(h.transitionGainBudgetUsd)) annual budget. Stretch the transition, or use an accelerator — charitable gift of appreciated shares, loss-harvesting, or gifting to family.",
                               magnitudeUsd: max(0, h.transitionAnnualRealizedGainUsd - h.transitionGainBudgetUsd)))
        }

        // --- Tactical tilts ---
        out.append(contentsOf: validateTilts(Seed.tiltPolicy, asOf: asOf))

        // Sort: hard first, then by dollars at stake (bigger first), then module.
        return out.sorted {
            let aHard = $0.severity == .hard ? 0 : 1, bHard = $1.severity == .hard ? 0 : 1
            if aHard != bHard { return aHard < bHard }
            if $0.magnitudeUsd != $1.magnitudeUsd { return $0.magnitudeUsd > $1.magnitudeUsd }
            return $0.module.rawValue < $1.module.rawValue
        }
    }
}
