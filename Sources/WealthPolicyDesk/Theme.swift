//  Theme.swift
//  WealthPolicyDesk
//
//  The design language: an advisory ledger / IPS document. Paper surface, serif
//  clause headers, monospaced tabular figures, ledger-green for assets, loss-red
//  for debt and violations.

import SwiftUI

public enum Theme {
    // Paper palette.
    public static let paper = Color(red: 0.969, green: 0.965, blue: 0.945)
    public static let card = Color.white
    public static let ink = Color(red: 0.11, green: 0.125, blue: 0.115)
    public static let rule = Color(red: 0.86, green: 0.855, blue: 0.82)

    // Semantic colors.
    public static let asset = Color(red: 0.04, green: 0.42, blue: 0.30)   // ledger green
    public static let debt = Color(red: 0.70, green: 0.23, blue: 0.18)    // loss red
    public static let accent = Color(red: 0.13, green: 0.35, blue: 0.62)  // ink blue
    public static let amber = Color(red: 0.73, green: 0.50, blue: 0.09)
    public static let muted = Color(red: 0.55, green: 0.53, blue: 0.46)

    public static func severityColor(_ s: Severity) -> Color { s == .hard ? debt : amber }
}
