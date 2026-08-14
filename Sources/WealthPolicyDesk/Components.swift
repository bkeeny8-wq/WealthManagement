//  Components.swift
//  WealthPolicyDesk
//
//  The reusable pieces of the advisory-ledger look: paper cards with serif
//  clause headers, monospaced tabular figures, ledger-green / loss-red legs,
//  and the tappable ⓘ teaching disclosure. Layout only — all copy lives in
//  Teach.swift.

import SwiftUI

// MARK: - Card

/// A titled paper card with an optional ⓘ that expands into three teaching
/// paragraphs (what it is, which way it moves, what to watch).
public struct Card<Content: View>: View {
    let title: String
    var help: BlockHelp? = nil
    @ViewBuilder var content: Content
    @State private var helpOpen = false
    public init(_ title: String, help: BlockHelp? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.help = help; self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title).font(.system(.title3, design: .serif).weight(.semibold)).foregroundStyle(Theme.ink)
                if let h = help { HelpDisclosure(help: h, open: $helpOpen) }
                Spacer(minLength: 0)
            }
            if helpOpen, let h = help { HelpBody(help: h) }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.rule))
    }
}

// MARK: - Teaching disclosure

public struct HelpDisclosure: View {
    let help: BlockHelp
    @Binding var open: Bool
    public var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: open ? "info.circle.fill" : "info.circle")
                .font(.system(size: 16)).foregroundStyle(open ? Theme.accent : Theme.muted)
        }.buttonStyle(.plain)
    }
}

public struct HelpBody: View {
    let help: BlockHelp
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([("WHAT IT IS", help.what), ("WHY IT MATTERS", help.moves), ("WATCH", help.watch)], id: \.0) { head, body in
                if !body.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(head).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.accent)
                        Text(body).font(.system(size: 13.5)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.955, green: 0.965, blue: 0.98), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Stat tiles

public struct StatTile: View {
    let title: String
    let value: String
    var sub: String = ""
    var color: Color = Theme.ink
    public init(_ title: String, _ value: String, sub: String = "", color: Color = Theme.ink) {
        self.title = title; self.value = value; self.sub = sub; self.color = color
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted).lineLimit(1)
            Text(value).lineLimit(1).minimumScaleFactor(0.5)
                .font(.system(size: 25, weight: .bold, design: .monospaced)).foregroundStyle(color)
            if !sub.isEmpty { Text(sub).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(13).frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.rule))
    }
}

/// Responsive grid of stat tiles: flows 2-up when narrow (portrait / inspector
/// open) and up to 4-up when the detail column is wide (landscape).
public struct StatGrid: View {
    let tiles: [StatTile]
    var minTileWidth: CGFloat = 160
    public init(minTileWidth: CGFloat = 160, _ tiles: [StatTile]) { self.minTileWidth = minTileWidth; self.tiles = tiles }
    public var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minTileWidth), spacing: 8)], spacing: 8) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { $0.element }
        }
    }
}

// MARK: - Ledger rows

/// A label + right-aligned monospaced figure, with a hairline rule beneath —
/// the atomic unit of a balance sheet or attribution table.
public struct LedgerRow: View {
    let label: String
    let value: String
    var color: Color = Theme.ink
    var indent: CGFloat = 0
    var bold: Bool = false
    public init(_ label: String, _ value: String, color: Color = Theme.ink, indent: CGFloat = 0, bold: Bool = false) {
        self.label = label; self.value = value; self.color = color; self.indent = indent; self.bold = bold
    }
    public var body: some View {
        HStack {
            Text(label).font(.system(size: 15, weight: bold ? .semibold : .regular)).foregroundStyle(bold ? Theme.ink : Theme.ink.opacity(0.85))
                .padding(.leading, indent)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 15.5, weight: .bold, design: .monospaced)).foregroundStyle(color)
        }
        .padding(.vertical, 6.5)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}

// MARK: - Severity badge & finding card

public struct SeverityBadge: View {
    let severity: Severity
    public init(_ s: Severity) { self.severity = s }
    public var body: some View {
        Text(severity == .hard ? "HARD" : "SOFT")
            .font(.system(size: 10.5, weight: .heavy)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.severityColor(severity), in: Capsule())
    }
}

public struct FindingCard: View {
    let finding: Finding
    public init(_ f: Finding) { self.finding = f }
    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                SeverityBadge(finding.severity)
                Text(finding.module.rawValue.uppercased()).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.muted)
                Spacer()
            }
            Text(finding.title).font(.system(size: 16.5, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
            Text(finding.detail).font(.system(size: 13.5)).foregroundStyle(Theme.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.severityColor(finding.severity).opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.severityColor(finding.severity).opacity(0.35)))
    }
}

// MARK: - Bars

/// Horizontal stacked bar of labelled dollar segments. The signature
/// balance-sheet / allocation element.
public struct StackSegment: Identifiable {
    public let id = UUID()
    public let label: String
    public let value: Double
    public let color: Color
    public init(_ label: String, _ value: Double, _ color: Color) { self.label = label; self.value = value; self.color = color }
}

public struct StackBar: View {
    let segments: [StackSegment]
    var height: CGFloat = 26
    public init(_ segments: [StackSegment], height: CGFloat = 26) { self.segments = segments; self.height = height }
    public var body: some View {
        let total = max(1, segments.reduce(0) { $0 + abs($1.value) })
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments.filter { abs($0.value) / total > 0.005 }) { s in
                    Rectangle().fill(s.color)
                        .frame(width: max(2, geo.size.width * abs(s.value) / total))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.rule))
    }
}

/// A drift meter: a centered target with an inner and outer band, and a marker
/// at the current deviation.
public struct DriftMeter: View {
    let driftBps: Int
    let innerBps: Int
    let outerBps: Int
    public init(driftBps: Int, innerBps: Int, outerBps: Int) { self.driftBps = driftBps; self.innerBps = innerBps; self.outerBps = outerBps }
    public var body: some View {
        let scale = Double(max(outerBps, abs(driftBps)) + 50)
        GeometryReader { geo in
            let w = geo.size.width
            let mid = w / 2
            let pos = mid + CGFloat(Double(driftBps) / scale) * (w / 2)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.rule.opacity(0.5)).frame(height: 6)
                // inner band
                Rectangle().fill(Theme.asset.opacity(0.18))
                    .frame(width: CGFloat(Double(innerBps) / scale) * w, height: 6)
                    .offset(x: mid - CGFloat(Double(innerBps) / scale) * (w / 2))
                Rectangle().fill(Theme.ink.opacity(0.5)).frame(width: 1, height: 14).offset(x: mid - 0.5)
                Circle().fill(driftColor).frame(width: 11, height: 11).offset(x: pos - 5.5)
            }
        }.frame(height: 16)
    }
    private var driftColor: Color {
        abs(driftBps) >= outerBps ? Theme.debt : (abs(driftBps) >= innerBps ? Theme.amber : Theme.asset)
    }
}

// MARK: - Chips & selectors

public struct ChoiceChips<T: Hashable>: View {
    let options: [(T, String)]
    let selection: T
    let pick: (T) -> Void
    public init(_ options: [(T, String)], selection: T, pick: @escaping (T) -> Void) {
        self.options = options; self.selection = selection; self.pick = pick
    }
    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(options, id: \.0) { opt in
                    Button { pick(opt.0) } label: {
                        Text(opt.1).font(.system(size: 14.5, weight: .semibold))
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .background(selection == opt.0 ? Theme.ink : Theme.card, in: Capsule())
                            .foregroundStyle(selection == opt.0 ? Color.white : Theme.ink)
                            .overlay(Capsule().stroke(selection == opt.0 ? Theme.ink : Theme.rule))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

/// Horizontal capsule chips with multi-selection (membership in a set).
public struct MultiChips<T: Hashable>: View {
    let options: [(T, String)]
    let selected: Set<T>
    let toggle: (T) -> Void
    public init(_ options: [(T, String)], selected: Set<T>, toggle: @escaping (T) -> Void) {
        self.options = options; self.selected = selected; self.toggle = toggle
    }
    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(options, id: \.0) { opt in
                    let on = selected.contains(opt.0)
                    Button { toggle(opt.0) } label: {
                        Text(opt.1).font(.system(size: 14.5, weight: .semibold))
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .background(on ? Theme.ink : Theme.card, in: Capsule())
                            .foregroundStyle(on ? Color.white : Theme.ink)
                            .overlay(Capsule().stroke(on ? Theme.ink : Theme.rule))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Misc

/// A small labelled callout (rationale, note, disclosure).
public struct Note: View {
    let text: String
    var icon: String = "text.quote"
    var color: Color = Theme.muted
    public init(_ text: String, icon: String = "text.quote", color: Color = Theme.muted) {
        self.text = text; self.icon = icon; self.color = color
    }
    public var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(color).padding(.top, 1.5)
            Text(text).font(.system(size: 13)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A big headline figure with a caption, for the anchor number on a tab.
public struct HeadlineFigure: View {
    let value: String
    let caption: String
    var color: Color = Theme.ink
    public init(_ value: String, caption: String, color: Color = Theme.ink) { self.value = value; self.caption = caption; self.color = color }
    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 42, weight: .heavy, design: .monospaced)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(caption).font(.system(size: 14)).foregroundStyle(Theme.muted)
        }
    }
}
