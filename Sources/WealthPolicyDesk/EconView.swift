//  EconView.swift
//  WealthPolicyDesk
//
//  The Econ desk — the firm-wide market & economy backdrop, identical for every
//  client because the cycle isn't per-account. It lives at the app's TOP LEVEL,
//  reached from the Book of Business, deliberately separate from any one client's
//  desk. One scroll, two sections: the Macro inning (where the US cycle sits) and
//  the tactical Sentiment board (equity & bond tilts the inning conditions).
//
//  Both sub-views are household-independent — they read the dated Seed catalogs
//  directly — which is exactly why they don't belong on a client's account pages.

import SwiftUI

struct EconView: View {
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    masthead
                    MacroTab()
                    SentimentTab()
                }
                .padding(24)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Theme.paper)
            .navigationTitle("Econ")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { onClose() } label: { Label("Book of business", systemImage: "rectangle.stack") }
                }
            }
        }
        .tint(Theme.accent)
    }

    /// A short masthead that frames the whole tab as the shared backdrop, so it's
    /// never mistaken for a client-specific read.
    private var masthead: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Econ").font(.system(size: 19, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
                    Text("FIRM-WIDE").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.accent, in: Capsule())
                }
                Text("The market & economy backdrop — the same for every client. A regime read that conditions each plan's tilts, never a client deliverable on its own.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.rule))
    }
}
