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
    // --- Direction / momentum (6-month change) — turning-point signals ---
    public var hyOasChg6mBps: Bps         // Δ HY OAS over 6mo (+ = widening off lows)
    public var termSpreadChg6mBps: Bps    // Δ 10y−3m over 6mo (+ = steepening)
    public var activityChg6m: Double      // Δ activity z over 6mo (+ = accelerating)
    // --- Broader market & survey data ---
    public var claimsChg13wK: Int         // initial claims 4wk-MA, 13-week change (thousands; + = rising)
    public var ismNewOrders: Double       // ISM manufacturing new orders (50 = neutral)
    public var cyclicalDefensiveZ: Double // cyclicals-vs-defensives relative-trend z (+ = risk-on)
    public var copperGoldZ: Double        // copper/gold ratio trend z (+ = growth strong)
    public var spxVs200dPct: Int          // S&P 500 vs its 200-day, % (+ = uptrend)
    public var vix: Double                // CBOE VIX
    // --- Real-economy breadth, prices & liquidity ---
    public var permitsChg6mPct: Int        // building permits, 6mo % change (+ = rising)
    public var consumerExpectations: Double // Conf Board expectations index (<70 = recessionary)
    public var tempEmpChg6mK: Int          // temp-help employment, 6mo change (thousands; + = rising)
    public var excessBondPremiumBps: Bps   // Gilchrist-Zakrajšek EBP (0 ≈ neutral; + = risk-off)
    public var realM2GrowthBps: Bps        // real M2 YoY (+ = liquidity growing)
    public var cpiYoYBps: Bps              // headline CPI YoY
    public var cpiChg6mBps: Bps            // Δ CPI YoY over 6mo (+ = re-accelerating)
    public init(asOf: IsoDate, source: String, termSpread10y3mBps: Bps, realRate10yBps: Bps, breakevenBps: Bps, hyOasBps: Bps, unemploymentBps: Bps, sahmBps: Bps, cape: Double, activityZ: Double, hyOasChg6mBps: Bps = 0, termSpreadChg6mBps: Bps = 0, activityChg6m: Double = 0, claimsChg13wK: Int = 0, ismNewOrders: Double = 50, cyclicalDefensiveZ: Double = 0, copperGoldZ: Double = 0, spxVs200dPct: Int = 0, vix: Double = 16, permitsChg6mPct: Int = 0, consumerExpectations: Double = 90, tempEmpChg6mK: Int = 0, excessBondPremiumBps: Bps = 0, realM2GrowthBps: Bps = 0, cpiYoYBps: Bps = 250, cpiChg6mBps: Bps = 0) {
        self.asOf = asOf; self.source = source; self.termSpread10y3mBps = termSpread10y3mBps
        self.realRate10yBps = realRate10yBps; self.breakevenBps = breakevenBps; self.hyOasBps = hyOasBps
        self.unemploymentBps = unemploymentBps; self.sahmBps = sahmBps; self.cape = cape; self.activityZ = activityZ
        self.hyOasChg6mBps = hyOasChg6mBps; self.termSpreadChg6mBps = termSpreadChg6mBps; self.activityChg6m = activityChg6m
        self.claimsChg13wK = claimsChg13wK; self.ismNewOrders = ismNewOrders; self.cyclicalDefensiveZ = cyclicalDefensiveZ
        self.copperGoldZ = copperGoldZ; self.spxVs200dPct = spxVs200dPct; self.vix = vix
        self.permitsChg6mPct = permitsChg6mPct; self.consumerExpectations = consumerExpectations; self.tempEmpChg6mK = tempEmpChg6mK
        self.excessBondPremiumBps = excessBondPremiumBps; self.realM2GrowthBps = realM2GrowthBps
        self.cpiYoYBps = cpiYoYBps; self.cpiChg6mBps = cpiChg6mBps
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

        // === DIRECTION / MOMENTUM — turns, not levels. A tight spread WIDENING calls
        // the peak; a wide spread NARROWING calls the trough; the curve UN-INVERTS as
        // a recession begins; activity momentum leads the coincident data. ===
        var turning = false

        // 7) Credit direction.
        let dHy = s.hyOasChg6mBps
        if dHy > 40 {
            score += 12; odds += min(25, dHy / 8); turning = true
            signals.append(.init("Credit direction (6mo)", "\(Fmt.bpsSigned(dHy)) — widening", .late, "Spreads widening off their lows — the classic peak signal, even from a tight level."))
        } else if dHy < -80 && (s.hyOasBps - dHy) > 550 {
            score -= 15
            signals.append(.init("Credit direction (6mo)", "\(Fmt.bpsSigned(dHy)) — narrowing off wides", .early, "Spreads peaking and compressing off a stressed level — a recovery signal."))
        } else {
            signals.append(.init("Credit direction (6mo)", "\(Fmt.bpsSigned(dHy)) — stable", .neutral, "No credit turn: spreads roughly flat."))
        }

        // 8) Curve direction — un-inversion is the recession-onset tell, not a green light.
        let dCurve = s.termSpreadChg6mBps
        let priorCurve = s.termSpread10y3mBps - dCurve   // the curve 6 months ago
        if priorCurve < 0 && s.termSpread10y3mBps >= 0 && dCurve > 40 {
            score += 15; odds += 20; turning = true
            signals.append(.init("Curve direction (6mo)", "un-inverted, \(Fmt.bpsSigned(dCurve))", .recession, "The curve bull-steepens right AS a recession begins — the opposite of a green light."))
        } else if dCurve > 30 {
            signals.append(.init("Curve direction (6mo)", "\(Fmt.bpsSigned(dCurve)) — steepening", .neutral, "Steepening from a positive curve — mid-cycle, not a turn."))
        } else if dCurve < -30 {
            score += 6
            signals.append(.init("Curve direction (6mo)", "\(Fmt.bpsSigned(dCurve)) — flattening", .late, "Flattening — policy biting, the cycle maturing."))
        } else {
            signals.append(.init("Curve direction (6mo)", "\(Fmt.bpsSigned(dCurve)) — stable", .neutral, "Little change in the curve."))
        }

        // 9) Activity momentum.
        if s.activityChg6m < -0.3 {
            score += 10; odds += 12; turning = true
            signals.append(.init("Activity momentum (6mo)", String(format: "Δz = %+.1f — decelerating", s.activityChg6m), .late, "Growth losing momentum — the leading edge of a slowdown."))
        } else if s.activityChg6m > 0.3 {
            score -= 8
            signals.append(.init("Activity momentum (6mo)", String(format: "Δz = %+.1f — accelerating", s.activityChg6m), .early, "Growth gaining momentum — early/mid expansion."))
        } else {
            signals.append(.init("Activity momentum (6mo)", String(format: "Δz = %+.1f — steady", s.activityChg6m), .neutral, "Growth momentum roughly flat."))
        }

        // === BROADER MARKET & SURVEY DATA — the market's own cycle vote plus the
        // best hard-data leaders, so the read isn't carried by rates and valuation
        // alone. This is where "the economy is strong" balances "assets look late". ===

        // 10) Jobless claims — the fastest labor leading indicator (leads Sahm).
        if s.claimsChg13wK > 40 {
            score += 10; odds += 12; turning = true
            signals.append(.init("Jobless claims (13wk)", "+\(s.claimsChg13wK)k — rising", .late, "Claims turning up is the earliest labor crack — it leads the Sahm trigger."))
        } else if s.claimsChg13wK < -20 {
            score -= 6
            signals.append(.init("Jobless claims (13wk)", "\(s.claimsChg13wK)k — falling", .early, "Claims still improving — labor demand firm."))
        } else {
            signals.append(.init("Jobless claims (13wk)", "\(s.claimsChg13wK >= 0 ? "+" : "")\(s.claimsChg13wK)k — flat", .neutral, "No labor crack: claims low and stable."))
        }

        // 11) ISM manufacturing new orders — the premier survey leading indicator.
        if s.ismNewOrders < 45 {
            score += 12; odds += 15
            signals.append(.init("ISM new orders", String(format: "%.1f — contracting", s.ismNewOrders), .recession, "Deep sub-50: manufacturing demand contracting — recessionary."))
        } else if s.ismNewOrders < 50 {
            score += 8
            signals.append(.init("ISM new orders", String(format: "%.1f — soft", s.ismNewOrders), .late, "Below 50: new orders shrinking — late-cycle demand fade."))
        } else if s.ismNewOrders <= 53 {
            signals.append(.init("ISM new orders", String(format: "%.1f — steady", s.ismNewOrders), .neutral, "Around the 50 line — demand roughly stable."))
        } else {
            score -= 8
            signals.append(.init("ISM new orders", String(format: "%.1f — strong", s.ismNewOrders), .early, "Well above 50 and rising — robust demand, a healthy real economy."))
        }

        // 12) Cyclicals vs. defensives — the equity market's own cycle vote.
        if s.cyclicalDefensiveZ < -0.4 {
            score += 10; odds += 8; turning = true
            signals.append(.init("Cyclicals vs defensives", String(format: "z = %+.1f — defensives lead", s.cyclicalDefensiveZ), .late, "The market is rotating to defensives — pricing a slowdown."))
        } else if s.cyclicalDefensiveZ > 0.3 {
            score -= 6
            signals.append(.init("Cyclicals vs defensives", String(format: "z = %+.1f — cyclicals lead", s.cyclicalDefensiveZ), .early, "Cyclicals leading — the market is voting risk-on / early-mid."))
        } else {
            signals.append(.init("Cyclicals vs defensives", String(format: "z = %+.1f — mixed", s.cyclicalDefensiveZ), .neutral, "No clear rotation."))
        }

        // 13) Copper/gold — "Dr. Copper" vs. the haven; an industrial-demand read.
        if s.copperGoldZ < -0.5 {
            score += 8; odds += 6
            signals.append(.init("Copper / gold", String(format: "z = %+.1f — gold leads", s.copperGoldZ), .late, "Gold outrunning copper — the market bids safety over growth."))
        } else if s.copperGoldZ > 0.5 {
            score -= 6
            signals.append(.init("Copper / gold", String(format: "z = %+.1f — copper leads", s.copperGoldZ), .early, "Copper outrunning gold — industrial demand firm, growth intact."))
        } else {
            signals.append(.init("Copper / gold", String(format: "z = %+.1f — balanced", s.copperGoldZ), .neutral, "No clear growth-vs-safety tilt."))
        }

        // 14) Equity trend — the index is itself a leading indicator; a rollover leads.
        if s.spxVs200dPct < -5 {
            score += 10; odds += 8; turning = true
            signals.append(.init("Equity trend (vs 200d)", "\(s.spxVs200dPct)% — below trend", .late, "The index has rolled below its 200-day — a leading risk-off signal."))
        } else if s.spxVs200dPct > 3 {
            score -= 6
            signals.append(.init("Equity trend (vs 200d)", "+\(s.spxVs200dPct)% — uptrend", .early, "Index above a rising 200-day — no market rollover; risk-on."))
        } else {
            signals.append(.init("Equity trend (vs 200d)", "\(s.spxVs200dPct >= 0 ? "+" : "")\(s.spxVs200dPct)% — flat", .neutral, "Index churning around its 200-day."))
        }

        // 15) Volatility — stress vs. complacency.
        if s.vix > 28 {
            score += 8; odds += 10; turning = true
            signals.append(.init("Volatility (VIX)", String(format: "%.0f — stressed", s.vix), .recession, "Elevated VIX — the market is repricing risk; stress is here."))
        } else if s.vix < 13 {
            score += 4
            signals.append(.init("Volatility (VIX)", String(format: "%.0f — complacent", s.vix), .late, "Unusually low VIX — calm now, but complacency is a late-cycle tell."))
        } else {
            signals.append(.init("Volatility (VIX)", String(format: "%.0f — calm", s.vix), .neutral, "Volatility subdued and orderly."))
        }

        // === REAL-ECONOMY BREADTH, PRICES & LIQUIDITY — the interest-rate-sensitive
        // and consumer-facing dimensions that turn first, plus the liquidity and
        // inflation backdrop policy responds to. ===

        // 16) Building permits — housing leads the cycle (most rate-sensitive).
        if s.permitsChg6mPct < -12 {
            score += 8; odds += 8; turning = true
            signals.append(.init("Building permits", "\(s.permitsChg6mPct)% / 6mo — falling", .late, "Housing rolls over first — permits declining is an early cycle-top signal."))
        } else if s.permitsChg6mPct > 10 {
            score -= 6
            signals.append(.init("Building permits", "+\(s.permitsChg6mPct)% / 6mo — rising", .early, "Housing turning up — the classic early-cycle, rate-sensitive lead."))
        } else {
            signals.append(.init("Building permits", "\(s.permitsChg6mPct >= 0 ? "+" : "")\(s.permitsChg6mPct)% / 6mo — flat", .neutral, "Housing steady — no clear turn."))
        }

        // 17) Consumer expectations — the consumer is ~70% of GDP.
        if s.consumerExpectations < 70 {
            score += 8; odds += 10
            signals.append(.init("Consumer expectations", String(format: "%.0f — weak", s.consumerExpectations), .recession, "Below ~70 has historically flagged recession — the consumer is retrenching."))
        } else if s.consumerExpectations < 85 {
            score += 5
            signals.append(.init("Consumer expectations", String(format: "%.0f — soft", s.consumerExpectations), .late, "Subdued expectations — spending momentum fading."))
        } else if s.consumerExpectations <= 105 {
            signals.append(.init("Consumer expectations", String(format: "%.0f — steady", s.consumerExpectations), .neutral, "Expectations around average."))
        } else {
            score -= 6
            signals.append(.init("Consumer expectations", String(format: "%.0f — buoyant", s.consumerExpectations), .early, "Optimistic consumer — a spending tailwind."))
        }

        // 18) Temp employment — firms cut temps before permanent staff.
        if s.tempEmpChg6mK < -40 {
            score += 8; odds += 8; turning = true
            signals.append(.init("Temp employment (6mo)", "\(s.tempEmpChg6mK)k — falling", .late, "Temp help is cut first — an early labor crack, ahead of payrolls."))
        } else if s.tempEmpChg6mK > 15 {
            score -= 4
            signals.append(.init("Temp employment (6mo)", "+\(s.tempEmpChg6mK)k — rising", .early, "Temp hiring firm — labor demand expanding at the margin."))
        } else {
            signals.append(.init("Temp employment (6mo)", "\(s.tempEmpChg6mK >= 0 ? "+" : "")\(s.tempEmpChg6mK)k — flat", .neutral, "Temp staffing roughly stable."))
        }

        // 19) Excess bond premium — the risk-appetite slice of credit spreads.
        if s.excessBondPremiumBps > 120 {
            score += 8; odds += 12; turning = true
            signals.append(.init("Excess bond premium", "\(Fmt.bpsSigned(s.excessBondPremiumBps)) — elevated", .recession, "EBP spikes ahead of recessions — risk appetite is contracting."))
        } else if s.excessBondPremiumBps < -50 {
            score -= 6
            signals.append(.init("Excess bond premium", "\(Fmt.bpsSigned(s.excessBondPremiumBps)) — loose", .early, "Below-average EBP — abundant risk appetite, easy financial conditions."))
        } else {
            signals.append(.init("Excess bond premium", "\(Fmt.bpsSigned(s.excessBondPremiumBps)) — normal", .neutral, "Risk appetite near its long-run average."))
        }

        // 20) Real money growth — liquidity feeding (or starving) the cycle.
        if s.realM2GrowthBps < -100 {
            score += 8; odds += 6
            signals.append(.init("Real M2 growth", "\(Fmt.pctBps(s.realM2GrowthBps)) — contracting", .late, "Real money contracting — policy is genuinely tight, a drag ahead."))
        } else if s.realM2GrowthBps > 150 {
            score -= 4
            signals.append(.init("Real M2 growth", "\(Fmt.pctBps(s.realM2GrowthBps)) — ample", .early, "Real money growing — liquidity supports activity."))
        } else {
            signals.append(.init("Real M2 growth", "\(Fmt.pctBps(s.realM2GrowthBps)) — neutral", .neutral, "Money growth roughly matching inflation."))
        }

        // 21) Inflation — overheating late, sub-target into recession; drives policy.
        let cpi = s.cpiYoYBps
        if cpi > 400 {
            score += 6; if s.cpiChg6mBps > 0 { odds += 4 }
            signals.append(.init("Inflation (CPI)", "\(Fmt.pctBps(cpi))\(s.cpiChg6mBps > 0 ? " — hot, rising" : " — hot")", .late, "Above-target inflation keeps policy restrictive — a late-cycle squeeze."))
        } else if cpi < 120 {
            score += 4; odds += 6
            signals.append(.init("Inflation (CPI)", "\(Fmt.pctBps(cpi)) — very low", .recession, "Sub-target inflation often accompanies demand weakness."))
        } else {
            signals.append(.init("Inflation (CPI)", "\(Fmt.pctBps(cpi)) — near target", .neutral, "Inflation around the policy target — no cycle extreme from prices."))
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

        // Direction resolves what levels can't: is this a STABLE read or a TURN?
        let turnClause = turning
            ? " The direction signals are starting to turn — the leading edge is moving, watch it."
            : " The direction signals are quiet — spreads stable, curve not un-inverting, momentum steady — so it's a STABLE read, not a turn."
        let headline: String
        switch phase {
        case .recession: headline = "The coincident data is contracting — the cycle has turned. Recession odds \(Fmt.pctBps(recessionOdds))."
        case .late: headline = "Late-cycle expansion — inning \(inning). No firm recession signal yet, but the late-leaning signals dominate." + turnClause
        case .mid: headline = "Mid expansion — inning \(inning). Growth intact, policy near neutral, no cycle extreme in view." + turnClause
        case .early: headline = "Early cycle — inning \(inning). The signals lean toward recovery off a trough." + turnClause
        }

        return MacroRegime(phase: phase, inning: inning, cycleScore: score, recessionOddsBps: recessionOdds,
                           signals: signals, headline: headline, asOf: s.asOf, source: s.source)
    }
}
