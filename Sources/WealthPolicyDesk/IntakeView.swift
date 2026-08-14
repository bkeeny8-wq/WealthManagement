//  IntakeView.swift
//  WealthPolicyDesk
//
//  The entrance experience: a welcome, an 8-step questionnaire, and the routing
//  that turns answers into a live desk. RootView is the app's entry point — it
//  owns the household, loads/saves the intake on-device, and swaps between the
//  welcome, the wizard, and the desk.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Resign the first responder so the number-pad keyboard (which has no Return key)
/// can be dismissed — the fix for the form scrolling around as focus moves.
func dismissKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

// MARK: - Root (public entry point)

public struct RootView: View {
    // The book of business is the source of truth; the fields below hold whichever
    // client (or the ephemeral sample) is currently open on the desk.
    @State private var book: [ClientRecord] = []
    @State private var loaded = false
    @State private var activeId: UUID?          // which book record is on the desk (nil = sample/none)
    @State private var household: Household?     // non-nil ⇒ desk is showing
    @State private var intake: IntakeModel?      // nil ⇒ the sample (no CRM record)
    @State private var practice = PracticeMetadata()

    @State private var showWizard = false
    @State private var wizardSeed = IntakeModel()
    @State private var wizardPractice = PracticeMetadata()
    @State private var wizardEditingId: UUID?    // nil ⇒ creating a new client

    public init() {}

    public var body: some View {
        Group {
            if household != nil {
                DeskView(
                    household: Binding($household)!,
                    clientHeader: intake != nil ? practice.header : nil,
                    exportJSON: exportJSON, exportCSV: exportCSV,
                    onEditIntake: { wizardSeed = intake ?? IntakeModel(); wizardPractice = practice; wizardEditingId = activeId; showWizard = true },
                    onLoadSample: openSample,
                    onClose: closeToBook
                )
            } else {
                RosterView(
                    book: book,
                    onOpen: openClient,
                    onNew: startNewClient,
                    onSample: openSample,
                    onArchiveToggle: toggleArchive,
                    onDelete: deleteClient,
                    exportNDJSON: { BookExport.ndjson(book) },
                    exportCSV: { BookExport.csv(book) }
                )
            }
        }
        .onAppear { if !loaded { book = BookStore.load(); loaded = true } }
        .sheet(isPresented: $showWizard) {
            IntakeWizard(intake: wizardSeed, practice: wizardPractice) { builtIntake, builtPractice in
                saveFromWizard(builtIntake, builtPractice); showWizard = false
            } onCancel: { showWizard = false }
        }
    }

    // MARK: routing

    private func openClient(_ id: UUID) {
        guard let rec = book.first(where: { $0.id == id }) else { return }
        activeId = id; intake = rec.intake; practice = rec.practice
        household = rec.intake.buildHousehold()
    }
    private func startNewClient() {
        wizardSeed = IntakeModel(); wizardPractice = PracticeMetadata(); wizardEditingId = nil; showWizard = true
    }
    private func openSample() {
        activeId = nil; intake = nil; practice = PracticeMetadata(); household = Seed.sampleHousehold
    }
    private func closeToBook() {
        activeId = nil; intake = nil; practice = PracticeMetadata(); household = nil
    }
    private func toggleArchive(_ id: UUID) {
        guard let i = book.firstIndex(where: { $0.id == id }) else { return }
        book[i].archived.toggle(); book[i].touch(); BookStore.save(book)
    }
    private func deleteClient(_ id: UUID) {
        book.removeAll { $0.id == id }; BookStore.save(book)
    }

    /// Persist the wizard's result into the book — updating the edited record or
    /// appending a new one — then open it on the desk.
    private func saveFromWizard(_ builtIntake: IntakeModel, _ builtPractice: PracticeMetadata) {
        let id: UUID
        if let editId = wizardEditingId, let i = book.firstIndex(where: { $0.id == editId }) {
            book[i].intake = builtIntake; book[i].practice = builtPractice; book[i].touch()
            id = editId
        } else {
            let rec = ClientRecord(intake: builtIntake, practice: builtPractice)
            book.append(rec); id = rec.id
        }
        BookStore.save(book)
        activeId = id; intake = builtIntake; practice = builtPractice
        household = builtIntake.buildHousehold()
    }

    // MARK: per-client export (canonical plan, not live what-ifs)

    private var exportJSON: String? {
        guard let intake else { return nil }
        let eval = Engine.evaluate(intake.buildHousehold())
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(practice.exportRecord(intake: intake, evaluation: eval))).flatMap { String(data: $0, encoding: .utf8) }
    }
    private var exportCSV: String? {
        guard let intake else { return nil }
        let eval = Engine.evaluate(intake.buildHousehold())
        return CRMExportRecord.csvHeader + "\n" + practice.exportRecord(intake: intake, evaluation: eval).csvRow()
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    var onStart: () -> Void
    var onSample: () -> Void
    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                VStack(spacing: 8) {
                    Text("Wealth Policy").font(.system(size: 44, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
                    Text("A total-balance-sheet view of your plan — required return, net fixed income, tax and legacy — built from an opinionated advisory policy.")
                        .font(.system(size: 16)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        .frame(maxWidth: 520).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 12) {
                    Button(action: onStart) {
                        Text("Set up my plan").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: 360).padding(.vertical, 15)
                            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                    Button(action: onSample) {
                        Text("Explore the sample (the Harrisons)").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(maxWidth: 360).padding(.vertical, 14)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.rule))
                    }.buttonStyle(.plain)
                }
                Text(Teach.disclosure).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
                Spacer()
            }
            .padding(32)
        }
    }
}

// MARK: - Wizard

struct IntakeWizard: View {
    @State var intake: IntakeModel
    @State var practice: PracticeMetadata
    var onComplete: (IntakeModel, PracticeMetadata) -> Void
    var onCancel: () -> Void

    enum Step: Int, CaseIterable {
        case household, family, income, equity, savings, accounts, holdings, property, external, protection, goals, estate, personality, relationship, review
        var title: String {
            switch self {
            case .household: return "Household"
            case .family: return "Family"
            case .income: return "Income"
            case .equity: return "Equity comp"
            case .savings: return "Savings"
            case .accounts: return "Accounts"
            case .holdings: return "Holdings"
            case .property: return "Home & debts"
            case .external: return "Other income"
            case .protection: return "Protection"
            case .goals: return "Goals"
            case .estate: return "Estate & giving"
            case .personality: return "You & risk"
            case .relationship: return "Relationship"
            case .review: return "Review"
            }
        }
    }
    @State private var step: Step = .household

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step.rawValue), total: Double(Step.allCases.count - 1))
                    .tint(Theme.ink).padding(.horizontal, 20).padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(step.title).font(.system(size: 26, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
                        stepBody
                    }
                    .padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollDismissesKeyboard(.interactively)
                footer
            }
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("Set up my plan").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { dismissKeyboard() } }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .household {
                Button { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .household } } label: {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 15, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(Theme.ink)
            }
            Spacer()
            if step == .review {
                Button { onComplete(intake, practice) } label: {
                    Text("Build my plan").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(Theme.asset, in: Capsule())
                }.buttonStyle(.plain)
            } else {
                Button { withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .review } } label: {
                    Label("Next", systemImage: "chevron.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(Theme.ink, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Theme.paper)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .top)
    }

    @ViewBuilder private var stepBody: some View {
        switch step {
        case .household: householdStep
        case .family: familyStep
        case .income: incomeStep
        case .equity: equityStep
        case .savings: savingsStep
        case .accounts: accountsStep
        case .holdings: holdingsStep
        case .property: propertyStep
        case .external: externalStep
        case .protection: protectionStep
        case .goals: goalsStep
        case .estate: estateStep
        case .personality: personalityStep
        case .relationship: relationshipStep
        case .review: reviewStep
        }
    }

    // MARK: steps

    private var householdStep: some View {
        VStack(spacing: 14) {
            Card("About you") {
                if !intake.adults.isEmpty {
                    AdultForm(adult: $intake.adults[0], index: 0, showIncome: false)
                }
            }
            Card("Spouse / partner") {
                Toggle("Include a second adult", isOn: Binding(
                    get: { intake.adults.count > 1 },
                    set: { on in
                        if on && intake.adults.count == 1 { intake.adults.append(IntakeAdult()) }
                        else if !on && intake.adults.count > 1 { intake.adults.removeLast() }
                    })).tint(Theme.ink)
                if intake.adults.count > 1 { AdultForm(adult: $intake.adults[1], index: 1, showIncome: false) }
            }
            Card("Filing & residence") {
                ChoiceChips(FilingStatus.allCases.map { ($0, $0.rawValue.uppercased()) }, selection: intake.filingStatus) { intake.filingStatus = $0 }
                FormText(label: "State", value: $intake.state)
            }
        }
    }

    private var incomeStep: some View {
        VStack(spacing: 14) {
            ForEach(Array(intake.adults.enumerated()), id: \.element.id) { i, _ in
                Card(i == 0 ? "Your income" : "Their income") {
                    AdultForm(adult: $intake.adults[i], index: i, showIncome: true)
                }
            }
            if intake.adults.count > 1 {
                Card("Two-earner risk") {
                    FormToggle(label: "Could you live on one income if needed?", isOn: $intake.survivableOnOneIncome)
                    Note("If both incomes move together and one alone can't carry the household, the reserve should be sized to a joint income loss.")
                }
            }
        }
    }

    private var savingsStep: some View {
        Card("Savings & reserve", help: Teach.help("requiredReturn")) {
            MoneyField(label: "Real savings per year", value: $intake.annualSavingsUsd)
            MoneyField(label: "Emergency reserve target", value: $intake.emergencyReserveUsd)
            Note("Savings are added to the corpus each year until you retire — they lower the required return.")
        }
    }

    private var accountsStep: some View {
        VStack(spacing: 14) {
            Card("Account balances", help: Teach.help("balanceSheet")) {
                MoneyField(label: "Taxable brokerage", value: $intake.taxableUsd)
                MoneyField(label: "Traditional (IRA / 401k)", value: $intake.traditionalUsd)
                MoneyField(label: "Roth", value: $intake.rothUsd)
                Note("We'll shape a portfolio across these accounts from your current mix below. (Entering exact holdings can come later.)")
            }
            Card("How it's invested today") {
                PercentField(label: "Roughly what share is in stocks (vs bonds/cash)?", value: $intake.currentEquityPct)
                Note("This is your AS-IS mix — the desk compares it to the policy target, so the allocation gap is real. The rest is treated as fixed income.")
            }
            Card("Taxable cost basis") {
                PercentField(label: "Roughly how much of the taxable balance is gains?", value: $intake.taxableUnrealizedGainPct)
                Note("Drives the deferred-tax and step-up math — a low-basis taxable account is worth holding to step-up.")
            }
        }
    }

    private var propertyStep: some View {
        VStack(spacing: 14) {
            Card("Home", help: Teach.help("netFI")) {
                MoneyField(label: "Home value", value: $intake.homeValueUsd)
                MoneyField(label: "Mortgage balance", value: $intake.mortgageBalanceUsd)
                PercentField(label: "Mortgage rate", value: bpsAsPct($intake.mortgageRateBps), maxPct: 0.12)
                FormToggle(label: "Fixed rate", isOn: $intake.mortgageFixed)
            }
            Card("Other debts") {
                MoneyField(label: "HELOC drawn", value: $intake.helocUsd)
                MoneyField(label: "Other debt (auto, student…)", value: $intake.otherDebtUsd)
            }
        }
    }

    private var externalStep: some View {
        VStack(spacing: 14) {
            Card("Social Security") {
                StepperRow(label: "Planned claiming age", value: $intake.ssClaimAge, range: 62...70)
                Note("We estimate your benefit from your earnings. Delaying past your full retirement age (67) raises it ~8%/yr.")
            }
            Card("Pension") {
                MoneyField(label: "Annual pension (if any)", value: $intake.pensionAnnualUsd)
            }
        }
    }

    private var equityStep: some View {
        VStack(spacing: 14) {
            Card("Equity compensation") {
                FieldLabel("Which grants does the primary earner hold?") {
                    MultiChips(EquityGrantType.allCases.map { ($0, $0.label) }, selected: Set(intake.equityGrantTypes)) { g in
                        if let i = intake.equityGrantTypes.firstIndex(of: g) { intake.equityGrantTypes.remove(at: i) }
                        else { intake.equityGrantTypes.append(g) }
                    }
                }
                Note("Leave empty to skip. Everything below refines the mechanics — the tax traps and the diversification path.")
            }
            if !intake.equityGrantTypes.isEmpty {
                Card("Insider status & window") {
                    FormToggle(label: "Company insider / subject to blackouts", isOn: $intake.isCompanyInsider)
                    FieldLabel("Current trading window") {
                        ChoiceChips(TradingWindowStatus.allCases.map { ($0, $0.label) }, selection: intake.tradingWindow) { intake.tradingWindow = $0 }
                    }
                    FormToggle(label: "10b5-1 plan in place", isOn: $intake.has10b51Plan)
                    Note("A concentrated position under blackout can only be trimmed on a schedule set ahead of time — a 10b5-1 plan is that schedule.")
                }
                if intake.equityGrantTypes.contains(.iso) || intake.equityGrantTypes.contains(.nso) {
                    Card("Vested options") {
                        MoneyField(label: "Options value to exercise & hold", value: $intake.isoUnexercisedValueUsd)
                        Note("Adds to single-employer exposure on the balance sheet — applies to both ISOs and NSOs.")
                        if intake.equityGrantTypes.contains(.iso) {
                            FormToggle(label: "Planning an ISO exercise-and-hold this year", isOn: $intake.planningIsoExerciseAndHold)
                            if intake.planningIsoExerciseAndHold {
                                MoneyField(label: "ISO bargain element (FMV − strike)", value: $intake.isoBargainElementUsd)
                                Note("The bargain element is an AMT preference item — tax can come due with no shares sold. The desk flags it so you model the crossover first.")
                            }
                        }
                    }
                }
                if intake.equityGrantTypes.contains(.restrictedStock) || intake.equityGrantTypes.contains(.founder) {
                    Card("83(b) election") {
                        FormText(label: "Grant date if pending (YYYY-MM-DD)", value: $intake.pending83bGrantDate)
                        Note("A restricted / founder grant carries a 30-day, irrevocable 83(b) window from the grant date. Enter the date only if the window is still open.")
                    }
                }
                if intake.equityGrantTypes.contains(.espp) {
                    Card("ESPP") {
                        MoneyField(label: "Annual ESPP contribution", value: $intake.esppAnnualContributionUsd)
                        FormToggle(label: "Lookback provision", isOn: $intake.esppLookback)
                    }
                }
                Card("QSBS") {
                    FieldLabel("Could any shares qualify for QSBS (§1202)?") {
                        ChoiceChips(QsbsStatus.allCases.map { ($0, $0.label) }, selection: intake.qsbsStatus) { intake.qsbsStatus = $0 }
                    }
                    Note("If plausible, it is worth verifying — the exclusion can be large, and the tests are specific.")
                }
            }
        }
    }

    private var protectionStep: some View {
        VStack(spacing: 14) {
            Card("Disability") {
                MoneyField(label: "Group DI benefit (monthly)", value: $intake.disabilityGroupMonthlyUsd)
                MoneyField(label: "Individual DI benefit (monthly)", value: $intake.disabilityIndividualMonthlyUsd)
                FormToggle(label: "Group benefit is taxable (employer-paid premium)", isOn: $intake.disabilityBenefitsTaxable)
                FormToggle(label: "Own-occupation definition", isOn: $intake.disabilityOwnOccupation)
                Note("Disability is the income that funds the whole plan. Group-only, taxable coverage replaces ~28% less than it appears to.")
            }
            Card("Life") {
                MoneyField(label: "Life insurance in force", value: $intake.lifeInForceUsd)
                FieldLabel("Policy type") {
                    ChoiceChips(LifeKind.allCases.map { ($0, $0.label) }, selection: intake.lifeKind) { intake.lifeKind = $0 }
                }
                FormToggle(label: "Held in an irrevocable trust (ILIT)", isOn: $intake.lifeInIrrevocableTrust)
            }
            Card("Long-term care") {
                FieldLabel("Funding approach") {
                    ChoiceChips(LtcApproach.allCases.map { ($0, $0.label) }, selection: intake.ltcApproach) { intake.ltcApproach = $0 }
                }
                if intake.ltcApproach == .selfFund {
                    MoneyField(label: "Dedicated LTC reserve", value: $intake.ltcDedicatedReserveUsd)
                }
                MoneyField(label: "Estimated annual care cost", value: $intake.ltcEstimatedAnnualCostUsd)
                StepperRow(label: "Estimated duration", value: $intake.ltcEstimatedDurationYears, range: 1...10, suffix: "y")
                Note("LTC is the largest tail for a long-lived household — the desk sizes exposure against the funding approach.")
            }
            Card("Liability") {
                MoneyField(label: "Umbrella liability limit", value: $intake.umbrellaLimitUsd)
                Note("A rule of thumb sets the umbrella limit at or above net worth. The desk detects gaps — it does not quote.")
            }
        }
    }

    private var goalsStep: some View {
        VStack(spacing: 14) {
            Card("Retirement spending", help: Teach.help("requiredReturn")) {
                MoneyField(label: "Annual spending (today's $)", value: $intake.retirementSpendingUsd)
                StepperRow(label: "Retire at age", value: $intake.retirementStartAge, range: 45...75)
                StepperRow(label: "Plan to age", value: $intake.planToAge, range: 80...100)
            }
            Card("Legacy floor", help: Teach.help("requiredReturn")) {
                MoneyField(label: "Corpus to leave at the end (today's $)", value: $intake.legacyFloorUsd)
                Note("$0 spends the corpus to zero. A positive floor funds a perpetual legacy and raises the required return. (Your legacy priority below can set this for you.)")
            }
            Card("Other goals") {
                Note("Every goal is a dated claim on the same money — the honest way to see one is as a bump in the return the portfolio must earn. Tier and flexibility decide how much it costs.")
                ForEach($intake.additionalGoals) { $g in
                    AdditionalGoalForm(goal: $g) { intake.additionalGoals.removeAll { $0.id == g.id } }
                }
                Button { intake.additionalGoals.append(IntakeGoal()) } label: {
                    Label("Add a goal (home, education, sabbatical…)", systemImage: "plus.circle").font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(Theme.accent).padding(.top, 4)
            }
        }
    }

    private var holdingsStep: some View {
        VStack(spacing: 14) {
            Card("Held-away holdings we should analyze directly") {
                Note("Itemize the handful of positions that actually matter — concentrated employer stock, an inherited low-basis fund, the winner you can't bear to sell. Everything else in each account stays a clean policy-shaped proxy, so you only type what's worth typing.")
                ForEach($intake.heldAwayPositions) { $p in
                    HeldPositionForm(position: $p) { intake.heldAwayPositions.removeAll { $0.id == p.id } }
                }
                Button { intake.heldAwayPositions.append(IntakeHeldPosition()) } label: {
                    Label("Add a position", systemImage: "plus.circle").font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(Theme.accent).padding(.top, 4)
            }
            Card("Transition budget") {
                MoneyField(label: "Annual realized-gain budget", value: $intake.annualGainBudgetUsd)
                StepperRow(label: "Target transition length (years)", value: $intake.transitionTargetYears, range: 1...10)
                FieldLabel("Positions you'll never sell") {
                    ChoiceChips(PermanentHoldPolicy.allCases.map { ($0, $0.label) }, selection: intake.permanentHoldPolicy) { intake.permanentHoldPolicy = $0 }
                }
                Note("The gain budget is the tax you'll tolerate each year — it forces a low-basis book and a short target date to trade off in public.")
            }
        }
    }

    private var relationshipStep: some View {
        VStack(spacing: 14) {
            Card("The relationship") {
                FormText(label: "Advisor", value: $practice.advisorName)
                FormText(label: "Client name", value: $practice.clientName)
                FormText(label: "Email (optional)", value: Binding(get: { practice.contactEmail ?? "" }, set: { practice.contactEmail = $0.isEmpty ? nil : $0 }))
                FormText(label: "Phone (optional)", value: Binding(get: { practice.contactPhone ?? "" }, set: { practice.contactPhone = $0.isEmpty ? nil : $0 }))
            }
            Card("Pipeline") {
                FieldLabel("Stage") { ChoiceChips(ClientStage.allCases.map { ($0, $0.label) }, selection: practice.stage) { practice.stage = $0 } }
                FieldLabel("Lead source") { ChoiceChips(LeadSource.allCases.map { ($0, $0.label) }, selection: practice.leadSource) { practice.leadSource = $0 } }
                FormText(label: "Lead source detail", value: $practice.leadSourceDetail)
                FormText(label: "Next action", value: $practice.nextAction)
                Note("This is the CRM envelope — it never touches the engine, lives in its own file, and is exportable as JSON or CSV from the desk. Contact details stay on this device.")
            }
        }
    }

    private var familyStep: some View {
        VStack(spacing: 14) {
            Card("Children & dependents") {
                ForEach($intake.children) { $c in
                    ChildForm(child: $c) { intake.children.removeAll { $0.id == c.id } }
                }
                Button { intake.children.append(IntakeChild()) } label: {
                    Label("Add a child", systemImage: "plus.circle").font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(Theme.accent).padding(.top, 4)
            }
            Card("Education goals") {
                Note("Education is the one goal whose date can't move, and it grows above CPI. Enter it in today's dollars; the engine inflates each year on the education series and a 529 balance offsets it.")
                ForEach($intake.educationGoals) { $g in
                    EducationGoalForm(goal: $g) { intake.educationGoals.removeAll { $0.id == g.id } }
                }
                Button { intake.educationGoals.append(IntakeEducationGoal()) } label: {
                    Label("Add an education goal", systemImage: "plus.circle").font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(Theme.accent).padding(.top, 4)
            }
        }
    }

    private var estateStep: some View {
        VStack(spacing: 14) {
            Card("Heirs") {
                StepperRow(label: "Number of heirs", value: $intake.heirCount, range: 0...12)
                FieldLabel("Expected heir tax bracket") { ChoiceChips(HeirTaxBracket.allCases.map { ($0, $0.label) }, selection: intake.expectedHeirBracket) { intake.expectedHeirBracket = $0 } }
            }
            Card("Charitable", help: Teach.help("disposition")) {
                MoneyField(label: "Annual charitable giving", value: $intake.annualGivingUsd)
                FormToggle(label: "Eligible for QCD (IRA owner 70½+)", isOn: $intake.qcdEligible)
                if intake.qcdEligible { MoneyField(label: "Planned annual QCD", value: $intake.qcdPlannedUsd) }
                FormToggle(label: "Donor-advised fund in place", isOn: $intake.dafExists)
                if intake.dafExists { MoneyField(label: "DAF balance", value: $intake.dafBalanceUsd) }
                FieldLabel("Charitable bequest funded from") { ChoiceChips(BequestSource.allCases.map { ($0, $0.label) }, selection: intake.charitableBequestSource) { intake.charitableBequestSource = $0 } }
                Note("Route the IRA (IRD) to charity, not the taxable account — the charity pays no income tax; heirs would. Choosing taxable trips the disposition-routing flag.")
            }
            Card("Documents in place") {
                FormToggle(label: "Will", isOn: $intake.hasWill)
                FormToggle(label: "Revocable living trust", isOn: $intake.hasRevocableTrust)
                FormToggle(label: "Financial power of attorney", isOn: $intake.hasFinancialPOA)
                FormToggle(label: "Healthcare directive", isOn: $intake.hasHealthcareDirective)
                FormToggle(label: "Beneficiary designations current", isOn: $intake.beneficiaryDesignationsCurrent)
            }
        }
    }

    private var personalityStep: some View {
        VStack(spacing: 14) {
            Card("How much loss could you take?", help: Teach.help("requiredReturn")) {
                ChoiceChips([(1000, "10%"), (2000, "20%"), (3000, "30%"), (4000, "40%+")], selection: nearestTolerance) { intake.lossToleranceBps = $0 }
                Note("In a single bad year, the drop at which you'd feel you had to act. This implies a ceiling on equity.")
            }
            Card("In the last big market drop, you…") {
                ChoiceChips(PastBehavior.allCases.map { ($0, $0.label) }, selection: intake.pastBehavior) { intake.pastBehavior = $0 }
                Note("Revealed behavior tempers stated tolerance — words and actions often disagree.")
            }
            Card("What worries you more?") {
                ChoiceChips(WorryFraming.allCases.map { ($0, $0.label) }, selection: intake.worry) { intake.worry = $0 }
            }
            Card("Is leaving a legacy…") {
                ChoiceChips(LegacyPriority.allCases.map { ($0, $0.label) }, selection: intake.legacyPriority) { intake.legacyPriority = $0 }
                Note("‘Essential’ sets a legacy floor that preserves your real principal; ‘nice to have’ sets a partial floor.")
            }
            Card("Could you cut or delay spending if markets disappoint?") {
                ChoiceChips(SpendingFlexibility.allCases.map { ($0, $0.label) }, selection: intake.spendingFlexibility) { intake.spendingFlexibility = $0 }
            }
            Card("Comfort with complex / illiquid investments") {
                ChoiceChips(Appetite.allCases.map { ($0, $0.label) }, selection: intake.complexityAppetite) { intake.complexityAppetite = $0 }
            }
        }
    }

    private var reviewStep: some View {
        let h = intake.buildHousehold()
        let e = Engine.evaluate(h)
        return VStack(spacing: 14) {
            Card("Your plan at a glance") {
                LedgerRow("Investable assets", Fmt.usd(intake.totalInvestableUsd), color: Theme.asset)
                LedgerRow("After-tax net worth", Fmt.usd(e.balanceSheet.afterTaxNetWorthUsd), color: Theme.ink, bold: true)
                LedgerRow("Required real return", Fmt.pctBps(e.requiredReturn.requiredRealReturnBps), color: Theme.ink)
                LedgerRow("Net fixed income", Fmt.usd(e.netFixedIncomeUsd), color: e.netFixedIncomeUsd < 0 ? Theme.debt : Theme.asset)
                LedgerRow("Funded ratio", Fmt.pctBps(e.balanceSheet.fundedRatioBps), color: e.balanceSheet.fundedRatioBps >= 10_000 ? Theme.asset : Theme.amber)
                LedgerRow("Legacy floor", intake.legacyFloorUsd > 0 || intake.legacyPriority != .none ? Fmt.usd(h.legacyFloorUsd) : "$0", color: Theme.ink)
            }
            Note("Build the plan to open the full desk. You can change any lever afterward, or edit these answers anytime.", icon: "checkmark.circle", color: Theme.asset)
        }
    }

    // helpers
    private var nearestTolerance: Int {
        [1000, 2000, 3000, 4000].min(by: { abs($0 - intake.lossToleranceBps) < abs($1 - intake.lossToleranceBps) }) ?? 2000
    }
    private func bpsAsPct(_ b: Binding<Bps>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) / 10_000 }, set: { b.wrappedValue = Int(($0 * 10_000).rounded()) })
    }
}

// MARK: - Adult sub-form

struct AdultForm: View {
    @Binding var adult: IntakeAdult
    let index: Int
    var showIncome: Bool
    var body: some View {
        VStack(spacing: 0) {
            if !showIncome {
                FormText(label: "Name (optional)", value: $adult.name)
                StepperRow(label: "Birth year", value: $adult.birthYear, range: 1940...2010)
                StepperRow(label: "Planned retirement age", value: $adult.retirementAge, range: 45...75)
                labeledChips("Health") { ChoiceChips(HealthStatus.allCases.map { ($0, $0.rawValue.capitalized) }, selection: adult.health) { adult.health = $0 } }
            } else {
                MoneyField(label: "Base salary", value: $adult.salaryUsd)
                MoneyField(label: "Expected bonus", value: $adult.bonusUsd)
                labeledChips("Bonus swings") { ChoiceChips(BonusStability.allCases.map { ($0, $0.rawValue.capitalized) }, selection: adult.bonusStability) { adult.bonusStability = $0 } }
                labeledChips("Income character") { ChoiceChips(IncomeCharacter.allCases.map { ($0, $0.label) }, selection: adult.incomeCharacter) { adult.incomeCharacter = $0 } }
                MoneyField(label: "Employer stock (RSUs)", value: $adult.employerStockUsd)
                MoneyField(label: "Deferred cash comp", value: $adult.deferredCashUsd)
            }
        }
    }
    @ViewBuilder private func labeledChips<C: View>(_ label: String, @ViewBuilder _ chips: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.muted)
            chips()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}

// MARK: - Form controls

struct MoneyField: View {
    let label: String
    @Binding var value: Usd
    var body: some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(Theme.ink)
            Spacer(minLength: 10)
            HStack(spacing: 1) {
                Text("$").foregroundStyle(Theme.muted).font(.system(size: 15))
                TextField("0", value: $value, format: .number.precision(.fractionLength(0)))
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
                    .frame(minWidth: 90, maxWidth: 140)
            }
        }
        .padding(.vertical, 7)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}

struct PercentField: View {
    let label: String
    @Binding var value: Double     // 0..1
    var maxPct: Double = 0.95
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 14)).foregroundStyle(Theme.ink)
                Spacer()
                Text(Fmt.pct(value)).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
            }
            Slider(value: $value, in: 0...maxPct, step: 0.01).tint(Theme.ink)
        }
        .padding(.vertical, 6)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}

struct StepperRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix: String = ""
    var body: some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(Theme.ink)
            Spacer()
            Text(String(value) + suffix).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink).frame(minWidth: 52, alignment: .trailing)
            Stepper("", value: $value, in: range).labelsHidden()
        }
        .padding(.vertical, 4)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}

struct FormText: View {
    let label: String
    @Binding var value: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(Theme.ink)
            Spacer(minLength: 10)
            TextField("", text: $value).multilineTextAlignment(.trailing)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).frame(maxWidth: 180)
        }
        .padding(.vertical, 7)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}

struct FormToggle: View {
    let label: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) { Text(label).font(.system(size: 14)).foregroundStyle(Theme.ink) }
            .tint(Theme.ink).padding(.vertical, 4)
    }
}

/// A caption label above an arbitrary control (used for chip rows in forms).
struct FieldLabel<C: View>: View {
    let label: String
    @ViewBuilder var content: C
    init(_ label: String, @ViewBuilder content: () -> C) { self.label = label; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.muted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}

// MARK: - Add/remove sub-forms

struct HeldPositionForm: View {
    @Binding var position: IntakeHeldPosition
    var onRemove: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Ticker", text: $position.ticker)
                    .textInputAutocapitalization(.characters)
                    .font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                Spacer()
                Button(role: .destructive, action: onRemove) { Image(systemName: "trash").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.debt)
            }
            .padding(.vertical, 5)
            .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
            MoneyField(label: "Market value", value: $position.marketValueUsd)
            MoneyField(label: "Cost basis", value: $position.costBasisUsd)
            FieldLabel("Account") { ChoiceChips(AccountTaxTreatment.allCases.map { ($0, $0.short) }, selection: position.treatment) { position.treatment = $0 } }
            FieldLabel("Plan") { ChoiceChips(HeldPositionTreatment.allCases.map { ($0, $0.label) }, selection: position.plan) { position.plan = $0 } }
            if position.plan == .unwindScheduled {
                StepperRow(label: "Unwind over (years)", value: $position.unwindYears, range: 1...15)
            }
            FormToggle(label: "Concentrated single-name risk?", isOn: $position.isConcentrated)
        }
        .padding(11)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
    }
}

struct ChildForm: View {
    @Binding var child: IntakeChild
    var onRemove: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Name", text: $child.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button(role: .destructive, action: onRemove) { Image(systemName: "trash").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.debt)
            }
            .padding(.vertical, 5)
            .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
            StepperRow(label: "Birth year", value: $child.birthYear, range: 1990...IntakeModel.currentYear)
        }
        .padding(11)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
    }
}

struct EducationGoalForm: View {
    @Binding var goal: IntakeEducationGoal
    var onRemove: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(goal.label).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
                Spacer()
                Button(role: .destructive, action: onRemove) { Image(systemName: "trash").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.debt)
            }
            .padding(.vertical, 5)
            .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
            FieldLabel("Cost tier") {
                ChoiceChips(EducationCostPreset.allCases.map { ($0, $0.label) }, selection: goal.costPreset) { p in
                    goal.costPreset = p
                    if p != .custom { goal.annualCostTodayUsd = p.annualCostUsd }
                }
            }
            MoneyField(label: "Annual cost (today's $)", value: $goal.annualCostTodayUsd)
            StepperRow(label: "Number of years", value: $goal.years, range: 1...8)
            StepperRow(label: "Start year", value: $goal.startYear, range: IntakeModel.currentYear...(IntakeModel.currentYear + 30))
            MoneyField(label: "529 balance", value: $goal.five29BalanceUsd)
        }
        .padding(11)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
    }
}

struct AdditionalGoalForm: View {
    @Binding var goal: IntakeGoal
    var onRemove: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(goal.label.isEmpty ? goal.type.label : goal.label).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
                Spacer()
                Button(role: .destructive, action: onRemove) { Image(systemName: "trash").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.debt)
            }
            .padding(.vertical, 5)
            .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
            FieldLabel("Type") { ChoiceChips(GoalType.allCases.map { ($0, $0.label) }, selection: goal.type) { goal.type = $0 } }
            FormText(label: "Name (optional)", value: $goal.label)
            MoneyField(label: "Amount (today's $)", value: $goal.amountUsd)
            StepperRow(label: "Target year", value: $goal.targetYear, range: IntakeModel.currentYear...(IntakeModel.currentYear + 40))
            StepperRow(label: "Spread over (years)", value: $goal.spanYears, range: 1...10)
            FieldLabel("How essential?") { ChoiceChips(GoalTier.allCases.map { ($0, $0.label) }, selection: goal.tier) { goal.tier = $0 } }
        }
        .padding(11)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
    }
}
