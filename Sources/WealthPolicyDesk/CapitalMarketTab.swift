//  CapitalMarketTab.swift
//  WealthPolicyDesk
//
//  The firm-wide capital-market expectations board, shown on the Econ tab. What each
//  asset class is priced to deliver in real terms, built block by block. Household-
//  independent (the market is the same for every client); the per-client "expected vs
//  required" reconciliation lives on the Required Return tab.

import SwiftUI

struct CapitalMarketTab: View {
    private var regime: MacroRegime { Engine.macroRegime(Seed.macroIndicators) }
    private var cme: CapitalMarketSet { Engine.capitalMarketExpectations(Seed.macroIndicators, regime: regime) }

    var body: some View {
        let c = cme
        Card("Capital market expectations") {
            Note("Expected REAL returns over ~10 years, built block by block from today's observable prices — earnings yield, real rates, credit spreads — plus a small set of labeled forecast dials. A glass box, not a black box. The macro inning adds a modest regime overlay. This CONDITIONS and VALIDATES a plan (the 'expected vs required' check on each client's Required Return tab); it never sets the forecast-free strategic target.")
            regimeLine(c)
        }

        Card("Expected real returns — \(c.classes.count) asset classes") {
            ForEach(CMEKind.allCases, id: \.self) { kind in
                let items = c.classes.filter { $0.kind == kind }
                if !items.isEmpty {
                    Text(kind.rawValue.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.accent).padding(.top, 8)
                    ForEach(items) { classRow($0) }
                }
            }
            Text("ALTERNATIVES — BY FUNCTION").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.accent).padding(.top, 8)
            ForEach(AltFunction.allCases) { fn in
                if let r = c.altRealBps[fn] { altRow(fn, r) }
            }
            Note("Alt sleeves are priced as an equity-equivalent beta on US large plus a function premium — illiquidity earns one; convexity is held for the inflation-shock hedge, not the level of return.", color: Theme.muted)
        }
    }

    private func regimeLine(_ c: CapitalMarketSet) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "dial.medium").font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text("Regime overlay — \(c.phase.label), cycle \(c.cycleScore)/100: equity \(Fmt.bpsSigned(c.equityRegimeBps)), credit \(Fmt.bpsSigned(c.creditRegimeBps)). Kept small because CAPE already carries the valuation signal. Expected inflation \(Fmt.pctBps(c.expectedInflationBps)).")
                .font(.system(size: 10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func classRow(_ a: AssetClassCME) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(a.label).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(Fmt.pctBps(a.realReturnBps)).font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(a.realReturnBps >= 400 ? Theme.asset : (a.realReturnBps <= 150 ? Theme.muted : Theme.ink))
            }
            blockLine(a.blocks)
            Text(a.note).font(.system(size: 10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }

    private func blockLine(_ blocks: [CMEBlock]) -> some View {
        Text(blocks.map { "\($0.label) \(Fmt.bpsSigned($0.bps))" }.joined(separator: "   "))
            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func altRow(_ fn: AltFunction, _ r: Bps) -> some View {
        HStack {
            Text(fn.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            Text(Fmt.pctBps(r)).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
        }
        .padding(.vertical, 4)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}
