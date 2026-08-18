//  RosterView.swift
//  WealthPolicyDesk
//
//  The book of business — the practice's home screen once it holds a client. A
//  roster of relationships, each a saved plan + CRM envelope, with the whole book
//  exportable as the interchange format a CRM would ingest. Empty, it falls back
//  to the welcome hero.

import SwiftUI

struct RosterView: View {
    let book: [ClientRecord]
    var onOpen: (UUID) -> Void
    var onNew: () -> Void
    var onEcon: () -> Void
    var onSample: () -> Void
    var onArchiveToggle: (UUID) -> Void
    var onDelete: (UUID) -> Void
    var exportNDJSON: () -> String
    var exportCSV: () -> String

    @State private var showArchived = false
    @State private var pendingDelete: UUID? = nil

    private var active: [ClientRecord] { book.filter { !$0.archived }.sorted { $0.updatedAt > $1.updatedAt } }
    private var archived: [ClientRecord] { book.filter { $0.archived }.sorted { $0.updatedAt > $1.updatedAt } }

    var body: some View {
        if book.isEmpty {
            WelcomeView(onStart: onNew, onSample: onSample, onEcon: onEcon)
        } else {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        summary
                        ForEach(active) { row($0) }
                        if !archived.isEmpty { archivedSection }
                        Text(Teach.disclosure).font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 8)
                    }
                    .padding(24)
                    .frame(maxWidth: 880, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .background(Theme.paper)
                .navigationTitle("Book of business")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onEcon) { Label("Econ", systemImage: "globe.americas") }
                            .tint(Theme.accent)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: onNew) { Label("New client", systemImage: "person.badge.plus") }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            ShareLink(item: exportNDJSON(), preview: SharePreview("Book of business (NDJSON)")) {
                                Label("Export book (NDJSON)", systemImage: "square.and.arrow.up")
                            }
                            ShareLink(item: exportCSV(), preview: SharePreview("Book of business (CSV)")) {
                                Label("Export book (CSV)", systemImage: "tablecells")
                            }
                            Divider()
                            Button(action: onSample) { Label("Explore sample (Harrisons)", systemImage: "person.2") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                .confirmationDialog("Delete this client permanently?",
                                    isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                    titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { if let id = pendingDelete { onDelete(id) }; pendingDelete = nil }
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                } message: {
                    Text("This removes the plan and CRM record from this device. It cannot be undone.")
                }
            }
        }
    }

    // MARK: book summary

    private var summary: some View {
        let investable = active.reduce(0) { $0 + $1.intake.totalInvestableUsd }
        let clients = active.filter { $0.practice.stage == .client }.count
        let prospects = active.filter { $0.practice.stage == .prospect }.count
        return HStack(spacing: 10) {
            stat("Relationships", "\(active.count)", Theme.ink)
            stat("Clients", "\(clients)", Theme.asset)
            stat("Prospects", "\(prospects)", Theme.accent)
            stat("Investable", Fmt.usdShort(investable), Theme.ink)
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.rule))
    }

    // MARK: one relationship

    private func row(_ rec: ClientRecord) -> some View {
        let intake = rec.intake
        let tier = IntakeModel.tier(forInvestable: intake.totalInvestableUsd)
        let hard = Engine.evaluate(intake.buildHousehold()).findings.filter { $0.severity == .hard }.count
        return Button { onOpen(rec.id) } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(rec.displayName).font(.system(size: 18, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
                        stageBadge(rec.practice.stage)
                    }
                    Text(subtitle(rec)).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    if !rec.practice.nextAction.isEmpty {
                        Label(rec.practice.nextAction, systemImage: "arrow.turn.down.right")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Fmt.usdShort(intake.totalInvestableUsd)).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                    Text(tier).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                    if hard > 0 {
                        Text("\(hard) hard").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.debt, in: Capsule())
                    }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.rule))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { onArchiveToggle(rec.id) } label: {
                Label(rec.archived ? "Unarchive" : "Archive", systemImage: rec.archived ? "tray.and.arrow.up" : "archivebox")
            }
            Button(role: .destructive) { pendingDelete = rec.id } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func subtitle(_ rec: ClientRecord) -> String {
        let advisor = rec.practice.advisorName.isEmpty ? "Unassigned" : rec.practice.advisorName
        let updated = rec.updatedAt.formatted(date: .abbreviated, time: .omitted)
        return "\(advisor) · \(rec.practice.leadSource.label) · updated \(updated)"
    }

    private func stageBadge(_ stage: ClientStage) -> some View {
        let color: Color = stage == .client ? Theme.asset : (stage == .onboarding ? Theme.amber : Theme.accent)
        return Text(stage.label.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3).background(color, in: Capsule())
    }

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation { showArchived.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showArchived ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .bold))
                    Text("Archived (\(archived.count))").font(.system(size: 13, weight: .semibold))
                }.foregroundStyle(Theme.muted)
            }.buttonStyle(.plain).padding(.top, 6)
            if showArchived { ForEach(archived) { row($0).opacity(0.62) } }
        }
    }
}
