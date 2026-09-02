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
    @State private var showEcon = false          // the firm-wide Econ backdrop, top-level (no client)
    @State private var wizardSeed = IntakeModel()
    @State private var wizardPractice = PracticeMetadata()
    @State private var wizardEditingId: UUID?    // nil ⇒ creating a new client

    public init() {}

    public var body: some View {
        Group {
            if household != nil {
                DeskView(
                    // A safe non-optional binding: the desk only shows while `household`
                    // is non-nil, but presenting a cover/sheet can trigger a transient
                    // re-layout where a force-unwrapped optional binding would trap.
                    household: Binding(get: { household ?? Seed.sampleHousehold }, set: { household = $0 }),
                    clientHeader: intake != nil ? practice.header : nil,
                    exportJSON: exportJSON, exportCSV: exportCSV,
                    committedStatuses: activeCommittedStatuses,
                    canPersist: activeId != nil,
                    onCommit: commitActions,
                    onCommitTilts: commitTilts,
                    onEditIntake: { wizardSeed = intake ?? IntakeModel(); wizardPractice = practice; wizardEditingId = activeId; showWizard = true },
                    currentHoldings: intake?.heldAwayPositions ?? [],
                    onUpdateHoldings: updateHoldings,
                    onLoadSample: openSample,
                    onClose: closeToBook,
                    onEcon: { showEcon = true },
                    onCommitOverrides: commitOverrides,
                    onResetOverrides: resetOverrides,
                    reviews: activeReviews,
                    onSaveReview: saveReview
                )
                // Client-scoped identity: switching client (or to the sample) rebuilds the desk
                // fresh so its @State (staged edits, review note/checkboxes) never leaks across.
                .id(activeId)
            } else {
                RosterView(
                    book: book,
                    onOpen: openClient,
                    onNew: startNewClient,
                    onEcon: { showEcon = true },
                    onSample: openSample,
                    onArchiveToggle: toggleArchive,
                    onDelete: deleteClient,
                    exportNDJSON: { BookExport.ndjson(book) },
                    exportCSV: { BookExport.csv(book) }
                )
            }
        }
        .onAppear { if !loaded { book = BookStore.load(); loaded = true } }
        .fullScreenCover(isPresented: $showEcon) {
            EconView(onClose: { showEcon = false })
        }
        // Full-screen (not a sheet): the intake is a long single page, and a form-sheet's
        // swipe/tap-outside dismissal would silently discard everything typed so far.
        .fullScreenCover(isPresented: $showWizard) {
            IntakeWizard(intake: wizardSeed, practice: wizardPractice) { builtIntake, builtPractice in
                saveFromWizard(builtIntake, builtPractice); showWizard = false
            } onCancel: { showWizard = false }
        }
    }

    // MARK: routing

    private func openClient(_ id: UUID) {
        guard let rec = book.first(where: { $0.id == id }) else { return }
        activeId = id; intake = rec.intake; practice = rec.practice
        household = rec.household()
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
        // Keep any committed moves layered on the freshly rebuilt household.
        household = book.first(where: { $0.id == id })?.household() ?? builtIntake.buildHousehold()
    }

    /// Commit staged moves onto the open client's plan of record, persist, and
    /// rebuild the household so the desk shows the new baseline. For the sample
    /// (no book record) the moves apply in memory only — nothing is persisted.
    private func commitActions(_ committed: [PlannedAction]) {
        guard !committed.isEmpty else { return }
        if let id = activeId, let i = book.firstIndex(where: { $0.id == id }) {
            book[i].actions.append(contentsOf: committed)
            book[i].touch()
            BookStore.save(book)
            household = book[i].household()
        } else {
            household = (household ?? Seed.sampleHousehold).applying(committed)
        }
    }

    /// Persist committed tactical tilts onto the open client's plan of record (or,
    /// for the sample, apply them in memory only).
    private func commitTilts(_ committed: [TacticalTiltAction]) {
        guard !committed.isEmpty else { return }
        if let id = activeId, let i = book.firstIndex(where: { $0.id == id }) {
            book[i].tilts.append(contentsOf: committed)
            book[i].touch()
            BookStore.save(book)
            household = book[i].household()
        } else {
            var h = household ?? Seed.sampleHousehold
            h.tacticalTilts.append(contentsOf: committed)
            household = h
        }
    }

    /// Persist foundational-assumption edits (legacy floor, risk tolerance) made from the
    /// Policy Statement onto the open client's plan of record (or, for the sample, in memory).
    private func commitOverrides(_ o: HouseholdOverrides) {
        guard !o.isEmpty else { return }
        if let id = activeId, let i = book.firstIndex(where: { $0.id == id }) {
            book[i].driverOverrides.merge(o)
            book[i].touch()
            BookStore.save(book)
            household = book[i].household()
        } else if let h = household {
            household = h.withDriverOverrides(o)
        }
    }

    /// Clear all foundational-assumption edits, returning to the standardized,
    /// intake-derived plan (or, for the sample, the seed household).
    private func resetOverrides() {
        if let id = activeId, let i = book.firstIndex(where: { $0.id == id }) {
            book[i].driverOverrides = HouseholdOverrides()
            book[i].touch()
            BookStore.save(book)
            household = book[i].household()
        } else {
            household = Seed.sampleHousehold
        }
    }

    /// Replace the open client's itemized holdings (from the Portfolio tab), persist, and
    /// rebuild so the desk re-derives against the real book. Sample has no record — no-op.
    private func updateHoldings(_ holdings: [IntakeHeldPosition]) {
        guard let id = activeId, let i = book.firstIndex(where: { $0.id == id }) else { return }
        book[i].intake.heldAwayPositions = holdings
        book[i].touch()
        BookStore.save(book)
        intake = book[i].intake
        household = book[i].household()
    }

    /// Commit any staged driver edits and snapshot the resulting plan as a dated review.
    private func saveReview(_ staged: HouseholdOverrides, note: String, confirmed: [String]) {
        guard let id = activeId, let i = book.firstIndex(where: { $0.id == id }) else {
            if let h = household { household = h.withDriverOverrides(staged) }   // sample: apply, no review saved
            return
        }
        book[i].driverOverrides.merge(staged)
        let hh = book[i].household()
        book[i].reviews.append(IPSReview.from(Engine.evaluate(hh), overrides: book[i].driverOverrides, at: Date(),
                                              note: note, confirmedSections: confirmed))
        book[i].touch()
        BookStore.save(book)
        household = hh
    }

    private var activeReviews: [IPSReview] {
        guard let id = activeId else { return [] }
        return book.first(where: { $0.id == id })?.reviews ?? []
    }

    private var activeCommittedActions: [PlannedAction] {
        guard let id = activeId else { return [] }
        return book.first(where: { $0.id == id })?.committedActions ?? []
    }
    private var activeCommittedStatuses: [CommittedMoveStatus] {
        guard let id = activeId else { return [] }
        return book.first(where: { $0.id == id })?.committedStatuses() ?? []
    }
    private var activeCommittedTilts: [TacticalTiltAction] {
        guard let id = activeId else { return [] }
        return book.first(where: { $0.id == id })?.committedTilts ?? []
    }

    // MARK: per-client export (canonical plan, not live what-ifs)

    /// The household of record for export — committed moves AND tilts applied, so
    /// the desk export matches the roster (whole-book) export for the same client.
    private func exportHousehold(_ intake: IntakeModel) -> Household {
        var h = intake.buildHousehold().applying(activeCommittedActions)
        h.tacticalTilts = activeCommittedTilts
        return h
    }

    private var exportJSON: String? {
        guard let intake else { return nil }
        let eval = Engine.evaluate(exportHousehold(intake))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(practice.exportRecord(intake: intake, evaluation: eval))).flatMap { String(data: $0, encoding: .utf8) }
    }
    private var exportCSV: String? {
        guard let intake else { return nil }
        let eval = Engine.evaluate(exportHousehold(intake))
        return CRMExportRecord.csvHeader + "\n" + practice.exportRecord(intake: intake, evaluation: eval).csvRow()
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    var onStart: () -> Void
    var onSample: () -> Void
    var onEcon: () -> Void = {}
    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                VStack(spacing: 8) {
                    Text("Wealth Policy").font(.system(size: 44, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
                    Text("Answer a short intake and it drafts a full Investment Policy Statement — your objectives, constraints, and strategic allocation — which you can then walk, edit live, export, and review year over year.")
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
                    Button(action: onEcon) {
                        Label("See the Econ backdrop", systemImage: "globe.americas")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                    }.buttonStyle(.plain).padding(.top, 2)
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
            case .review: return "Your policy statement"
            }
        }
    }
    @State private var visibleSection: Step = .household   // for the rail highlight
    @State private var scrollTarget: Step? = nil           // a rail tap requests a jump here
    @State private var viewportH: CGFloat = 0              // content scroll-view height
    @State private var reviewVisible = false               // gate for the heavy review evaluate
    @State private var dirty = false
    @State private var confirmCancel = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    sectionRail()
                    Divider().overlay(Theme.rule)
                    // The reader wraps ONLY the content scroll view (not the rail's own
                    // scroll view), so a jump is never ambiguous about what to move.
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 30) {
                                ForEach(Step.allCases, id: \.self) { s in
                                    VStack(alignment: .leading, spacing: 14) {
                                        sectionHeader(s)
                                        sectionContent(s)
                                    }
                                    .frame(maxWidth: 720, alignment: .leading)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .id(s)
                                    .background(sectionVisibilityReader(s))
                                }
                                createFooter
                                    .frame(maxWidth: 720, alignment: .leading)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 40)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .coordinateSpace(name: "intakeScroll")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ViewportHeightKey.self, value: g.size.height)
                        })
                        .onPreferenceChange(ViewportHeightKey.self) { viewportH = $0 }
                        .onPreferenceChange(SectionOffsetKey.self) { updateVisible($0) }
                        .onChange(of: scrollTarget) { _, target in
                            guard let target else { return }
                            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
                            scrollTarget = nil
                        }
                    }
                }
                actionBar
            }
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("Set up my plan").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { dismissKeyboard() } }
            }
            .onChange(of: intake) { dirty = true }
            .onChange(of: practice) { dirty = true }
            .confirmationDialog("Discard this plan?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Discard", role: .destructive, action: onCancel)
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Nothing you've entered has been saved yet.")
            }
        }
    }

    // A leading rail of every section — the "whole page" made navigable. Tapping
    // jumps to that section; the rail tracks which one you're reading.
    private func sectionRail() -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Step.allCases, id: \.self) { s in
                    Button {
                        dismissKeyboard()
                        visibleSection = s      // immediate highlight; auto-tracking corrects as it scrolls
                        scrollTarget = s        // requests the content reader to jump
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(s.rawValue + 1)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(visibleSection == s ? Color.white : Theme.muted)
                                .frame(width: 20, height: 20)
                                .background(visibleSection == s ? Theme.ink : Theme.card, in: Circle())
                            Text(s.title)
                                .font(.system(size: 13, weight: visibleSection == s ? .semibold : .regular))
                                .foregroundStyle(visibleSection == s ? Theme.ink : Theme.muted)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 7).padding(.horizontal, 10)
                        .background(visibleSection == s ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(.vertical, 14).padding(.horizontal, 8)
        }
        .frame(width: 208)
        .background(Theme.paper)
    }

    private func sectionHeader(_ s: Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(s.rawValue + 1)").font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Theme.muted)
            Text(s.title).font(.system(size: 26, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
        }
    }

    private var createFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            Note("Creating it opens the statement on the desk. From there you can walk it, adjust any driver live, export it as a PDF, and save annual reviews — nothing here is locked.", icon: "doc.richtext", color: Theme.accent)
            Button { onComplete(intake, practice) } label: {
                Label("Create my policy statement", systemImage: "doc.richtext")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Theme.asset, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
        }
    }

    // Pinned action bar: Cancel (with a discard guard) + the primary create action.
    private var actionBar: some View {
        HStack {
            Button { if dirty { confirmCancel = true } else { onCancel() } } label: {
                Text("Cancel").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            }.buttonStyle(.plain)
            Spacer()
            Button { onComplete(intake, practice) } label: {
                Label("Create my policy statement", systemImage: "doc.richtext")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 11)
                    .background(Theme.asset, in: Capsule())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Theme.paper)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .top)
    }

    /// Reports each section's top offset in the scroll's coordinate space, so the rail
    /// can highlight whichever section header last crossed the top of the viewport.
    private func sectionVisibilityReader(_ s: Step) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: SectionOffsetKey.self,
                                   value: [SectionOffset(step: s, top: geo.frame(in: .named("intakeScroll")).minY)])
        }
    }
    private func updateVisible(_ offsets: [SectionOffset]) {
        // The current section is the last one whose header has scrolled to/above ~90pt.
        let crossed = offsets.filter { $0.top <= 90 }.max(by: { $0.top < $1.top })
        var next = crossed?.step ?? offsets.min(by: { $0.top < $1.top })?.step
        let reviewTop = offsets.first(where: { $0.step == .review })?.top ?? .infinity
        // Tail case: the final section can't scroll its header to the 90pt line (there
        // isn't enough content below it), so once it sits in the upper viewport it is
        // clearly the one being read — highlight it.
        if viewportH > 0, reviewTop <= viewportH * 0.45 { next = .review }
        if let next, next != visibleSection { visibleSection = next }
        // Compute the (expensive) review figures only once that section is within ~400pt
        // of the viewport, so the payoff screen is always current when reached but never
        // recomputes while the user is typing far above it.
        let show = reviewTop < viewportH + 400
        if show != reviewVisible { reviewVisible = show }
    }

    @ViewBuilder private func sectionContent(_ s: Step) -> some View {
        switch s {
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
                FieldLabel("Filing status") {
                    ChoiceChips(FilingStatus.allCases.map { ($0, $0.rawValue.uppercased()) }, selection: intake.filingStatus) { intake.filingStatus = $0 }
                }
                WheelRow(label: "State of residence", selection: stateSelection, options: USStates.options)
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
                if intake.adults.count > 1 {
                    FieldLabel("Taxable account titling") {
                        ChoiceChips([(OwnershipKind.jointWROS, "Joint"), (.communityProperty, "Community prop."), (.individual, "Individual"), (.revocableTrust, "Trust")],
                                    selection: intake.taxableTitling ?? intake.autoTaxableTitling) { intake.taxableTitling = $0 }
                    }
                    Note("Titling drives the basis step-up at death (community property steps up the full gain on the first death; joint tenancy only half). Auto-set by your state — pick to override.")
                }
                Note("We'll shape a portfolio across these accounts from your current mix below. (Entering exact holdings can come later.)")
            }
            Card("How it's invested today") {
                PercentField(label: "Roughly what share is in stocks (vs bonds/cash)?", value: $intake.currentEquityPct,
                             maxPct: 1.0, presets: [0.0, 0.4, 0.6, 0.8, 1.0])
                Note("This is your AS-IS mix — the desk compares it to the policy target, so the allocation gap is real. The rest is treated as fixed income. 100% stocks is allowed.")
            }
            Card("Taxable cost basis") {
                PercentField(label: "Roughly how much of the taxable balance is gains?", value: $intake.taxableUnrealizedGainPct,
                             maxPct: 1.0, presets: [0.0, 0.25, 0.5, 0.75, 1.0])
                Note("Drives the deferred-tax and step-up math — a low-basis taxable account is worth holding to step-up.")
            }
        }
    }

    private var propertyStep: some View {
        VStack(spacing: 14) {
            Card("Home", help: Teach.help("netFI")) {
                YesNoRow(label: "Do you own your home?", value: $intake.ownsHome)
                if intake.ownsHome {
                    MoneyField(label: "Home value", value: $intake.homeValueUsd)
                    MoneyField(label: "Mortgage balance", value: $intake.mortgageBalanceUsd)
                    PercentField(label: "Mortgage rate", value: bpsAsPct($intake.mortgageRateBps), maxPct: 0.12)
                    FormToggle(label: "Fixed rate", isOn: $intake.mortgageFixed)
                    MoneyField(label: "HELOC drawn", value: $intake.helocUsd)
                } else {
                    Note("No home — renters skip this. Home equity and any mortgage are left out of the balance sheet.")
                }
            }
            Card("Other debts") {
                MoneyField(label: "Other debt (auto, student…)", value: $intake.otherDebtUsd)
            }
        }
    }

    private var externalStep: some View {
        VStack(spacing: 14) {
            Card("Social Security") {
                WheelRow(label: "Planned claiming age", selection: $intake.ssClaimAge, options: ages(62...70))
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
                WheelRow(label: "Retire at age", selection: $intake.retirementStartAge, options: ages(45...75))
                WheelRow(label: "Plan to age", selection: $intake.planToAge, options: ages(80...100))
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
                Note("In a single bad year, the drop at which you'd feel you had to act. On ~\(Fmt.usdShort(intake.totalInvestableUsd)) that's about a \(Fmt.usdShort(Double(nearestTolerance) / 10000.0 * intake.totalInvestableUsd)) fall — the threshold, which implies a ceiling on equity.")
            }
            Card("If a severe year actually hit…") {
                ChoiceChips(LossReaction.allCases.map { ($0, $0.label) }, selection: intake.forwardLossReaction) { intake.forwardLossReaction = $0 }
                Note("A 2008-style year takes your ~\(Fmt.usdShort(intake.totalInvestableUsd)) down about 35%, to ~\(Fmt.usdShort(intake.totalInvestableUsd * 0.65)). What would you most likely do? What you'd DO tempers what you SAY you'll tolerate.")
            }
            Card("In the last big market drop, you…") {
                ChoiceChips(PastBehavior.allCases.map { ($0, $0.label) }, selection: intake.pastBehavior) { intake.pastBehavior = $0 }
                Note("Revealed history is the second behavioral check — and it catches the client who wasn't invested last time.")
            }
            Card("What worries you more?") {
                ChoiceChips(WorryFraming.allCases.map { ($0, $0.label) }, selection: intake.worry) { intake.worry = $0 }
                Note("A drop-worried client is nudged toward stability; a shortfall-worried one toward the return the goal needs.")
            }
            Card("Your risk read") {
                LedgerRow("Stated threshold", Fmt.pctBps(intake.statedThresholdBps), color: Theme.muted)
                LedgerRow("× behavior (history + reaction)", String(format: "%.2f×", intake.behaviorTemperMultiplier), color: Theme.muted)
                LedgerRow("× outlook", String(format: "%.2f×", intake.worry.toleranceTiltMultiplier), color: Theme.muted)
                LedgerRow("Effective max drawdown", Fmt.pctBps(intake.effectiveMaxDrawdownBps), color: Theme.ink, bold: true)
                LedgerRow("Implies an equity ceiling near", Fmt.pctBps(intake.impliedEquityCeilingBps), color: Theme.asset, bold: true)
                Note("This is TOLERANCE. Your situation's CAPACITY — horizon, income stability, funded status — is computed on the desk, and the plan binds to the lower of the two: never more risk than you can afford or will stomach.", icon: "info.circle", color: Theme.muted)
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

    @ViewBuilder private var reviewStep: some View {
        // buildHousehold + evaluate costs tens of ms — too much to run on every keystroke,
        // so compute only once the reader has scrolled this section into range (reviewVisible).
        if reviewVisible {
            reviewFigures
        } else {
            Card("The figures your statement will anchor on") {
                Note("Your headline figures — required real return, funded ratio, after-tax net worth — appear here as you reach this section.")
            }
        }
    }

    private var reviewFigures: some View {
        let h = intake.buildHousehold()
        let e = Engine.evaluate(h)
        return VStack(spacing: 14) {
            Card("The figures your statement will anchor on") {
                LedgerRow("Investable assets", Fmt.usd(intake.totalInvestableUsd), color: Theme.asset)
                LedgerRow("After-tax net worth", Fmt.usd(e.balanceSheet.afterTaxNetWorthUsd), color: Theme.ink, bold: true)
                LedgerRow("Required real return", Fmt.pctBps(e.requiredReturn.requiredRealReturnBps), color: Theme.ink)
                LedgerRow("Net fixed income", Fmt.usd(e.netFixedIncomeUsd), color: e.netFixedIncomeUsd < 0 ? Theme.debt : Theme.asset)
                LedgerRow("Funded ratio", Fmt.pctBps(e.balanceSheet.fundedRatioBps), color: e.balanceSheet.fundedRatioBps >= 10_000 ? Theme.asset : Theme.amber)
                LedgerRow("Legacy floor", intake.legacyFloorUsd > 0 || intake.legacyPriority != .none ? Fmt.usd(h.legacyFloorUsd) : "$0", color: Theme.ink)
            }
            Card("Your Investment Policy Statement will set out") {
                ForEach(["Objectives — the real, after-tax return your goals require and the risk the plan may take",
                         "Constraints — liquidity, time horizon, taxes, legal, and unique circumstances",
                         "The strategic asset allocation derived from them",
                         "The rebalancing and review policy"], id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.asset).padding(.top, 1)
                        Text(line).font(.system(size: 13)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // helpers
    private var nearestTolerance: Int { intake.statedThresholdBps }
    private func bpsAsPct(_ b: Binding<Bps>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) / 10_000 }, set: { b.wrappedValue = Int(($0 * 10_000).rounded()) })
    }
    /// The state wheel binds to a normalized code so a legacy free-text value displays its
    /// proper name and selection always matches an option (never "—", never auto-reset).
    private var stateSelection: Binding<String> {
        Binding(get: { USStates.code(for: intake.state) }, set: { intake.state = $0 })
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
                FormText(label: index == 0 ? "Your name" : "Their name", value: $adult.name)
                WheelRow(label: "Birth year", selection: $adult.birthYear, options: years(1940...2010))
                WheelRow(label: "Planned retirement age", selection: $adult.retirementAge, options: ages(45...75))
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
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(Theme.ink)
            Spacer(minLength: 10)
            HStack(spacing: 1) {
                Text("$").foregroundStyle(Theme.muted).font(.system(size: 15))
                TextField("0", value: $value, format: .number.precision(.fractionLength(0)))
                    .focused($focused)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
                    .frame(minWidth: 90, maxWidth: 140)
            }
        }
        .padding(.vertical, 9)
        // Focus on a tap anywhere in the row: an empty numeric field's glyph area is
        // too small to reliably hit on its own.
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}

struct PercentField: View {
    let label: String
    @Binding var value: Double     // 0..1
    var maxPct: Double = 0.95
    var presets: [Double] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 14)).foregroundStyle(Theme.ink)
                Spacer()
                Text(Fmt.pct(value)).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
            }
            Slider(value: $value, in: 0...maxPct, step: 0.01).tint(Theme.ink)
            if !presets.isEmpty {
                HStack(spacing: 5) {
                    ForEach(presets, id: \.self) { p in
                        let on = abs(value - p) < 0.005
                        Button { value = p } label: {
                            Text(Fmt.pct(p)).font(.system(size: 12.5, weight: .semibold))
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .background(on ? Theme.ink : Theme.card, in: Capsule())
                                .foregroundStyle(on ? Color.white : Theme.ink)
                                .overlay(Capsule().stroke(on ? Theme.ink : Theme.rule))
                        }.buttonStyle(.plain)
                    }
                }
            }
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
    var placeholder: String = "Tap to enter"
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(Theme.ink)
            Spacer(minLength: 10)
            TextField(placeholder, text: $value)
                .focused($focused)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).frame(maxWidth: 240)
        }
        .padding(.vertical, 9)
        // An empty TextField with no placeholder has almost no tappable width — focus
        // the field from a tap anywhere in the row instead.
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
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

// MARK: - Scrolling pickers, yes/no, section tracking

/// A compact row that expands into a real scroll wheel — the fix for tapping a
/// stepper dozens of times to set a birth year, an age, or a state.
struct WheelRow<T: Hashable>: View {
    let label: String
    @Binding var selection: T
    let options: [(T, String)]
    @State private var expanded = false
    private var currentLabel: String { options.first(where: { $0.0 == selection })?.1 ?? "—" }
    var body: some View {
        VStack(spacing: 0) {
            Button {
                dismissKeyboard()
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack {
                    Text(label).font(.system(size: 14)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(currentLabel)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(expanded ? Theme.accent : Theme.ink)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                Picker(label, selection: $selection) {
                    ForEach(options, id: \.0) { opt in Text(opt.1).tag(opt.0) }
                }
                .pickerStyle(.wheel).frame(height: 132).clipped()
            }
        }
        .padding(.vertical, 7)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}

/// A two-button Yes / No — clearer than a toggle for a gating question.
struct YesNoRow: View {
    let label: String
    @Binding var value: Bool
    var body: some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(Theme.ink)
            Spacer()
            HStack(spacing: 5) {
                pill("No", on: !value) { value = false }
                pill("Yes", on: value) { value = true }
            }
        }
        .padding(.vertical, 7)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
    private func pill(_ text: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(text).font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(on ? Theme.ink : Theme.card, in: Capsule())
                .foregroundStyle(on ? Color.white : Theme.ink)
                .overlay(Capsule().stroke(on ? Theme.ink : Theme.rule))
        }.buttonStyle(.plain)
    }
}

/// Option builders for the year/age wheels.
func years(_ r: ClosedRange<Int>) -> [(Int, String)] { r.map { ($0, String($0)) } }
func ages(_ r: ClosedRange<Int>) -> [(Int, String)] { r.map { ($0, "\($0)") } }

/// Sector options for a held position — "not a single stock" first, since most holdings
/// are funds and are classified from their ticker instead.
var sectorOptions: [(Sector?, String)] {
    [(Sector?.none, "Fund / not a single stock")] + Sector.allCases.map { (Sector?.some($0), $0.label) }
}

/// US states + DC, stored as the two-letter code the tax layer expects.
enum USStates {
    static let options: [(String, String)] = [
        ("AL","Alabama"),("AK","Alaska"),("AZ","Arizona"),("AR","Arkansas"),("CA","California"),
        ("CO","Colorado"),("CT","Connecticut"),("DE","Delaware"),("DC","District of Columbia"),
        ("FL","Florida"),("GA","Georgia"),("HI","Hawaii"),("ID","Idaho"),("IL","Illinois"),
        ("IN","Indiana"),("IA","Iowa"),("KS","Kansas"),("KY","Kentucky"),("LA","Louisiana"),
        ("ME","Maine"),("MD","Maryland"),("MA","Massachusetts"),("MI","Michigan"),("MN","Minnesota"),
        ("MS","Mississippi"),("MO","Missouri"),("MT","Montana"),("NE","Nebraska"),("NV","Nevada"),
        ("NH","New Hampshire"),("NJ","New Jersey"),("NM","New Mexico"),("NY","New York"),
        ("NC","North Carolina"),("ND","North Dakota"),("OH","Ohio"),("OK","Oklahoma"),("OR","Oregon"),
        ("PA","Pennsylvania"),("RI","Rhode Island"),("SC","South Carolina"),("SD","South Dakota"),
        ("TN","Tennessee"),("TX","Texas"),("UT","Utah"),("VT","Vermont"),("VA","Virginia"),
        ("WA","Washington"),("WV","West Virginia"),("WI","Wisconsin"),("WY","Wyoming")
    ]
    /// Normalize any stored value (2-letter code, full name, mixed case, or legacy free
    /// text) to a canonical code that always matches an option — so the wheel never shows
    /// "—" and can never silently commit the first row over an unmatched value.
    static func code(for raw: String) -> String {
        let up = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if options.contains(where: { $0.0 == up }) { return up }
        if let m = options.first(where: { $0.1.uppercased() == up }) { return m.0 }
        return "CA"
    }
}

/// Reports section header offsets up to the wizard, so the rail can highlight the
/// section currently being read.
struct SectionOffset: Equatable { let step: IntakeWizard.Step; let top: CGFloat }
struct SectionOffsetKey: PreferenceKey {
    static var defaultValue: [SectionOffset] = []
    static func reduce(value: inout [SectionOffset], nextValue: () -> [SectionOffset]) { value.append(contentsOf: nextValue()) }
}
struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
            FormText(label: "Acquired (YYYY-MM-DD, optional)", value: Binding(
                get: { position.acquisitionDate ?? "" },
                set: { position.acquisitionDate = $0.isEmpty ? nil : $0 }))
            WheelRow(label: "Sector (single stocks)", selection: $position.sector, options: sectorOptions)
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
            WheelRow(label: "Birth year", selection: $child.birthYear, options: years(1990...IntakeModel.currentYear))
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
            WheelRow(label: "Start year", selection: $goal.startYear, options: years(IntakeModel.currentYear...(IntakeModel.currentYear + 30)))
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
            WheelRow(label: "Target year", selection: $goal.targetYear, options: years(IntakeModel.currentYear...(IntakeModel.currentYear + 40)))
            StepperRow(label: "Spread over (years)", value: $goal.spanYears, range: 1...10)
            FieldLabel("How essential?") { ChoiceChips(GoalTier.allCases.map { ($0, $0.label) }, selection: goal.tier) { goal.tier = $0 } }
        }
        .padding(11)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
    }
}
