//  DispositionTab.swift
//  WealthPolicyDesk

import SwiftUI

struct DispositionTab: View {
    let eval: Evaluation

    var body: some View {
        Card("Disposition inverts location", help: Teach.help("disposition")) {
            Note("The charity should get the IRA; the heirs should get the brokerage account. Death treatment — step-up vs IRD — drives what you hold and where, and over decades it is worth more than any tilt.", icon: "arrow.triangle.branch", color: Theme.accent)
            if let first = eval.dispositions.first {
                LedgerRow("Estate exemption (household)", Fmt.usd(first.exemptionAvailableUsd), color: Theme.ink)
                LedgerRow("Above exemption?", first.aboveExemption ? "Yes" : "No", color: first.aboveExemption ? Theme.debt : Theme.asset)
            }
        }

        Card("Per-lot terminal disposition") {
            ForEach(eval.dispositions) { d in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(d.ticker).font(.system(size: 16.5, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                        Spacer()
                        recTag(d)
                    }
                    HStack(spacing: 12) {
                        metric("Gain", Fmt.usdShort(d.unrealizedGainUsd))
                        metric("Basis", Fmt.pctBps(d.basisRatioBps))
                        metric("Held", Fmt.usdShort(d.taxIfHeldUsd))
                        metric("Gifted", Fmt.usdShort(d.taxIfGiftedUsd))
                    }
                    Text(d.rationale).font(.system(size: 11.5)).foregroundStyle(Theme.ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
            }
        }

        Card("Beneficiary routing") {
            routeRow("Traditional IRA (IRD)", "→ Charity", "No income tax to the charity; heirs would pay ordinary rates.", Theme.asset)
            routeRow("Taxable, low-basis", "→ Heirs (hold to step-up)", "Basis resets at death; the embedded gain is erased.", Theme.asset)
            routeRow("Roth", "→ Heirs", "Tax-free growth continues; best held by the longest-lived beneficiary.", Theme.asset)
            routeRow("Illiquid alt w/ calls", "→ Accredited heir or entity", "Orphaned capital calls to an unqualified heir are a hard violation.", Theme.amber)
        }

        let e = eval.household.estate
        if e.heirCount > 0 || e.bequestSource != .none || e.annualGivingUsd > 0 || e.hasWill {
            Card("Estate & giving") {
                LedgerRow("Heirs", "\(e.heirCount)", color: Theme.ink)
                LedgerRow("Charitable bequest from", e.bequestSource.label,
                          color: e.bequestSource == .ira ? Theme.asset : (e.bequestSource == .taxable ? Theme.debt : Theme.muted))
                if e.annualGivingUsd > 0 { LedgerRow("Annual giving", Fmt.usd(e.annualGivingUsd), color: Theme.ink) }
                if e.qcdPlannedUsd > 0 { LedgerRow("Planned QCD", Fmt.usd(e.qcdPlannedUsd), color: Theme.asset) }
                if e.dafBalanceUsd > 0 { LedgerRow("DAF balance", Fmt.usd(e.dafBalanceUsd), color: Theme.ink) }
                Divider().overlay(Theme.rule).padding(.vertical, 2)
                docRow("Will", e.hasWill)
                docRow("Revocable trust", e.hasRevocableTrust)
                docRow("Financial POA", e.hasFinancialPOA)
                docRow("Healthcare directive", e.hasHealthcareDirective)
                docRow("Beneficiaries current", e.beneficiaryDesignationsCurrent)
                Note(e.bequestSource == .taxable
                     ? "Charitable bequest is funded from the taxable account while the IRA passes to heirs — flip it: the charity pays no income tax on the IRA; the heirs would."
                     : (e.bequestSource == .ira ? "IRA routed to charity — the tax-efficient bequest." : "No charitable bequest set."),
                     icon: "arrow.triangle.branch", color: e.bequestSource == .taxable ? Theme.debt : Theme.asset)
            }
        }
    }

    private func docRow(_ label: String, _ present: Bool) -> some View {
        HStack {
            Image(systemName: present ? "checkmark.circle.fill" : "xmark.circle").font(.system(size: 14))
                .foregroundStyle(present ? Theme.asset : Theme.debt)
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.ink)
            Spacer()
            Text(present ? "In place" : "Missing").font(.system(size: 11, weight: .semibold)).foregroundStyle(present ? Theme.asset : Theme.debt)
        }
        .padding(.vertical, 4)
    }

    private func recTag(_ d: DispositionDecision) -> some View {
        let match = d.recommendation == d.currentDisposition
        return HStack(spacing: 4) {
            if !match {
                Text(d.currentDisposition.label).font(.system(size: 11.5)).foregroundStyle(Theme.muted).strikethrough()
                Image(systemName: "arrow.right").font(.system(size: 9.5)).foregroundStyle(Theme.muted)
            }
            Text(d.recommendation.label).font(.system(size: 11.5, weight: .heavy)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3.5)
                .background(match ? Theme.asset : Theme.amber, in: Capsule())
        }
    }
    private func metric(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
            Text(v).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
        }
    }
    private func routeRow(_ asset: String, _ to: String, _ why: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(asset).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(to).font(.system(size: 14, weight: .bold)).foregroundStyle(color)
            }
            Text(why).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 6)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}
