// swift-tools-version:5.9
//
//  Package.swift — a test harness for the ENGINE only.
//
//  The app ships as the hand-generated WealthPolicyDesk.xcodeproj (framework + Example
//  host). This package exists purely to unit-test the pure engine: it compiles the 36
//  Foundation-only source files (no SwiftUI) into a `WealthPolicyDesk` module and runs
//  `swift test` natively on macOS — fast, no simulator. The SwiftUI view files are NOT
//  listed here (they need UIKit and are exercised in-app). When a new ENGINE file is
//  added under Sources/WealthPolicyDesk, add it to `sources` below.
//
//  Run:  swift test
//
import PackageDescription

let package = Package(
    name: "WealthPolicyDesk",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "WealthPolicyDesk",
            path: "Sources/WealthPolicyDesk",
            exclude: ["WealthPolicyDesk.h"],
            sources: [
                "AllocationSolver.swift", "Book.swift", "CapitalMarketModel.swift", "CapitalMarketRisk.swift",
                "Decumulation.swift", "Engine.swift", "EngineAnalyses.swift", "EquityCompModel.swift",
                "EquityStyleModel.swift",
                "ExposureLookthrough.swift", "ExposureModel.swift", "FactorLookthrough.swift", "FixedIncomeModel.swift",
                "FrontierModel.swift", "HouseholdModel.swift", "HouseholdOverrides.swift", "IPSReview.swift",
                "IntakeModel.swift", "LayerModel.swift", "MacroIndicators.swift", "MacroModel.swift",
                "OwnershipModel.swift", "Planning.swift", "PolicyModel.swift", "PortfolioModel.swift", "PracticeMetadata.swift",
                "RebalanceModel.swift", "Resilience.swift", "RiskScale.swift", "Seed.swift",
                "ShortfallModel.swift", "TacticalModel.swift", "TacticalTilts.swift", "TaxLotModel.swift",
                "TaxModel.swift", "Teach.swift", "Units.swift", "WealthGlideModel.swift",
            ]
        ),
        .testTarget(
            name: "WealthPolicyDeskTests",
            dependencies: ["WealthPolicyDesk"],
            path: "Tests/WealthPolicyDeskTests"
        ),
    ]
)
