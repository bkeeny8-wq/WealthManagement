//  ExposureTab.swift
//  WealthPolicyDesk
//
//  The country×sector look-through: where the equity REALLY sits, once the index
//  weights, sector/factor tilts, and concentrated single stocks are decomposed into
//  joint cells. Surfaces the concentration a per-axis (by-sector OR by-country) view
//  can't see, against the cell / sector / country / EM limits.

import SwiftUI

struct ExposureTab: View {
    let eval: Evaluation
    private var ex: ExposureView { Engine.exposureMatrix(eval.household) }
    private var fx: FactorTiltView { Engine.factorExposure(eval.household) }

    var body: some View {
        let e = ex
        Card("Look-through exposure") {
            Note("Every equity holding decomposed into country×sector cells, as a share of total equity. A by-sector OR by-country view can look diversified while one cell — US·Technology, say, once the index weight, a sector tilt, and a concentrated stock stack up — quietly dominates. Sector SPDRs and single stocks land in exact cells (single names are assumed US-domiciled — no geo is captured per holding); total-international funds split developed vs EM; broad intl/EM use the country×sector marginal product. Dated reference weights — verify.")
            LedgerRow("Total equity", Fmt.usdShort(e.equityUsd), color: Theme.ink, bold: true)
            LedgerRow("Emerging-market share", Fmt.pctBps(e.emBps), color: e.emBps > 1500 ? Theme.amber : Theme.muted)
        }

        if e.breaches.isEmpty {
            Card("Within all limits") {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 15)).foregroundStyle(Theme.asset)
                    Text("No cell, sector, country, or EM concentration is over its look-through limit.")
                        .font(.system(size: 13.5)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Card("Concentration breaches — \(e.breaches.count)") {
                ForEach(e.breaches) { b in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(b.label).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                            Text(b.severity == .hard ? "HARD" : "SOFT").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(b.severity == .hard ? Theme.debt : Theme.amber, in: Capsule())
                            Spacer()
                            Text("\(Fmt.pctBps(b.valueBps)) / \(Fmt.pctBps(b.limitBps))")
                                .font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.debt)
                        }
                        Text(b.detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                    .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
                }
            }
        }

        Card("Largest cells — country × sector") {
            let mc = Seed.matrixConstraints.first { $0.scope == .cell }
            let cap = mc?.limitBps ?? 800
            let hard = (mc?.severity ?? .soft) == .hard
            ForEach(e.cells.prefix(12)) { c in
                bar(label: "\(c.geo) · \(c.sector.label)", bps: c.bps, cap: cap, overIsHard: hard)
            }
            Note("The joint cell a per-axis view misses. \(hard ? "Cap" : "Flag over") \(Fmt.pctBps(cap)) of equity per cell — amber is a soft notice, not a mandatory correction.", color: Theme.muted)
        }

        Card("By sector — look-through") {
            let mc = Seed.matrixConstraints.first { $0.scope == .sectorMargin }
            let cap = mc?.limitBps ?? 3800
            let hard = (mc?.severity ?? .hard) == .hard
            ForEach(e.bySector, id: \.sector) { row in bar(label: row.sector.label, bps: row.bps, cap: cap, overIsHard: hard) }
        }

        Card("By country") {
            let mc = Seed.matrixConstraints.first { $0.id == "single_country" }
            let cap = mc?.limitBps ?? 700
            let hard = (mc?.severity ?? .hard) == .hard
            ForEach(Array(e.byGeo.prefix(10)), id: \.geo) { row in
                // US home market is exempt from the single-country cap.
                bar(label: row.geo, bps: row.bps, cap: cap, overIsHard: hard, exempt: row.geo == "US")
            }
        }

        Card("Factor tilts — implied by holdings") {
            Note("The systematic bet the book carries relative to the cap-weighted market (0 = market). A book can look diversified by sector and country yet lean hard on one factor — momentum, growth, or defensives. Broad index funds sit at 0; sector funds, factor funds, and concentrated single names (which inherit their sector's factor character) move the needle. Dated loadings — verify.")
            ForEach(fx.tilts) { t in factorBar(t) }
            Note(fx.summary, icon: "scope", color: Theme.ink)
        }
    }

    // Diverging center bar: 0 = market at the midline; positive fills toward the long
    // (right) end of the axis, negative toward the short (left) end.
    private func factorBar(_ t: FactorTilt) -> some View {
        let maxScale = 0.30
        let frac = min(1, abs(t.tilt) / maxScale)
        let col = t.notable ? Theme.accent : Theme.accent.opacity(0.45)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(t.axis.label).font(.system(size: 13, weight: t.notable ? .semibold : .regular)).foregroundStyle(Theme.ink)
                Spacer()
                Text(signedTilt(t.tilt)).font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(t.notable ? Theme.accent : Theme.muted)
            }
            GeometryReader { geo in
                let half = geo.size.width / 2, barW = max(2, frac * half)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.rule.opacity(0.35)).frame(height: 6)
                    // Only draw the fill for a non-zero tilt; a market-neutral axis (rounds to
                    // 0.00) shows just the center tick, no directional nub biased to one side.
                    if abs(t.tilt) >= 0.005 {
                        Capsule().fill(col).frame(width: barW, height: 6)
                            .offset(x: t.tilt >= 0 ? half : half - barW)
                    }
                    Rectangle().fill(Theme.muted.opacity(0.55)).frame(width: 1, height: 13)
                        .offset(x: half - 0.5)
                }.frame(height: 14)
            }.frame(height: 14)
            HStack {
                Text(t.axis.shortName).font(.system(size: 9.5)).foregroundStyle(Theme.muted)
                Spacer()
                Text(t.axis.longName).font(.system(size: 9.5)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 5)
    }

    private func signedTilt(_ x: Double) -> String {
        let s = String(format: "%+.2f", x)
        return (s == "+0.00" || s == "-0.00") ? "0.00" : s
    }

    private func bar(label: String, bps: Bps, cap: Bps, overIsHard: Bool, exempt: Bool = false) -> some View {
        let over = !exempt && bps > cap
        // Red only for a HARD breach; a soft over-cap cell (e.g. cap-weighted US·Tech)
        // is amber — a notice, matching the SOFT pill and the teaching copy.
        let overColor = overIsHard ? Theme.debt : Theme.amber
        // Exempt rows (US) fill the bar fully without an over color.
        let denom = exempt ? max(bps, 1) : max(1, cap)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.ink)
                Spacer()
                Text(Fmt.pctBps(bps)).font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(over ? overColor : Theme.ink)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let frac = min(1, Double(bps) / Double(denom))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.rule.opacity(0.5)).frame(height: 6)
                    Capsule().fill(over ? overColor : Theme.asset).frame(width: max(2, frac * w), height: 6)
                }
            }.frame(height: 8)
        }
        .padding(.vertical, 4)
    }
}
