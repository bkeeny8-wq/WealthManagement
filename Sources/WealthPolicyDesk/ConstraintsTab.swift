//  ConstraintsTab.swift
//  WealthPolicyDesk

import SwiftUI

struct ConstraintsTab: View {
    let eval: Evaluation

    // Notable checks the engine runs; those not fired are shown as PASS, so the
    // discrimination is visible — a silent rule is the system working.
    private static let notableChecks: [(id: String, label: String)] = [
        ("muni_in_sheltered_account", "Munis kept out of sheltered accounts"),
        ("liquidity_floor", "Daily-liquid assets cover the floor"),
        ("capital_call_coverage", "Liquid assets cover capital calls"),
        ("estate_liquidity", "No estate-tax liquidity shortfall"),
        ("step_up_sale", "No step-up lot in the tactical layer"),
        ("exceeds_total_deviation", "Tactical bet within total budget"),
        ("tips_in_taxable", "No TIPS held in taxable"),
        ("correlated_dual_income", "Dual income survivable on one"),
    ]

    var body: some View {
        let hard = eval.findings.filter { $0.severity == .hard }
        let soft = eval.findings.filter { $0.severity == .soft }
        let firedIds = Set(eval.findings.map { $0.ruleId })
        let passed = Self.notableChecks.filter { !firedIds.contains($0.id) }

        Card("Constraint compliance", help: Teach.help("constraints")) {
            HStack(spacing: 8) {
                StatTile("Hard violations", "\(hard.count)", sub: "Block", color: hard.isEmpty ? Theme.asset : Theme.debt)
                StatTile("Soft flags", "\(soft.count)", sub: "Review", color: soft.isEmpty ? Theme.asset : Theme.amber)
                StatTile("Checks passed", "\(passed.count)+", sub: "Silent = working", color: Theme.asset)
            }
        }

        if !hard.isEmpty {
            Text("HARD — must resolve").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.debt).padding(.top, 2)
            ForEach(hard) { FindingCard($0) }
        }
        if !soft.isEmpty {
            Text("SOFT — flags").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.amber).padding(.top, 2)
            ForEach(soft) { FindingCard($0) }
        }

        Card("Passed — and worth noticing") {
            ForEach(passed, id: \.id) { c in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.asset)
                    Text(c.label).font(.system(size: 14.5)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text("PASS").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.asset)
                }
                .padding(.vertical, 5)
                .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
            }
            Note("The value is as much in what does not fire as in what does. Move the muni into the IRA in the editor and watch this list react.")
        }
    }
}
