//  LearnTab.swift
//  WealthPolicyDesk

import SwiftUI

struct LearnTab: View {
    @State private var openLesson: Int? = 1
    @State private var openTerm: String? = nil

    var body: some View {
        Card("The philosophy, in one paragraph") {
            Text(Seed.legacyPolicy.statement)
                .font(.system(size: 14.5, design: .serif)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("GUIDED LESSONS").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted).padding(.top, 4)
        ForEach(Teach.lessons) { lesson in
            lessonCard(lesson)
        }

        Text("GLOSSARY — plain / desk").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted).padding(.top, 8)
        Card("Two registers for the same idea") {
            ForEach(Teach.glossary) { term in
                VStack(alignment: .leading, spacing: 3) {
                    Button { withAnimation { openTerm = (openTerm == term.name) ? nil : term.name } } label: {
                        HStack {
                            Text(term.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                            Spacer()
                            Image(systemName: openTerm == term.name ? "chevron.down" : "chevron.right").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                    }.buttonStyle(.plain)
                    if openTerm == term.name {
                        Text(term.plain).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                        Text(term.desk).font(.system(size: 13, design: .serif)).italic().foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
                .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
            }
        }

        Note(Teach.disclosure, icon: "info.circle", color: Theme.muted)
    }

    private func lessonCard(_ lesson: Lesson) -> some View {
        let open = openLesson == lesson.number
        return Card("\(lesson.number). \(lesson.title)") {
            Button { withAnimation { openLesson = open ? nil : lesson.number } } label: {
                HStack {
                    Text(lesson.goal).font(.system(size: 13.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
            }.buttonStyle(.plain)
            if open {
                ForEach(Array(lesson.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(i + 1)").font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                            .frame(width: 19, height: 19).background(Theme.accent, in: Circle())
                        Text(step).font(.system(size: 13)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Note(lesson.takeaway, icon: "lightbulb", color: Theme.asset)
            }
        }
    }
}
