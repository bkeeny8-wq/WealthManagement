//  OwnershipModel.swift
//  WealthPolicyDesk
//
//  Account ownership / titling — who actually owns each account, which the app
//  modelled only implicitly (in labels). Titling drives the basis STEP-UP at death,
//  the biggest lever a taxable account has: community property gets a full (double)
//  step-up on the FIRST spouse's death, joint tenancy only half, and a separately
//  owned account steps up only at its own owner's death. Same holdings, very
//  different embedded tax the heirs inherit.
//
//  Pure and descriptive: this classifies and prices the step-up; it never sets a
//  target or touches resolveTargets.

import Foundation

public enum OwnershipKind: String, Codable, CaseIterable, Sendable, Hashable {
    case individual
    case jointWROS = "joint_wros"
    case communityProperty = "community_property"
    case revocableTrust = "revocable_trust"
    case entity
    public var label: String {
        switch self {
        case .individual: return "Individual"
        case .jointWROS: return "Joint (WROS)"
        case .communityProperty: return "Community property"
        case .revocableTrust: return "Revocable trust"
        case .entity: return "Entity / LLC"
        }
    }
    /// Fraction of a taxable account's embedded gain whose basis steps up on the FIRST
    /// spouse's death. Community property = full (double) step-up; joint tenancy = half
    /// (the decedent's share); a separately owned or entity account gets nothing at the
    /// first death (it steps up, if ever, at its own owner's death — the second death).
    public var firstDeathStepUpFraction: Double {
        switch self {
        case .communityProperty: return 1.0
        case .jointWROS: return 0.5
        case .individual, .revocableTrust, .entity: return 0.0
        }
    }
    public var stepUpNote: String {
        switch self {
        case .communityProperty: return "full step-up on the first death — both halves"
        case .jointWROS: return "half step-up on the first death (the decedent's share)"
        case .individual, .revocableTrust: return "steps up at the owner's own death"
        case .entity: return "no step-up — held in an entity"
        }
    }
}

public struct AccountOwnership: Sendable, Hashable {
    public var kind: OwnershipKind
    public var ownerPersonId: String?          // individual / revocableTrust: the owner; nil otherwise
    public init(kind: OwnershipKind, ownerPersonId: String? = nil) {
        self.kind = kind; self.ownerPersonId = ownerPersonId
    }
    public static let individual = AccountOwnership(kind: .individual)
}

public struct AccountStepUp: Identifiable, Sendable, Hashable {
    public var accountId: String
    public var label: String
    public var ownerLabel: String
    public var kind: OwnershipKind
    public var embeddedGainUsd: Usd
    public var firstDeathStepUpUsd: Usd        // gain whose basis steps up on the first death
    public var taxSavedUsd: Usd                // heirs' LTCG tax that first-death step-up erases
    public var id: String { accountId }
}

public struct TitlingStepUp: Sendable {
    public var accounts: [AccountStepUp]
    public var totalEmbeddedGainUsd: Usd
    public var totalFirstDeathStepUpUsd: Usd
    public var totalTaxSavedUsd: Usd
    public var communityPropertyTaxSavedUsd: Usd   // what the same book would save if titled community property
    public var isCouple: Bool
}

public extension Engine {
    /// The basis step-up each taxable account earns on the first death, by titling —
    /// and, for a couple, how much more community-property titling would save.
    static func titlingStepUp(_ h: Household, asOf: IsoDate = planningAsOf) -> TitlingStepUp {
        let isCouple = h.people.contains { $0.role == .spouse }
        let ltcgRate = (1500 + Seed.tax2026.niitRateBps).frac      // matches the balance-sheet embedded-tax rate
        var rows: [AccountStepUp] = []
        var cpSaved: Usd = 0
        for a in h.accounts where a.treatment == .taxable {
            let gain = h.positions.filter { $0.accountId == a.id }.reduce(0) { $0 + max(0, $1.unrealizedGainUsd) }
            guard gain > 0 else { continue }
            let steppedUp = gain * a.ownership.kind.firstDeathStepUpFraction
            rows.append(AccountStepUp(accountId: a.id, label: a.label, ownerLabel: ownerLabel(a.ownership, h: h),
                kind: a.ownership.kind, embeddedGainUsd: gain,
                firstDeathStepUpUsd: steppedUp, taxSavedUsd: steppedUp * ltcgRate))
            // Community property would step up the full gain — but only for property that
            // can be transmuted; an entity interest's inside basis doesn't step up that way.
            if isCouple && a.ownership.kind != .entity { cpSaved += gain * ltcgRate }
        }
        return TitlingStepUp(accounts: rows.sorted { $0.embeddedGainUsd > $1.embeddedGainUsd },
            totalEmbeddedGainUsd: rows.reduce(0) { $0 + $1.embeddedGainUsd },
            totalFirstDeathStepUpUsd: rows.reduce(0) { $0 + $1.firstDeathStepUpUsd },
            totalTaxSavedUsd: rows.reduce(0) { $0 + $1.taxSavedUsd },
            communityPropertyTaxSavedUsd: cpSaved, isCouple: isCouple)
    }

    private static func ownerLabel(_ o: AccountOwnership, h: Household) -> String {
        switch o.kind {
        case .individual, .revocableTrust:
            return h.people.first { $0.id == o.ownerPersonId }?.label ?? o.kind.label
        default: return o.kind.label
        }
    }
}
