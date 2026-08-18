//  PlanningTab.swift
//  WealthPolicyDesk
//
//  The one place on the desk that CHANGES the plan. Compose a move — sell part or
//  all of a holding and rotate the proceeds into a sector (its Select Sector
//  SPDR) — and STAGE it. Staging previews the move across the whole desk
//  non-destructively (a banner marks the preview). Commit writes the staged moves
//  onto the client's plan of record. Nothing here is advice; it is a what-if you
//  choose to record.

import SwiftUI

struct PlanningTab: View {
    let base: Household                 // household of record (committed applied)
    @Binding var staged: [PlannedAction]
    @Binding var stagedTilts: [TacticalTiltAction]
    let committed: [CommittedMoveStatus]
    let committedTilts: [TacticalTiltAction]
    let canPersist: Bool
    var onCommit: () -> Void
    var onDiscard: () -> Void

    @State private var sellId: String? = nil
    @State private var sellAll = true
    @State private var sellUsd: Usd = 25_000
    @State private var targetSector: Sector = .consumerStaples
    @State private var thesis = ""
    @State private var hasReview = false
    @State private var reviewDate = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()

    /// The household after the moves already staged — what is available to rotate.
    private var current: Household { base.applying(staged) }
    private var sellable: [Position] { current.positions.filter { $0.marketValueUsd > 1 }.sorted { $0.marketValueUsd > $1.marketValueUsd } }
    private var effSell: Position? { sellable.first { $0.id == sellId } ?? sellable.first }

    private var candidate: PlannedAction? {
        guard let p = effSell else { return nil }
        let amt = sellAll ? p.marketValueUsd : min(max(0, sellUsd), p.marketValueUsd)
        guard amt > 1, targetSector.spdrTicker != p.ticker else { return nil }
        return PlannedAction(sellAccountId: p.accountId, sellTicker: p.ticker, sellUsd: amt,
                             buyTicker: targetSector.spdrTicker, buySleeveId: "us_sector_tilt",
                             buySectorRaw: targetSector.rawValue, thesis: thesis,
                             reviewDate: hasReview ? reviewDate : nil, status: .staged)
    }

    var body: some View {
        intro
        composer
        tiltComposer
        if !staged.isEmpty || !stagedTilts.isEmpty { stagedCard }
        if !committed.isEmpty { committedCard }
    }

    // MARK: tactical-tilt composer (sentiment → governed per-client tilt)

    private var tiltBudget: TiltPolicy { Seed.tiltPolicy }
    private var stageableCandidates: [TacticalTilt] {
        Seed.tacticalTilts.filter { $0.isStageable }.sorted { abs($0.netScore) > abs($1.netScore) }
    }
    private var tiltUsedBps: Bps { (committedTilts + stagedTilts).reduce(0) { $0 + abs($1.deviationBps) } }
    private func exactlyStaged(_ c: TacticalTilt) -> Bool { (committedTilts + stagedTilts).contains { $0.sourceName == c.name } }
    /// One active tilt per sleeve — the sleeve holds a single tactical bet, so a
    /// different candidate on the same sleeve can't stack on top.
    private func sleeveOccupied(_ c: TacticalTilt) -> Bool {
        guard let s = c.tiltSleeveId else { return true }
        return (committedTilts + stagedTilts).contains { $0.sleeveId == s && $0.sourceName != c.name }
    }
    private func sleeveLabel(_ id: String) -> String { Seed.legacyPolicy.sleeves.first { $0.id == id }?.label ?? id }

    private var tiltComposer: some View {
        Card("Tactical tilts — from sentiment") {
            Note("Turn a sentiment candidate (Econ → Sentiment) into a governed tilt for THIS client: a signed sleeve deviation, funded within the same role so the risk level is unchanged, carrying the candidate's thesis and a 6-month review. Committed tilts move the tactical target on the Allocation tab, within a \(Fmt.pctBps(tiltBudget.maxTotalAbsoluteDeviationBps)) total budget (\(Fmt.pctBps(tiltBudget.maxSingleSectorDeviationBps)) per tilt).")
            LedgerRow("Tilt budget used", "\(Fmt.pctBps(tiltUsedBps)) of \(Fmt.pctBps(tiltBudget.maxTotalAbsoluteDeviationBps))",
                      color: tiltUsedBps > tiltBudget.maxTotalAbsoluteDeviationBps ? Theme.debt : Theme.ink, bold: true)
            Text("STAGEABLE CANDIDATES").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.muted).padding(.top, 6)
            ForEach(stageableCandidates.prefix(10)) { c in candidateTiltRow(c) }
        }
    }

    private func candidateTiltRow(_ c: TacticalTilt) -> some View {
        let dev = c.proposedDeviationBps(maxSingleBps: tiltBudget.maxSingleSectorDeviationBps)
        let staged = exactlyStaged(c)
        let occupied = sleeveOccupied(c)
        let disabled = staged || occupied
        let label = staged ? "Staged" : (occupied ? "Sleeve used" : "Stage")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(c.stance.short).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(dev >= 0 ? Theme.asset : Theme.debt, in: Capsule())
                }
                Text("\(sleeveLabel(c.tiltSleeveId ?? "")) · \(Fmt.bpsSigned(dev))").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Button { stageTilt(c) } label: {
                Text(label).font(.system(size: 12, weight: .bold)).foregroundStyle(disabled ? Theme.muted : .white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(disabled ? Theme.card : Theme.accent, in: Capsule())
                    .overlay(disabled ? Capsule().stroke(Theme.rule) : nil)
            }.buttonStyle(.plain).disabled(disabled)
        }
        .padding(.vertical, 5)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }

    private func stageTilt(_ c: TacticalTilt) {
        guard let sleeve = c.tiltSleeveId, !exactlyStaged(c), !sleeveOccupied(c) else { return }
        let dev = c.proposedDeviationBps(maxSingleBps: tiltBudget.maxSingleSectorDeviationBps)
        let review = Calendar.current.date(byAdding: .month, value: 6, to: Date())
        stagedTilts.append(TacticalTiltAction(sleeveId: sleeve, deviationBps: dev, sourceName: c.name, thesis: c.thesis, reviewDate: review, status: .staged))
    }

    // MARK: intro

    private var intro: some View {
        Card("Planning — make a move") {
            Note("This is the only tab that changes the plan. Compose a rotation — sell a holding, buy a sector — and Stage it: the whole desk then previews the effect, non-destructively. Nothing is saved until you Commit, which records the move on this client with your thesis and a review date. The sale funds the buy; in a taxable account the realized tax is paid from the proceeds, so you reinvest the sale minus the tax — in a sheltered account the full amount rotates.")
        }
    }

    // MARK: composer

    private var composer: some View {
        Card("Compose a rotation") {
            if effSell == nil {
                Note("No sellable holdings in this plan.", icon: "tray", color: Theme.muted)
            } else {
                // Sell leg
                Text("SELL").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.muted)
                Menu {
                    ForEach(sellable, id: \.id) { p in
                        Button { sellId = p.id } label: {
                            Text("\(p.ticker) · \(accountLabel(p.accountId)) · \(Fmt.usd(p.marketValueUsd))")
                        }
                    }
                } label: {
                    HStack {
                        if let p = effSell {
                            Text(p.ticker).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                            Text("· \(accountLabel(p.accountId)) · \(Fmt.usd(p.marketValueUsd))").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 8)
                    .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
                }
                Toggle(isOn: $sellAll) { Text("Sell the entire position").font(.system(size: 14)) }
                    .tint(Theme.accent).padding(.top, 2)
                if !sellAll { MoneyField(label: "Amount to sell", value: $sellUsd) }

                // Buy leg
                Text("BUY — rotate into a sector").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.muted).padding(.top, 8)
                ChoiceChips(Sector.allCases.map { ($0, $0.label) }, selection: targetSector) { targetSector = $0 }
                Text("\(targetSector.label) · \(targetSector.spdrTicker)").font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.top, 2)

                // Thesis + review
                Text("WHY (thesis)").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.muted).padding(.top, 8)
                TextField("e.g. late-cycle rotation into defensives", text: $thesis, axis: .vertical)
                    .font(.system(size: 14)).lineLimit(1...3)
                    .padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
                Toggle(isOn: $hasReview) { Text("Set a review date").font(.system(size: 14)) }.tint(Theme.accent).padding(.top, 4)
                if hasReview {
                    DatePicker("Review by", selection: $reviewDate, displayedComponents: .date)
                        .font(.system(size: 14)).tint(Theme.accent)
                }

                candidatePreview
                Button { stage() } label: {
                    Text(candidate == nil ? "Pick a different target" : "Stage this move")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(candidate == nil ? Theme.muted : Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(candidate == nil).padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var candidatePreview: some View {
        if let c = candidate, let p = effSell {
            let t = Engine.realizedGainTax(current, c)
            let sellAmt = min(c.sellUsd, p.marketValueUsd)
            let reinvest = max(0, sellAmt - t.taxUsd)
            let isLoss = t.gainUsd < 0
            let fromSector = p.effectiveSector
            VStack(alignment: .leading, spacing: 6) {
                Text("THIS MOVE").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.muted)
                LedgerRow("Sell", "−\(Fmt.usd(sellAmt)) \(c.sellTicker)", color: Theme.debt)
                if let fs = fromSector {
                    LedgerRow("Sector tilt", "\(fs.label) → \(targetSector.label)", color: Theme.ink)
                } else {
                    LedgerRow("Into sector", targetSector.label, color: Theme.ink)
                }
                LedgerRow(isLoss ? "Realized loss" : "Unrealized gain sold",
                          Fmt.usd(t.gainUsd), color: isLoss ? Theme.debt : Theme.ink)
                if t.taxable {
                    LedgerRow("Realized tax now", Fmt.usd(t.taxUsd), color: t.taxUsd > 0 ? Theme.debt : Theme.asset, bold: true)
                    LedgerRow("Reinvested", "+\(Fmt.usd(reinvest)) \(c.buyTicker)", color: Theme.asset, bold: true)
                } else {
                    LedgerRow("Buy", "+\(Fmt.usd(sellAmt)) \(c.buyTicker)", color: Theme.asset, bold: true)
                }
                Note(taxNote(t, p), icon: t.taxable ? "percent" : "checkmark.circle", color: t.taxable ? Theme.amber : Theme.asset)
                if isLoss {
                    Note("A realized loss can offset other gains (or up to $3k of income) — that benefit isn't credited in this preview.", icon: "arrow.down.circle", color: Theme.muted)
                }
                if p.sleeveId == "us_sector_tilt" {
                    Note("Same policy sleeve (sector tilt), so the allocation percentages don't move — this is a within-sleeve sector rotation. Check Constraints for any tilt-budget flag.", icon: "info.circle", color: Theme.muted)
                }
            }
            .padding(11).background(Theme.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.rule)).padding(.top, 8)
        }
    }

    // MARK: staged

    private var stagedCard: some View {
        Card("Staged — previewing, not saved") {
            ForEach(staged) { a in moveRow(action: a, badge: "MOVE", badgeColor: Theme.amber, warning: nil) }
            ForEach(stagedTilts) { t in stagedTiltRow(t) }
            HStack {
                Button { onDiscard() } label: {
                    Text("Discard all").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.debt)
                }.buttonStyle(.plain)
                Spacer()
                Button { onCommit() } label: {
                    Label(canPersist ? "Commit to plan" : "Apply (sample)", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9).background(Theme.accent, in: Capsule())
                }.buttonStyle(.plain)
            }
            .padding(.top, 6)
            Note(canPersist ? "Commit records these on the client and rebaselines the desk." : "This is the sample — moves apply in memory only and are not saved.", icon: "lock.shield", color: Theme.muted)
        }
    }

    // MARK: committed history

    private var committedCard: some View {
        Card("Plan of record — committed moves") {
            ForEach(committed) { s in
                moveRow(action: s.action, badge: "COMMITTED", badgeColor: Theme.asset, warning: statusWarning(s))
            }
        }
    }

    private func stagedTiltRow(_ t: TacticalTiltAction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Tilt \(sleeveLabel(t.sleeveId)) \(Fmt.bpsSigned(t.deviationBps))")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
                Spacer()
                Text("TILT · \(t.sourceName)").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.accent, in: Capsule())
            }
            if !t.thesis.isEmpty {
                Text(t.thesis).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }

    private func statusWarning(_ s: CommittedMoveStatus) -> String? {
        if !s.resolved {
            return "No longer in the portfolio — an intake edit removed or renamed this holding, so the move isn't applied."
        }
        if s.clamped {
            return "Only \(Fmt.usd(s.appliedUsd)) of the \(Fmt.usd(s.action.sellUsd)) still available — the sold holding shrank, so the rotation is partial."
        }
        return nil
    }

    private func moveRow(action a: PlannedAction, badge: String, badgeColor: Color, warning: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Sell \(Fmt.usd(a.sellUsd)) \(a.sellTicker)  →  \(a.buyTicker)")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
                Spacer()
                Text(badge)
                    .font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(badgeColor, in: Capsule())
            }
            if !a.thesis.isEmpty {
                Text(a.thesis).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let r = a.reviewDate {
                Text("Review by \(r.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            if let w = warning {
                Note(w, icon: "exclamationmark.triangle", color: Theme.amber)
            }
        }
        .padding(.vertical, 7)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }

    // MARK: actions & helpers

    private func stage() {
        guard let c = candidate else { return }
        staged.append(c)
        thesis = ""; sellAll = true
    }
    private func accountLabel(_ id: String) -> String { base.account(id)?.label ?? id }
    private func taxNote(_ t: (gainUsd: Usd, taxUsd: Usd, taxable: Bool, ordinaryTaxableUsd: Usd), _ p: Position) -> String {
        if !t.taxable {
            let where_ = base.treatment(of: p) == .taxFree ? "a Roth (tax-free)" : "a tax-deferred account"
            return "Held in \(where_) — the sale realizes no current tax."
        }
        return "Estimated long-term cap-gains tax (assumes a long-term holding), stacked on ~\(Fmt.usd(t.ordinaryTaxableUsd)) of ordinary income."
    }
}
