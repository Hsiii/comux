import AppKit
import Foundation
import SwiftUI

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

struct SupabaseConfig: Codable {
    let functionURL: String
    let tokenID: String
    let token: String
}

struct SupabaseFunctionPayload: Codable {
    let accounts: [AccountSnapshot]
}

struct SystemAuthIdentity {
    let accessToken: String
    let accountId: String?
    let email: String?
    let name: String?
    let planType: String?
    let subject: String?
}

struct WindowPair {
    let weeklyWindow: UsageWindow
    let rollingWindow: UsageWindow
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

enum CodexBoardPaths {
    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codexboard", isDirectory: true)
    static let cache = root.appendingPathComponent("cache.json", isDirectory: false)
    static let config = root.appendingPathComponent("accounts.json", isDirectory: false)
    static let supabase = root.appendingPathComponent("supabase.json", isDirectory: false)
    static let sample = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("../../storage/sample-cache.json")
        .standardizedFileURL
    static let codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex")
    static let codexAuth = codexHome.appendingPathComponent("auth.json", isDirectory: false)
}

final class CacheStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func load() -> CachePayload {
        self.ensureSeeded()

        guard let data = try? Data(contentsOf: CodexBoardPaths.cache),
              let payload = try? self.decoder.decode(CachePayload.self, from: data)
        else {
            return self.emptyPayload()
        }

        return payload
    }

    func save(_ payload: CachePayload) throws {
        try FileManager.default.createDirectory(
            at: CodexBoardPaths.root,
            withIntermediateDirectories: true
        )
        try self.encoder.encode(payload).write(to: CodexBoardPaths.cache)
    }

    private func ensureSeeded() {
        if FileManager.default.fileExists(atPath: CodexBoardPaths.cache.path(percentEncoded: false)) {
            return
        }

        try? FileManager.default.createDirectory(
            at: CodexBoardPaths.root,
            withIntermediateDirectories: true
        )

        if let data = try? Data(contentsOf: CodexBoardPaths.sample) {
            try? data.write(to: CodexBoardPaths.cache)
        } else if let data = try? self.encoder.encode(self.emptyPayload()) {
            try? data.write(to: CodexBoardPaths.cache)
        }
    }

    private func emptyPayload() -> CachePayload {
        CachePayload(
            meta: CacheMeta(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                cachePath: CodexBoardPaths.cache.path(percentEncoded: false),
                source: "native-swift-cache"
            ),
            accounts: []
        )
    }
}

@MainActor
final class PulseCoordinator: ObservableObject {
    @Published var statusLine = "Idle"
    @Published var lastSyncedAt: String?
    @Published var cache = CachePayload(
        meta: CacheMeta(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            cachePath: CodexBoardPaths.cache.path(percentEncoded: false),
            source: "native-swift-cache"
        ),
        accounts: []
    )

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let cacheStore = CacheStore()
    private var timer: Timer?
    private var hasStarted = false

    var accountCount: Int {
        self.cache.accounts.count
    }

    func start() {
        guard !self.hasStarted else {
            return
        }

        self.hasStarted = true
        self.cache = self.cacheStore.load()
        self.lastSyncedAt = self.cache.meta.generatedAt

        Task {
            await self.syncNow()
            self.scheduleNextSync()
        }
    }

    func syncNow() async {
        do {
            let config = self.loadConfig()
            var incomingSnapshots: [AccountSnapshot] = []

            if let systemSnapshot = try await self.buildSystemSnapshotIfAvailable() {
                incomingSnapshots.append(systemSnapshot)
            }

            for account in config.accounts {
                let snapshot = try await self.buildCookieSnapshot(for: account)
                incomingSnapshots.append(snapshot)
            }

            let merged = self.mergeSnapshots(
                existing: self.cacheStore.load(),
                incoming: incomingSnapshots
            )

            try self.cacheStore.save(merged)
            try await self.syncSupabaseIfConfigured(cache: merged)
            self.cache = merged
            self.lastSyncedAt = merged.meta.generatedAt
            self.statusLine = "Synced \(merged.accounts.count) account(s)"
        } catch {
            self.statusLine = error.localizedDescription
        }
    }

    private func scheduleNextSync() {
        let config = self.loadConfig()

        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer(
            withTimeInterval: max(config.pollIntervalSeconds, 60),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.syncNow()
            }
        }
    }

    private func loadConfig() -> PulseConfig {
        guard let data = try? Data(contentsOf: CodexBoardPaths.config),
              let config = try? self.decoder.decode(PulseConfig.self, from: data)
        else {
            return .default
        }

        return config
    }

    private func loadSupabaseConfig() -> SupabaseConfig? {
        guard let data = try? Data(contentsOf: CodexBoardPaths.supabase),
              let config = try? self.decoder.decode(SupabaseConfig.self, from: data)
        else {
            return nil
        }

        return config
    }

    private func buildSystemSnapshotIfAvailable() async throws -> AccountSnapshot? {
        guard let identity = try self.loadSystemIdentity() else {
            return nil
        }

        let rawUsage = try await self.fetchUsagePayload(
            accessToken: identity.accessToken,
            cookieHeader: nil,
            usageEndpoint: "https://chatgpt.com/backend-api/wham/usage",
            accountHeader: nil
        )

        return try self.normalizeUsage(
            rawUsage,
            accountID: rawUsage["account_id"] as? String ?? identity.accountId ?? identity.subject ?? UUID().uuidString,
            label: identity.name ?? rawUsage["email"] as? String ?? identity.email ?? "Current system account",
            email: rawUsage["email"] as? String ?? identity.email ?? "Unknown account",
            workspaceLabel: "Ambient ~/.codex session",
            plan: self.displayPlan(rawUsage["plan_type"] as? String ?? identity.planType),
            color: "#8cf5b0",
            source: "live system auth",
            note: "Native Swift sync from local Codex auth."
        )
    }

    private func buildCookieSnapshot(for account: AccountConfig) async throws -> AccountSnapshot {
        let accessToken = try await self.fetchAccessToken(for: account)
        let rawUsage = try await self.fetchUsagePayload(
            accessToken: accessToken,
            cookieHeader: account.chatGPTCookie,
            usageEndpoint: account.usageEndpoint ?? "https://chatgpt.com/backend-api/wham/usage",
            accountHeader: account.accountHeader
        )

        return try self.normalizeUsage(
            rawUsage,
            accountID: account.id,
            label: account.label,
            email: account.email,
            workspaceLabel: account.workspaceLabel,
            plan: account.plan,
            color: account.color,
            source: account.source ?? "native cookie sync",
            note: "Native Swift sync from account cookie."
        )
    }

    private func loadSystemIdentity() throws -> SystemAuthIdentity? {
        guard FileManager.default.fileExists(atPath: CodexBoardPaths.codexAuth.path(percentEncoded: false)) else {
            return nil
        }

        let data = try Data(contentsOf: CodexBoardPaths.codexAuth)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = payload["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String
        else {
            throw PulseError.invalidAuthFile
        }

        let idToken = tokens["id_token"] as? String
        let idTokenClaims = idToken.flatMap(self.decodeJWTClaims)
        let planClaims = idTokenClaims?["https://api.openai.com/auth"] as? [String: Any]

        return SystemAuthIdentity(
            accessToken: accessToken,
            accountId: tokens["account_id"] as? String,
            email: idTokenClaims?["email"] as? String,
            name: idTokenClaims?["name"] as? String,
            planType: planClaims?["chatgpt_plan_type"] as? String,
            subject: idTokenClaims?["sub"] as? String
        )
    }

    private func decodeJWTClaims(_ token: String) -> [String: Any]? {
        let components = token.split(separator: ".")
        guard components.count > 1 else {
            return nil
        }

        var payload = String(components[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4

        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return object
    }

    private func fetchAccessToken(for account: AccountConfig) async throws -> String {
        let sessionURL = URL(string: account.sessionEndpoint ?? "https://chatgpt.com/api/auth/session")!
        var request = URLRequest(url: sessionURL)
        request.setValue(account.chatGPTCookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")

        let (data, _) = try await URLSession.shared.data(for: request)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let accessToken = payload?["accessToken"] as? String

        guard let accessToken, !accessToken.isEmpty else {
            throw PulseError.invalidSessionToken
        }

        return accessToken
    }

    private func fetchUsagePayload(
        accessToken: String,
        cookieHeader: String?,
        usageEndpoint: String,
        accountHeader: String?
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: usageEndpoint)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        if let accountHeader, !accountHeader.isEmpty {
            request.setValue(accountHeader, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PulseError.invalidUsageResponse
        }

        return payload
    }

    private func normalizeUsage(
        _ payload: [String: Any],
        accountID: String,
        label: String,
        email: String,
        workspaceLabel: String,
        plan: String,
        color: String,
        source: String,
        note: String
    ) throws -> AccountSnapshot {
        let windows = self.resolveWindows(rateLimit: payload["rate_limit"] as? [String: Any])
        let now = ISO8601DateFormatter().string(from: Date())
        let pace = self.projectPace(weeklyWindow: windows.weeklyWindow, rollingWindow: windows.rollingWindow)
        let snapshotKey = buildSnapshotKey(
            accountId: accountID,
            plan: plan,
            workspaceLabel: workspaceLabel
        )

        return AccountSnapshot(
            accountId: snapshotKey,
            label: label,
            email: email,
            workspaceLabel: workspaceLabel,
            plan: plan,
            color: color,
            source: source,
            lastSyncedAt: now,
            weeklyWindow: windows.weeklyWindow,
            rollingWindow: windows.rollingWindow,
            pace: pace,
            history: [
                HistorySnapshot(
                    capturedAt: now,
                    weeklyUsedMinutes: windows.weeklyWindow.usedMinutes,
                    rollingUsedMinutes: windows.rollingWindow.usedMinutes,
                    note: note
                )
            ]
        )
    }

    private func resolveWindows(rateLimit: [String: Any]?) -> WindowPair {
        let primaryWindow = rateLimit?["primary_window"] as? [String: Any]
        let secondaryWindow = rateLimit?["secondary_window"] as? [String: Any]
        let primarySeconds = (primaryWindow?["limit_window_seconds"] as? NSNumber)?.intValue ?? 0
        let secondarySeconds = (secondaryWindow?["limit_window_seconds"] as? NSNumber)?.intValue ?? 0

        if primarySeconds >= 6 * 24 * 60 * 60 {
            return WindowPair(
                weeklyWindow: self.buildWindow(label: "Weekly window", rawWindow: primaryWindow),
                rollingWindow: self.buildWindow(label: "Rolling 5-hour window", rawWindow: secondaryWindow)
            )
        }

        if secondarySeconds >= 6 * 24 * 60 * 60 {
            return WindowPair(
                weeklyWindow: self.buildWindow(label: "Weekly window", rawWindow: secondaryWindow),
                rollingWindow: self.buildWindow(label: "Rolling 5-hour window", rawWindow: primaryWindow)
            )
        }

        return WindowPair(
            weeklyWindow: self.buildWindow(label: "Weekly window", rawWindow: nil),
            rollingWindow: self.buildWindow(label: "Rolling 5-hour window", rawWindow: primaryWindow)
        )
    }

    private func buildWindow(label: String, rawWindow: [String: Any]?) -> UsageWindow {
        guard let rawWindow else {
            return UsageWindow(
                available: false,
                label: label,
                usedMinutes: 0,
                limitMinutes: 0,
                remainingMinutes: 0,
                usedPercentage: 0,
                resetsAt: ""
            )
        }

        let limitSeconds = (rawWindow["limit_window_seconds"] as? NSNumber)?.intValue ?? 0
        let resetAtEpoch = (rawWindow["reset_at"] as? NSNumber)?.doubleValue ?? 0
        let usedPercent = (rawWindow["used_percent"] as? NSNumber)?.doubleValue ?? 0
        let limitMinutes = Int(round(Double(limitSeconds) / 60))
        let usedMinutes = Int(round(Double(limitMinutes) * (usedPercent / 100)))
        let remainingMinutes = max(limitMinutes - usedMinutes, 0)

        return UsageWindow(
            available: true,
            label: label,
            usedMinutes: usedMinutes,
            limitMinutes: limitMinutes,
            remainingMinutes: remainingMinutes,
            usedPercentage: usedPercent,
            resetsAt: Date(timeIntervalSince1970: resetAtEpoch).ISO8601Format()
        )
    }

    private func projectPace(weeklyWindow: UsageWindow, rollingWindow: UsageWindow) -> PaceSnapshot {
        if !weeklyWindow.available {
            return PaceSnapshot(
                status: "steady",
                summary: "Weekly pace unavailable",
                detail: "This account did not expose a weekly limit window."
            )
        }

        let paceStatus: String

        switch weeklyWindow.usedPercentage {
        case ..<45:
            paceStatus = "ahead"
        case ..<75:
            paceStatus = "steady"
        case ..<90:
            paceStatus = "tight"
        default:
            paceStatus = "over"
        }

        let headroom = max(Int(round(100 - weeklyWindow.usedPercentage)), 0)
        let detail: String

        if rollingWindow.available {
            detail = "Current account is using \(Int(round(rollingWindow.usedPercentage)))% of the rolling window and \(Int(round(weeklyWindow.usedPercentage)))% of the weekly window."
        } else {
            detail = "Current account is using \(Int(round(weeklyWindow.usedPercentage)))% of the weekly window."
        }

        return PaceSnapshot(
            status: paceStatus,
            summary: "\(headroom)% weekly headroom left",
            detail: detail
        )
    }

    private func mergeSnapshots(
        existing: CachePayload,
        incoming: [AccountSnapshot]
    ) -> CachePayload {
        let incomingByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.accountId, $0) })
        var mergedAccounts: [AccountSnapshot] = []

        for account in existing.accounts {
            guard let replacement = incomingByID[account.accountId] else {
                mergedAccounts.append(account)
                continue
            }

            mergedAccounts.append(
                AccountSnapshot(
                    accountId: replacement.accountId,
                    label: replacement.label,
                    email: replacement.email,
                    workspaceLabel: replacement.workspaceLabel,
                    plan: replacement.plan,
                    color: replacement.color,
                    source: replacement.source,
                    lastSyncedAt: replacement.lastSyncedAt,
                    weeklyWindow: replacement.weeklyWindow,
                    rollingWindow: replacement.rollingWindow,
                    pace: replacement.pace,
                    history: self.mergedHistory(existing: account.history, next: replacement.history.first)
                )
            )
        }

        for snapshot in incoming where !mergedAccounts.contains(where: { $0.accountId == snapshot.accountId }) {
            mergedAccounts.append(snapshot)
        }

        mergedAccounts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        return CachePayload(
            meta: CacheMeta(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                cachePath: CodexBoardPaths.cache.path(percentEncoded: false),
                source: "native-swift-cache"
            ),
            accounts: mergedAccounts
        )
    }

    private func mergedHistory(
        existing: [HistorySnapshot],
        next: HistorySnapshot?
    ) -> [HistorySnapshot] {
        guard let next else {
            return existing
        }

        if let last = existing.last,
           last.weeklyUsedMinutes == next.weeklyUsedMinutes,
           last.rollingUsedMinutes == next.rollingUsedMinutes
        {
            return existing
        }

        return Array((existing + [next]).suffix(12))
    }

    private func displayPlan(_ rawPlan: String?) -> String {
        guard let rawPlan, !rawPlan.isEmpty else {
            return "Codex"
        }

        return "Codex \(rawPlan.prefix(1).uppercased())\(rawPlan.dropFirst())"
    }

    private func syncSupabaseIfConfigured(cache: CachePayload) async throws {
        guard let config = self.loadSupabaseConfig() else {
            return
        }

        guard !cache.accounts.isEmpty else {
            return
        }

        guard let url = URL(string: config.functionURL) else {
            throw PulseError.invalidUsageResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.tokenID, forHTTPHeaderField: "x-codexboard-token-id")
        request.setValue(config.token, forHTTPHeaderField: "x-codexboard-token")
        request.httpBody = try self.encoder.encode(
            SupabaseFunctionPayload(accounts: cache.accounts)
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200 ..< 300 ~= httpResponse.statusCode
        else {
            if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                print("Supabase ingest failed: \(message)")
            }
            throw PulseError.invalidUsageResponse
        }
    }
}

private func formatHours(_ minutes: Int) -> String {
    String(format: "%.1fh", Double(minutes) / 60)
}

private func formatCountdown(_ value: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: value) else {
        return "n/a"
    }

    let diff = Int(date.timeIntervalSinceNow)

    if diff <= 0 {
        return "resetting"
    }

    let minutes = diff / 60
    let days = minutes / (24 * 60)
    let hours = (minutes % (24 * 60)) / 60
    let remainingMinutes = minutes % 60

    if days > 0 {
        return "\(days)d \(hours)h"
    }

    if hours > 0 {
        return "\(hours)h \(remainingMinutes)m"
    }

    return "\(remainingMinutes)m"
}

private func formatRelative(_ value: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: value) else {
        return value
    }

    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func clampPercentage(_ value: Double) -> Double {
    min(100, max(0, value))
}

private func remainingPercentage(for window: UsageWindow) -> Int {
    Int(round(clampPercentage(100 - window.usedPercentage)))
}

private func tierLabel(for plan: String) -> String {
    let normalized = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if normalized.contains("team") {
        return "Team"
    }

    if normalized.contains("free") {
        return "Free"
    }

    if normalized.contains("pro") {
        return "Pro"
    }

    if normalized.hasPrefix("codex ") {
        return String(plan.dropFirst(6))
    }

    return plan
}

private func windowDuration(for window: UsageWindow) -> TimeInterval? {
    let label = window.label.lowercased()

    if label.contains("week") {
        return 7 * 24 * 60 * 60
    }

    if label.contains("5-hour") || label.contains("5h") {
        return 5 * 60 * 60
    }

    return nil
}

private func pacePercentage(for window: UsageWindow) -> Double {
    guard window.available,
          let duration = windowDuration(for: window),
          let resetDate = ISO8601DateFormatter().date(from: window.resetsAt)
    else {
        return 0
    }

    let startDate = resetDate.addingTimeInterval(-duration)
    let elapsed = Date().timeIntervalSince(startDate)
    return clampPercentage((elapsed / duration) * 100)
}

private func nextResetWindow(for account: AccountSnapshot) -> UsageWindow {
    guard account.rollingWindow.available,
          !account.rollingWindow.resetsAt.isEmpty,
          let rollingReset = ISO8601DateFormatter().date(from: account.rollingWindow.resetsAt)
    else {
        return account.weeklyWindow
    }

    guard !account.weeklyWindow.resetsAt.isEmpty,
          let weeklyReset = ISO8601DateFormatter().date(from: account.weeklyWindow.resetsAt)
    else {
        return account.rollingWindow
    }

    return rollingReset <= weeklyReset ? account.rollingWindow : account.weeklyWindow
}

final class NicknameStore: ObservableObject {
    @Published private(set) var nicknames: [String: String]

    private let defaultsKey = "codexboard.nicknames.v1"

    init() {
        self.nicknames = UserDefaults.standard.dictionary(forKey: self.defaultsKey) as? [String: String] ?? [:]
    }

    func displayName(for account: AccountSnapshot) -> String {
        let nickname = self.nicknames[account.accountId]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return nickname.isEmpty ? account.label : nickname
    }

    func nickname(for account: AccountSnapshot) -> String {
        self.nicknames[account.accountId] ?? ""
    }

    func saveNickname(_ value: String, for account: AccountSnapshot) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            self.nicknames.removeValue(forKey: account.accountId)
        } else {
            self.nicknames[account.accountId] = trimmed
        }

        UserDefaults.standard.set(self.nicknames, forKey: self.defaultsKey)
    }
}

struct WindowCardView: View {
    let window: UsageWindow
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack {
                Text(window.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(window.available ? "\(remainingPercentage(for: window))% left" : "n/a")
                    .font(.caption.weight(.semibold))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 999)
                        .fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 999)
                        .fill(Color.white.opacity(0.12))
                        .frame(
                            width: geometry.size.width * CGFloat(pacePercentage(for: window) / 100)
                        )
                    LinearGradient(
                        colors: [
                            Color(red: 0.4, green: 0.49, blue: 0.92),
                            Color(red: 0.46, green: 0.29, blue: 0.64),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                        .frame(width: geometry.size.width)
                        .mask(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 999)
                                .frame(
                                    width: geometry.size.width * CGFloat(clampPercentage(window.usedPercentage) / 100)
                                )
                        }
                }
            }
            .frame(height: compact ? 8 : 14)
            .opacity(window.available ? 1 : 0)

            if !compact {
                Text(formatCountdown(window.resetsAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AccountEditorView: View {
    let account: AccountSnapshot
    let initialNickname: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftNickname: String

    init(
        account: AccountSnapshot,
        initialNickname: String,
        onSave: @escaping (String) -> Void
    ) {
        self.account = account
        self.initialNickname = initialNickname
        self.onSave = onSave
        self._draftNickname = State(initialValue: initialNickname)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit nickname")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Email")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(account.email)
                    .font(.body)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Nickname")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Nickname", text: self.$draftNickname)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Save") {
                    onSave(self.draftNickname)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

struct AccountCardView: View {
    let account: AccountSnapshot
    let displayName: String
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(displayName)
                            .font(.title3.weight(.semibold))
                        Button("Edit") {
                            onEdit()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Text(tierLabel(for: account.plan))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            WindowCardView(window: account.weeklyWindow, compact: false)

            if account.rollingWindow.available {
                WindowCardView(window: account.rollingWindow, compact: true)
            }

            HStack {
                Text("Reset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatCountdown(nextResetWindow(for: account).resetsAt))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

struct NextResetSectionView: View {
    let accounts: [AccountSnapshot]
    let nicknameStore: NicknameStore

    var body: some View {
        if let nextResetAccount = accounts
            .map({ account in (account: account, window: nextResetWindow(for: account)) })
            .filter({ !$0.window.resetsAt.isEmpty })
            .sorted(by: { $0.window.resetsAt < $1.window.resetsAt })
            .first {
            VStack(alignment: .leading, spacing: 12) {
                Text("NEXT RESET")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                HStack {
                    Text(nicknameStore.displayName(for: nextResetAccount.account))
                        .font(.title.weight(.bold))
                    Spacer()
                    Text(formatCountdown(nextResetAccount.window.resetsAt))
                        .font(.title3.weight(.semibold))
                }
            }
            .padding(20)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
    }
}

struct DashboardView: View {
    @ObservedObject var coordinator: PulseCoordinator
    @StateObject private var nicknameStore = NicknameStore()
    @State private var editingAccount: AccountSnapshot?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.11, blue: 0.16),
                    Color(red: 0.04, green: 0.06, blue: 0.09),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    NextResetSectionView(
                        accounts: coordinator.cache.accounts,
                        nicknameStore: nicknameStore
                    )

                    Text("ACCOUNTS")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    ForEach(coordinator.cache.accounts) { account in
                        AccountCardView(
                            account: account,
                            displayName: nicknameStore.displayName(for: account),
                            onEdit: {
                                editingAccount = account
                            }
                        )
                    }
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: self.$editingAccount) { account in
            AccountEditorView(
                account: account,
                initialNickname: nicknameStore.nickname(for: account),
                onSave: { nickname in
                    nicknameStore.saveNickname(nickname, for: account)
                }
            )
        }
    }
}

struct PulseMenuView: View {
    @ObservedObject var coordinator: PulseCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CodexBoard")
                .font(.headline)

            Text(coordinator.statusLine)
                .font(.subheadline)

            Text("Accounts: \(coordinator.accountCount)")
                .foregroundStyle(.secondary)

            if let lastSyncedAt = coordinator.lastSyncedAt {
                Text("Last sync: \(formatRelative(lastSyncedAt))")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Open dashboard") {
                    openWindow(id: "dashboard")
                }

                Button("Sync now") {
                    Task { @MainActor in
                        await coordinator.syncNow()
                    }
                }
            }

            Divider()

            Text("Cache: \(CodexBoardPaths.cache.path(percentEncoded: false))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(width: 360)
        .padding(16)
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let red = Double((int >> 16) & 0xFF) / 255
        let green = Double((int >> 8) & 0xFF) / 255
        let blue = Double(int & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

@main
struct CodexBoardPulseApp: App {
    @StateObject private var coordinator = PulseCoordinator()

    var body: some Scene {
        MenuBarExtra("CodexBoard", systemImage: "gauge.with.needle") {
            PulseMenuView(coordinator: coordinator)
                .task {
                    coordinator.start()
                }
        }
        .menuBarExtraStyle(.window)

        Window("CodexBoard", id: "dashboard") {
            DashboardView(coordinator: coordinator)
                .task {
                    coordinator.start()
                }
                .frame(minWidth: 1120, minHeight: 760)
        }
        .windowResizability(.contentSize)
    }
}
