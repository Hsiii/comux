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

private func toneColor(_ status: String) -> Color {
    switch status {
    case "ahead":
        return Color(red: 0.55, green: 0.96, blue: 0.69)
    case "tight":
        return Color(red: 1, green: 0.74, blue: 0.43)
    case "over":
        return Color(red: 1, green: 0.5, blue: 0.5)
    default:
        return Color(red: 0.4, green: 0.83, blue: 1)
    }
}

struct WindowCardView: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(window.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(window.available ? "\(Int(round(window.usedPercentage)))%" : "n/a")
                    .font(.caption.weight(.semibold))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 999)
                        .fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 999)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.4, green: 0.83, blue: 1),
                                    Color(red: 1, green: 0.88, blue: 0.41),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: window.available
                                ? geometry.size.width * CGFloat(window.usedPercentage / 100)
                                : 0
                        )
                }
            }
            .frame(height: 10)

            if window.available {
                Text("\(formatHours(window.usedMinutes)) / \(formatHours(window.limitMinutes))")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                Text("\(window.remainingMinutes)m left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Resets in \(formatCountdown(window.resetsAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Unavailable")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                Text("This account did not expose this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct AccountCardView: View {
    let account: AccountSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(account.plan.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(account.label)
                        .font(.title3.weight(.semibold))
                    Text("\(account.email) / \(account.workspaceLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label(account.source, systemImage: "circle.fill")
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color(hex: account.color), .secondary)
            }

            HStack(spacing: 12) {
                WindowCardView(window: account.weeklyWindow)
                WindowCardView(window: account.rollingWindow)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("PACE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(account.pace.summary)
                    .font(.headline)
                    .foregroundStyle(toneColor(account.pace.status))
                Text(account.pace.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let latest = account.history.last {
                HStack {
                    Text("Last sync \(formatRelative(account.lastSyncedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(latest.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

struct SummaryStripView: View {
    let cache: CachePayload

    var body: some View {
        let accounts = cache.accounts
        let weeklyMinutes = accounts.reduce(0) { partialResult, account in
            partialResult + (account.weeklyWindow.available ? account.weeklyWindow.usedMinutes : 0)
        }
        let rollingMinutes = accounts.reduce(0) { partialResult, account in
            partialResult + (account.rollingWindow.available ? account.rollingWindow.usedMinutes : 0)
        }
        let nextReset = accounts
            .filter { $0.rollingWindow.available }
            .sorted { $0.rollingWindow.resetsAt < $1.rollingWindow.resetsAt }
            .first

        return HStack(spacing: 12) {
            SummaryTileView(
                title: "Tracked accounts",
                value: "\(accounts.count)",
                detail: "System account plus any extra cookie accounts."
            )
            SummaryTileView(
                title: "Weekly burn",
                value: formatHours(weeklyMinutes),
                detail: "Combined across all visible accounts."
            )
            SummaryTileView(
                title: "Rolling 5h",
                value: formatHours(rollingMinutes),
                detail: "Fast comparison of near-term pressure."
            )
            SummaryTileView(
                title: "Next reset",
                value: nextReset.map { formatCountdown($0.rollingWindow.resetsAt) } ?? "n/a",
                detail: nextReset?.label ?? "No rolling window available."
            )
        }
    }
}

struct SummaryTileView: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

struct DashboardView: View {
    @ObservedObject var coordinator: PulseCoordinator

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
                    VStack(alignment: .leading, spacing: 12) {
                        Text("CODEXBOARD")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(red: 1, green: 0.88, blue: 0.41))
                        Text("Native Codex usage board for the current system account and any extra accounts you attach.")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text(coordinator.statusLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    SummaryStripView(cache: coordinator.cache)

                    ForEach(coordinator.cache.accounts) { account in
                        AccountCardView(account: account)
                    }
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
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
