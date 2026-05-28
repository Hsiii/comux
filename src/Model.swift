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

enum PulseError: Error, LocalizedError, Equatable {
    case invalidAuthFile
    case invalidSessionToken
    case invalidUsageResponse
    case workspaceListUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidAuthFile:
            return "Local Codex auth could not be parsed."
        case .invalidSessionToken:
            return "ChatGPT session cookie did not yield an access token."
        case .invalidUsageResponse:
            return "Usage endpoint did not contain enough fields to normalize."
        case .workspaceListUnavailable:
            return "Workspace list could not be loaded."
        }
    }
}
