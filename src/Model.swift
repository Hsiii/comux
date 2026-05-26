import Foundation

struct UsageWindow: Codable {
    let available: Bool
    let label: String
    let usedMinutes: Int
    let limitMinutes: Int
    let usedPercentage: Double
    let resetsAt: String

    var remainingMinutes: Int {
        max(limitMinutes - usedMinutes, 0)
    }
}

struct AccountSnapshot: Codable, Identifiable {
    let accountId: String
    let label: String
    let email: String
    let workspaceId: String?
    let workspaceLabel: String
    let plan: String
    let source: String
    let systemAuthProfileId: String?
    let isCurrentSystemAccount: Bool?
    let lastSyncedAt: String
    let weeklyWindow: UsageWindow
    let rollingWindow: UsageWindow

    var id: String { self.accountId }
}

struct CacheMeta: Codable {
    let source: String
}

struct CachePayload: Codable {
    let meta: CacheMeta
    let accounts: [AccountSnapshot]
}

struct AccountConfig: Codable, Identifiable {
    let id: String
    let label: String
    let email: String
    let workspaceLabel: String
    let plan: String
    let color: String
    let chatGPTCookie: String
    let source: String?
    let sessionEndpoint: String?
    let usageEndpoint: String?
    let accountHeader: String?
}

struct PulseConfig: Codable {
    let pollIntervalSeconds: Double
    let accounts: [AccountConfig]

    static let `default` = PulseConfig(
        pollIntervalSeconds: 300,
        accounts: []
    )
}

func legacyBaseAccountID(from accountID: String) -> String {
    let legacySeparator = "::"

    guard let separatorRange = accountID.range(of: legacySeparator) else {
        return accountID
    }

    return String(accountID[..<separatorRange.lowerBound])
}

func resolvedWorkspaceIdentity(
    accountId: String,
    workspaceId: String?
) -> String? {
    if let trimmedWorkspaceID = workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
       !trimmedWorkspaceID.isEmpty {
        return trimmedWorkspaceID
    }

    let legacyAccountID = legacyBaseAccountID(from: accountId)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !legacyAccountID.isEmpty else {
        return nil
    }

    if legacyAccountID.hasPrefix("user-")
        || legacyAccountID.hasPrefix("org-")
        || legacyAccountID.hasPrefix("workspace-") {
        return legacyAccountID
    }

    return nil
}

func buildAccountPrimaryKey(
    email: String,
    workspaceId: String?,
    workspaceLabel: String
) -> String {
    let normalizedEmail = email
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let normalizedWorkspaceID = workspaceId?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    let normalizedWorkspace = workspaceLabel
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    if !normalizedEmail.isEmpty && !normalizedWorkspaceID.isEmpty {
        return "\(normalizedEmail)::\(normalizedWorkspaceID)"
    }

    if !normalizedEmail.isEmpty && !normalizedWorkspace.isEmpty {
        return "\(normalizedEmail)::\(normalizedWorkspace)"
    }

    if !normalizedEmail.isEmpty {
        return normalizedEmail
    }

    if !normalizedWorkspaceID.isEmpty {
        return "workspace::\(normalizedWorkspaceID)"
    }

    return normalizedWorkspace.isEmpty ? UUID().uuidString : "workspace::\(normalizedWorkspace)"
}

struct SystemAuthIdentity {
    let accessToken: String
    let accountId: String?
    let email: String?
    let name: String?
    let planType: String?
    let organizationTitles: [String]
    let subject: String?
}

func normalizedSystemAuthProfileID(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }

    return trimmed.lowercased()
}

struct WindowPair {
    let weeklyWindow: UsageWindow
    let rollingWindow: UsageWindow
}

struct WorkspaceIdentity: Decodable {
    let items: [WorkspaceItem]
}

struct WorkspaceItem: Decodable {
    let id: String
    let name: String?
}

enum PulseError: Error, LocalizedError {
    case invalidAuthFile
    case invalidSessionToken
    case invalidUsageResponse

    var errorDescription: String? {
        switch self {
        case .invalidAuthFile:
            return "Local Codex auth could not be parsed."
        case .invalidSessionToken:
            return "ChatGPT session cookie did not yield an access token."
        case .invalidUsageResponse:
            return "Usage endpoint did not contain enough fields to normalize."
        }
    }
}
