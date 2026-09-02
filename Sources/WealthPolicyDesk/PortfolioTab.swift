//  PortfolioTab.swift
//  WealthPolicyDesk
//
//  "Bring the client's current portfolio and integrate it into the model." A desk-side
//  editor for the real holdings (ticker, value, account, basis) — the asset input the
//  desk was missing — plus a per-holding suggestion board: each holding mapped to a
//  policy sleeve with a tax-aware keep / add / trim / relocate / unwind step.
//
//  Holdings are edited in a local draft and applied explicitly (a rebuild is expensive),
//  matching the desk's stage-then-commit model. Applying writes them onto the client's
//  record so the whole desk re-derives against the real book.

import SwiftUI

struct PortfolioTab: View {
    let eval: Evaluation
    var holdings: [IntakeHeldPosition] = []
    var canEdit: Bool = false
    var onApply: ([IntakeHeldPosition]) -> Void = { _ in }

    @State private var draft: [IntakeHeldPosition] = []
    @State private var loaded = false

    private var dirty: Bool { draft != holdings }

    var body: some View {
        let integ = Engine.portfolioIntegration(eval)

        Card("Current portfolio — the client's actual holdings") {
            Note("Enter each position the client holds today — ticker, value, account type, and cost basis. Everything below maps each holding to a policy sleeve and gives a tax-aware step to integrate it into the model. Only the handful that matter need entering; the rest of each account stays a policy-shaped proxy.")
            if !canEdit {
                Note("Open a saved client to enter and apply holdings. (The sample is read-only.)", icon: "lock", color: Theme.muted)
            } else {
                ForEach($draft) { $p in
                    HeldPositionForm(position: $p) { draft.removeAll { $0.id == p.id } }
                }
                HStack {
                    Button { draft.append(IntakeHeldPosition()) } label: {
                        Label("Add a holding", systemImage: "plus.circle").font(.system(size: 14, weight: .semibold))
                    }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                    Spacer()
                    if dirty {
                        Button { onApply(draft) } label: {
                            Label("Apply to the model", systemImage: "arrow.down.doc")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Theme.asset, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
                if dirty { Note("Unapplied edits — tap Apply to re-map against the policy.", icon: "exclamationmark.circle", color: Theme.amber) }
            }
        }
        .onAppear { if !loaded { draft = holdings; loaded = true } }

        if integ.hasHoldings {
            Card("Integration — how the book fits the model") {
                Note(integ.summary)
                HStack(spacing: 8) {
                    StatTile("Entered", Fmt.usdShort(integ.itemizedUsd), sub: "\(integ.suggestions.count) holdings", color: Theme.ink)
                    StatTile("Mapped to policy", integ.itemizedUsd > 0 ? Fmt.pct(integ.classifiedUsd / integ.itemizedUsd) : "—",
                             sub: "classified", color: Theme.asset)
                    StatTile("Embedded gain", Fmt.usdShort(integ.unrealizedGainUsd), sub: "taxable if sold", color: integ.unrealizedGainUsd > 0 ? Theme.amber : Theme.muted)
                }
                actionLegend(integ)
            }

            Card("Per-holding steps") {
                ForEach(integ.suggestions) { suggestionCard($0) }
                Note("These are analysis steps, not orders. Stage the sells/buys you accept on the Planning tab; taxable trims respect the transition gain budget.", color: Theme.muted)
            }
        }
    }

    // MARK: - pieces

    private func actionLegend(_ integ: PortfolioIntegration) -> some View {
        let order: [HoldingAction] = [.unwind, .relocate, .trim, .review, .add, .keep]
        return HStack(spacing: 6) {
            ForEach(order.filter { (integ.actionCounts[$0] ?? 0) > 0 }, id: \.self) { a in
                HStack(spacing: 4) {
                    Circle().fill(color(for: a)).frame(width: 7, height: 7)
                    Text("\(integ.actionCounts[a] ?? 0) \(a.label.lowercased())").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func suggestionCard(_ s: HoldingSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.ticker).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                Text("· \(s.sleeveLabel)").font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                Text(s.action.label.uppercased()).font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(color(for: s.action), in: Capsule())
            }
            HStack(spacing: 10) {
                Text(Fmt.usdShort(s.marketValueUsd)).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
                Text(s.accountLabel).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                if s.isConcentrated {
                    Text("CONCENTRATED").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.debt)
                }
            }
            Text(s.rationale).font(.system(size: 12.5)).foregroundStyle(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            if let tax = s.taxNote {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "percent").font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 2)
                    Text(tax).font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
        .padding(.vertical, 3)
    }

    private func color(for a: HoldingAction) -> Color {
        switch a {
        case .unwind:   return Theme.debt
        case .relocate: return Theme.amber
        case .trim:     return Theme.amber
        case .review:   return Theme.accent
        case .add:      return Theme.asset
        case .keep:     return Theme.muted
        }
    }
}
