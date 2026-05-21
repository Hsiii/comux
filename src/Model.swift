import Foundation

struct UsageWindow: Codable {
    let available: Bool
    let label: String
    let usedMinutes: Int
    let limitMinutes: Int
    let remainingMinutes: Int
    let usedPercentage: Double
    let resetsAt: String
}

struct PaceSnapshot: Codable {
    let status: String
    let summary: String
    let detail: String
}

struct HistorySnapshot: Codable {
    let capturedAt: String
    let weeklyUsedMinutes: Int
    let rollingUsedMinutes: Int
    let note: String
}

struct AccountSnapshot: Codable, Identifiable {
    let accountId: String
    let label: String
    let email: String
    let workspaceLabel: String
    let plan: String
    let color: String
    let source: String
    let lastSyncedAt: String
    let weeklyWindow: UsageWindow
    let rollingWindow: UsageWindow
    let pace: PaceSnapshot
    let history: [HistorySnapshot]

    var id: String { self.accountId }
}

struct CacheMeta: Codable {
    let generatedAt: String
    let cachePath: String
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

func buildSnapshotKey(
    accountId: String,
    plan: String,
    workspaceLabel: String
) -> String {
    [accountId, plan, workspaceLabel].joined(separator: "::")
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
