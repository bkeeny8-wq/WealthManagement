//  PracticeMetadata.swift
//  WealthPolicyDesk
//
//  The practice-facing envelope around a plan — who owns the relationship, who
//  the client is, where they sit in the pipeline, and what happens next. This is
//  the hook between a one-off plan and a running practice: the same on-device
//  intake that produces a financial plan also seeds a CRM.
//
//  It deliberately does NOT feed buildHousehold() — a lead source can't change a
//  portfolio — so it lives in its own struct and its own JSON file. PII stays on
//  device; nothing here touches the network, and it never holds account numbers
//  or credentials.

import Foundation

public enum ClientStage: String, Codable, CaseIterable, Hashable {
    case prospect, onboarding, client
    public var label: String { rawValue.capitalized }
}

public enum LeadSource: String, Codable, CaseIterable, Hashable {
    case referral, coldOutreach = "cold_outreach", event, website, social, centerOfInfluence = "center_of_influence", existingClient = "existing_client", other
    public var label: String {
        switch self {
        case .referral: return "Referral"
        case .coldOutreach: return "Cold outreach"
        case .event: return "Event / seminar"
        case .website: return "Website / inbound"
        case .social: return "Social media"
        case .centerOfInfluence: return "Center of influence"
        case .existingClient: return "Existing client / family"
        case .other: return "Other"
        }
    }
}

public struct PracticeMetadata: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var advisorName: String = ""
    public var clientName: String = ""
    public var contactEmail: String? = nil
    public var contactPhone: String? = nil
    public var stage: ClientStage = .prospect
    public var leadSource: LeadSource = .referral
    public var leadSourceDetail: String = ""
    public var nextAction: String = ""
    public var notes: String = ""
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init() {}

    /// Forward-compatible decode: start from defaults, override only present keys
    /// (so adding a field later never discards a saved CRM record). createdAt is
    /// write-once; updatedAt bumps on save.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil { id = v }
        if let v = (try? c.decodeIfPresent(String.self, forKey: .advisorName)) ?? nil { advisorName = v }
        if let v = (try? c.decodeIfPresent(String.self, forKey: .clientName)) ?? nil { clientName = v }
        if let v = (try? c.decodeIfPresent(String.self, forKey: .contactEmail)) ?? nil { contactEmail = v }
        if let v = (try? c.decodeIfPresent(String.self, forKey: .contactPhone)) ?? nil { contactPhone = v }
        if let v = (try? c.decodeIfPresent(ClientStage.self, forKey: .stage)) ?? nil { stage = v }
        if let v = (try? c.decodeIfPresent(LeadSource.self, forKey: .leadSource)) ?? nil { leadSource = v }
        if let v = (try? c.decodeIfPresent(String.self, forKey: .leadSourceDetail)) ?? nil { leadSourceDetail = v }
        if let v = (try? c.decodeIfPresent(String.self, forKey: .nextAction)) ?? nil { nextAction = v }
        if let v = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? nil { notes = v }
        if let v = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil { createdAt = v }
        if let v = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil { updatedAt = v }
    }

    public mutating func touch() { updatedAt = Date() }

    /// Header view-model for the desk's client strip.
    public var header: ClientProfileHeader {
        ClientProfileHeader(
            title: clientName.isEmpty ? "New relationship" : clientName,
            subtitle: advisorName.isEmpty ? "Unassigned" : advisorName,
            badge: stage.label,
            caption: leadSource.label + (leadSourceDetail.isEmpty ? "" : " · " + leadSourceDetail),
            nextAction: nextAction)
    }
}

public struct ClientProfileHeader: Hashable {
    public let title: String
    public let subtitle: String
    public let badge: String
    public let caption: String
    public let nextAction: String
}

// MARK: - Persistence (separate file from the plan)

public enum PracticeStore {
    private static var url: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("wealth-policy-practice.json")
    }
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public static func save(_ m: PracticeMetadata) {
        guard let url else { return }
        var m = m; m.touch()
        if let data = try? encoder.encode(m) { try? data.write(to: url) }
    }
    public static func load() -> PracticeMetadata? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(PracticeMetadata.self, from: data)
    }
    public static func clear() { if let url { try? FileManager.default.removeItem(at: url) } }
}

// MARK: - CRM export (the thin header over the plan record)

/// A flat, CRM-neutral interchange record: the practice envelope joined to a
/// non-PII snapshot of the plan and its open planning flags. The IntakeModel JSON
/// already IS the full plan record; this is the header a CRM keys on. It carries
/// contact detail (the advisor's own relationship data) but never account numbers,
/// balances-by-account, or credentials — only aggregate figures and derived flags.
/// Deliberately vendor-neutral: no field is shaped to a specific CRM's importer.
public struct CRMExportRecord: Codable, Hashable {
    // Contact
    public var advisor: String
    public var client: String
    public var email: String?
    public var phone: String?
    public var state: String
    // Relationship / opportunity
    public var stage: String
    public var stageLabel: String
    public var leadSource: String
    public var leadSourceLabel: String
    public var leadSourceDetail: String
    public var nextAction: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date
    // Non-PII plan snapshot (aggregate only)
    public var investableUsd: Usd
    public var tier: String
    public var primaryAge: Int
    public var filingStatus: String
    public var requiredRealReturnBps: Bps
    public var afterTaxNetWorthUsd: Usd
    public var fundedRatioBps: Bps
    // Open planning flags (from the engine)
    public var hardFlags: Int
    public var softFlags: Int
    public var openHardRules: String   // ";"-joined ruleIds of the hard findings

    public func csvRow() -> String {
        func esc(_ s: String) -> String {
            (s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let iso = ISO8601DateFormatter()
        let cells = [advisor, client, email ?? "", phone ?? "", state,
                     stage, leadSource, leadSourceDetail, nextAction, notes,
                     iso.string(from: createdAt), iso.string(from: updatedAt),
                     String(format: "%.0f", investableUsd), tier, String(primaryAge), filingStatus,
                     String(requiredRealReturnBps), String(format: "%.0f", afterTaxNetWorthUsd), String(fundedRatioBps),
                     String(hardFlags), String(softFlags), openHardRules]
        return cells.map(esc).joined(separator: ",")
    }

    public static let csvHeader = "advisor,client,email,phone,state,stage,lead_source,lead_source_detail,next_action,notes,created_at,updated_at,investable_usd,tier,primary_age,filing_status,required_real_return_bps,after_tax_net_worth_usd,funded_ratio_bps,hard_flags,soft_flags,open_hard_rules"
}

public extension PracticeMetadata {
    /// Join the CRM envelope with a non-PII snapshot of the plan and its open flags.
    func exportRecord(intake: IntakeModel, evaluation e: Evaluation) -> CRMExportRecord {
        let hard = e.findings.filter { $0.severity == .hard }
        let soft = e.findings.filter { $0.severity == .soft }
        return CRMExportRecord(
            advisor: advisorName, client: clientName, email: contactEmail, phone: contactPhone, state: intake.state,
            stage: stage.rawValue, stageLabel: stage.label, leadSource: leadSource.rawValue, leadSourceLabel: leadSource.label,
            leadSourceDetail: leadSourceDetail, nextAction: nextAction, notes: notes, createdAt: createdAt, updatedAt: updatedAt,
            investableUsd: intake.totalInvestableUsd, tier: IntakeModel.tier(forInvestable: intake.totalInvestableUsd),
            primaryAge: intake.primaryAge, filingStatus: intake.filingStatus.rawValue,
            requiredRealReturnBps: e.requiredReturn.requiredRealReturnBps, afterTaxNetWorthUsd: e.balanceSheet.afterTaxNetWorthUsd,
            fundedRatioBps: e.balanceSheet.fundedRatioBps,
            hardFlags: hard.count, softFlags: soft.count, openHardRules: hard.map { $0.ruleId }.joined(separator: ";"))
    }
}
