//  PlanSummaryPDF.swift
//  WealthPolicyDesk
//
//  Turns the on-screen Investment Policy Statement into a real, multi-page US-Letter
//  PDF the advisor can hand a client. It renders the SAME card views the Plan Summary
//  tab shows (so the paper matches the screen), measuring each card and packing whole
//  cards onto pages — a card is never split across a page break. Vector text, on-device,
//  no network; the file lands in a temp directory and is shared through the system sheet.

import SwiftUI
import UIKit

enum PlanSummaryPDF {
    // US Letter at 72 dpi.
    private static let pageW: CGFloat = 612
    private static let pageH: CGFloat = 792
    private static let margin: CGFloat = 40
    private static let gap: CGFloat = 14

    /// Render the ordered IPS blocks into a paginated PDF; returns the file URL.
    @MainActor
    static func render(blocks: [AnyView], fileName: String) -> URL? {
        guard !blocks.isEmpty else { return nil }
        let contentW = pageW - margin * 2
        let maxH = pageH - margin * 2

        // 1) Measure each block at the page's content width.
        var items: [(view: AnyView, height: CGFloat)] = []
        for b in blocks {
            let sized = AnyView(b.frame(width: contentW))
            let mr = ImageRenderer(content: sized)
            var h: CGFloat = 0
            mr.render { size, _ in h = size.height }
            items.append((sized, h))
        }

        // 2) Greedily pack whole blocks onto pages (never split a card).
        var pages: [[AnyView]] = []
        var current: [AnyView] = []
        var used: CGFloat = 0
        for item in items {
            let need = current.isEmpty ? item.height : used + gap + item.height
            if need > maxH && !current.isEmpty {
                pages.append(current); current = []; used = 0
            }
            used = current.isEmpty ? item.height : used + gap + item.height
            current.append(item.view)
        }
        if !current.isEmpty { pages.append(current) }

        // 3) Draw each page into the PDF context.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        for page in pages {
            let pageView = ZStack(alignment: .topLeading) {
                Theme.paper
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(0..<page.count, id: \.self) { page[$0] }
                }
                .padding(margin)
            }
            .frame(width: pageW, height: pageH, alignment: .topLeading)

            let pr = ImageRenderer(content: pageView)
            pr.render { _, drawInContext in
                ctx.beginPDFPage(nil)
                drawInContext(ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return url
    }

    /// Which client document is being exported — they must NOT share a filename, or the
    /// second export overwrites the first in the temp directory and a pending share sheet
    /// can hand off the wrong governing document.
    enum Kind {
        case policyStatement   // the CFA narrative — THE Investment Policy Statement
        case planSummary       // the one-page card dashboard
        var base: String { self == .policyStatement ? "Investment Policy Statement" : "Plan Summary" }
    }

    /// A filesystem-safe, per-document filename, e.g. "Investment Policy Statement - <name>.pdf".
    static func fileName(for clientName: String, kind: Kind = .policyStatement) -> String {
        let cleaned = clientName.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: " ")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(kind.base) - \(trimmed.isEmpty ? "Client" : trimmed).pdf"
    }
}

/// Identifiable wrapper so a generated file URL can drive a `.sheet(item:)`.
struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

/// Minimal system share sheet for a generated file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
