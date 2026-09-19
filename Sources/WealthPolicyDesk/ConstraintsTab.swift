//  ConstraintsTab.swift
//  WealthPolicyDesk

import SwiftUI

struct ConstraintsTab: View {
    let eval: Evaluation

    // Notable checks the engine runs; those not fired are shown as PASS, so the
    // discrimination is visible — a silent rule is the system working.
    private static let notableChecks: [(id: String, label: String)] = [
        ("muni_in_sheltered_account", "Munis kept out of sheltered accounts"),
        ("liquidity_floor", "Cash and fixed income cover the floor"),
        ("capital_call_coverage", "Liquid assets cover capital calls"),
        ("estate_liquidity", "No estate-tax liquidity shortfall"),
        ("step_up_sale", "No step-up lot in the tactical layer"),
        ("exceeds_total_deviation", "Tactical bet within total budget"),
        ("tips_in_taxable", "No TIPS held in taxable"),
        ("correlated_dual_income", "Dual income survivable on one"),
    ]

    var body: some View {
        if eval.household.positions.isEmpty { emptyNotice } else { solvedBody }
    }

    /// Notable checks that did not fire are painted PASS. On a book with no
    /// holdings they never ran against anything, so the green list is a vacuous
    /// all-clear (munis in the right account, cash covering a $0 floor, …).
    /// Findings that are not holdings-based (protection unreviewed, …) still show.
    private var emptyNotice: some View {
        let findings = eval.findings
        return Group {
            Card("Constraint compliance", help: Teach.help("constraints")) {
                Note("Nothing on the book to check yet. The notable rules that would show PASS — munis in the right account, cash covering the liquidity floor, TIPS location — have not been applied to any holdings. The absence of a hard violation is not an all-clear. Enter the account balances first.",
                     icon: "questionmark.circle", color: Theme.muted)
            }
            if !findings.isEmpty {
                Text("Still on file").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted).padding(.top, 2)
                ForEach(findings) { FindingCard($0) }
            }
        }
    }

    @ViewBuilder private var solvedBody: some View {
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
            Note("The value is as much in what does not fire as in what does. Changing a holding's account on the Portfolio tab re-derives this list.")
        }
    }
}
