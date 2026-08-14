//  WealthPolicyDeskApp.swift
//  Wealth Policy
//
//  Host app for the WealthPolicyDesk framework. Targets iOS 17+.
//  Display Name: "Wealth Policy".
//
//  The framework holds everything: the ported policy layer, the evaluation
//  engine, the design system, the teaching layer and the desk UI. This target
//  is a thin shell that imports it and shows `DeskView()`.

import SwiftUI
import WealthPolicyDesk

@main
struct WealthPolicyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
