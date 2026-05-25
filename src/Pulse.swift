import Foundation
import SwiftUI

@MainActor
final class PulseCoordinator: ObservableObject {
    @Published var cache = CachePayload(
        meta: CacheMeta(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            cachePath: CodexMuxPaths.cache.path(percentEncoded: false),
            source: "native-swift-cache"
        ),
        accounts: []
    )
    @Published private(set) var removableAccountIDs = Set<String>()

    private let cacheStore = CacheStore()
    private let accountConfigStore = AccountConfigStore()
    private var hasStarted = false
    private var isSyncing = false
    nonisolated(unsafe) private var syncTimer: Timer?

    var accountCount: Int {
        self.cache.accounts.count
    }

    func start() {
        guard !self.hasStarted else {
            return
        }

        self.hasStarted = true
        self.cache = self.cacheStore.load()
        self.removableAccountIDs = self.buildRemovableAccountIDs(
            for: self.cache.accounts,
            config: self.loadConfig()
        )

        // Initial sync
        Task {
            await self.syncNow()
        }

        // Periodic sync every 2 minutes
        self.syncTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.syncNow()
            }
        }
    }

    deinit {
        self.syncTimer?.invalidate()
    }

    func syncNow() async {
        guard !self.isSyncing else {
            return
        }

        self.isSyncing = true
        defer {
            self.isSyncing = false
        }

        do {
            let config = self.loadConfig()
            var incomingSnapshots: [AccountSnapshot] = []

            incomingSnapshots.append(contentsOf: try await self.buildSystemSnapshotsIfAvailable())

            if !incomingSnapshots.isEmpty {
                self.publishMergedSnapshots(
                    incomingSnapshots,
                    config: config
                )
            }

            for account in config.accounts {
                let snapshot = try await self.buildCookieSnapshot(for: account)
                incomingSnapshots.append(snapshot)
                self.publishMergedSnapshots(
                    incomingSnapshots,
                    config: config
                )
            }
        } catch {
            return
        }
    }

    func isRemovable(_ account: AccountSnapshot) -> Bool {
        self.removableAccountIDs.contains(account.accountId)
    }

    func removeAccount(_ account: AccountSnapshot) throws {
        guard let configAccountID = self.configAccountID(for: account, in: self.loadConfig()) else {
            return
        }

        try self.accountConfigStore.removeAccount(withID: configAccountID)
        self.cache = try self.cacheStore.removeAccount(withID: account.accountId)
        self.removableAccountIDs.remove(account.accountId)
    }

    private func loadConfig() -> PulseConfig {
        self.accountConfigStore.load()
    }

    private func buildSystemSnapshotsIfAvailable() async throws -> [AccountSnapshot] {
        guard let identity = try self.loadSystemIdentity() else {
            return []
        }

        let currentUsage = try await self.fetchUsagePayload(
            accessToken: identity.accessToken,
            cookieHeader: nil,
            usageEndpoint: "https://chatgpt.com/backend-api/wham/usage",
            accountHeader: nil
        )
        let currentWorkspaceAccountID = self.normalizeWorkspaceAccountID(
            (currentUsage["account_id"] as? String) ?? identity.accountId
        )
        let workspaceItems = try await self.fetchWorkspaceItems(
            accessToken: identity.accessToken,
            cookieHeader: nil
        )

        if workspaceItems.isEmpty {
            return [
                try self.normalizeUsage(
                    currentUsage,
                    accountID: currentUsage["account_id"] as? String
                        ?? identity.accountId
                        ?? identity.subject
                        ?? UUID().uuidString,
                    label: identity.name ?? currentUsage["email"] as? String ?? identity.email ?? "Current system account",
                    email: currentUsage["email"] as? String ?? identity.email ?? "Unknown account",
                    workspaceLabel: self.resolveWorkspaceName(
                        currentUsage,
                        workspaceItem: nil,
                        identity: identity
                    ),
                    plan: self.displayPlan(currentUsage["plan_type"] as? String ?? identity.planType),
                    color: "#8cf5b0",
                    source: "live system auth",
                    isCurrentSystemAccount: true,
                    note: "Native Swift sync from local Codex auth."
                )
            ]
        }

        var snapshots: [AccountSnapshot] = []

        for workspaceItem in workspaceItems {
            let workspaceAccountID = self.normalizeWorkspaceAccountID(workspaceItem.id)
            let rawUsage: [String: Any]

            if workspaceAccountID == currentWorkspaceAccountID {
                rawUsage = currentUsage
            } else {
                rawUsage = try await self.fetchUsagePayload(
                    accessToken: identity.accessToken,
                    cookieHeader: nil,
                    usageEndpoint: "https://chatgpt.com/backend-api/wham/usage",
                    accountHeader: workspaceAccountID
                )
            }

            snapshots.append(
                try self.normalizeUsage(
                    rawUsage,
                    accountID: workspaceItem.id,
                    label: identity.name ?? rawUsage["email"] as? String ?? identity.email ?? "Current system account",
                    email: rawUsage["email"] as? String ?? identity.email ?? "Unknown account",
                    workspaceLabel: self.resolveWorkspaceName(
                        rawUsage,
                        workspaceItem: workspaceItem,
                        identity: identity
                    ),
                    plan: self.displayPlan(rawUsage["plan_type"] as? String ?? identity.planType),
                    color: "#8cf5b0",
                    source: "live system auth",
                    isCurrentSystemAccount: workspaceAccountID == currentWorkspaceAccountID,
                    note: "Native Swift sync from local Codex auth."
                )
            )
        }

        return snapshots
    }

    private func buildCookieSnapshot(for account: AccountConfig) async throws -> AccountSnapshot {
        let accessToken = try await self.fetchAccessToken(for: account)
        let rawUsage = try await self.fetchUsagePayload(
            accessToken: accessToken,
            cookieHeader: account.chatGPTCookie,
            usageEndpoint: account.usageEndpoint ?? "https://chatgpt.com/backend-api/wham/usage",
            accountHeader: account.accountHeader
        )
        let workspaceAccountID = account.accountHeader?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? account.accountHeader?.trimmingCharacters(in: .whitespacesAndNewlines)
            : (rawUsage["account_id"] as? String)
        let workspaceLabel = try await self.fetchWorkspaceLabel(
            accessToken: accessToken,
            cookieHeader: account.chatGPTCookie,
            workspaceAccountID: workspaceAccountID
        ) ?? account.workspaceLabel

        return try self.normalizeUsage(
            rawUsage,
            accountID: account.id,
            label: account.label,
            email: account.email,
            workspaceLabel: workspaceLabel,
            plan: self.displayPlan(rawUsage["plan_type"] as? String) == "Codex"
                ? account.plan
                : self.displayPlan(rawUsage["plan_type"] as? String),
            color: account.color,
            source: account.source ?? "native cookie sync",
            isCurrentSystemAccount: false,
            note: "Native Swift sync from account cookie."
        )
    }

    private func loadSystemIdentity() throws -> SystemAuthIdentity? {
        guard FileManager.default.fileExists(atPath: CodexMuxPaths.codexAuth.path(percentEncoded: false)) else {
            return nil
        }

        let data = try Data(contentsOf: CodexMuxPaths.codexAuth)
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
            organizationTitles: self.resolveOrganizationTitles(from: planClaims),
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

    private func fetchWorkspaceItems(
        accessToken: String,
        cookieHeader: String?
    ) async throws -> [WorkspaceItem] {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/accounts")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            return []
        }

        let payload = try JSONDecoder().decode(WorkspaceIdentity.self, from: data)
        return payload.items
    }

    private func fetchWorkspaceLabel(
        accessToken: String,
        cookieHeader: String?,
        workspaceAccountID: String?
    ) async throws -> String? {
        let normalizedWorkspaceAccountID = self.normalizeWorkspaceAccountID(workspaceAccountID)
        let workspaceItems = try await self.fetchWorkspaceItems(
            accessToken: accessToken,
            cookieHeader: cookieHeader
        )
        let matchingWorkspace: WorkspaceItem?

        if let normalizedWorkspaceAccountID {
            matchingWorkspace = workspaceItems.first { item in
                self.normalizeWorkspaceAccountID(item.id) == normalizedWorkspaceAccountID
            }
        } else {
            matchingWorkspace = workspaceItems.first
        }

        guard let matchingWorkspace else {
            return nil
        }

        let trimmedName = matchingWorkspace.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? "Personal" : trimmedName
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
        isCurrentSystemAccount: Bool,
        note: String
    ) throws -> AccountSnapshot {
        let windows = self.resolveWindows(rateLimit: payload["rate_limit"] as? [String: Any])
        let now = ISO8601DateFormatter().string(from: Date())
        let pace = self.projectPace(weeklyWindow: windows.weeklyWindow, rollingWindow: windows.rollingWindow)
        let resolvedWorkspaceLabel = normalizedWorkspaceLabel(
            self.resolveWorkspaceLabel(
            payload: payload,
            fallback: workspaceLabel
            ),
            plan: plan
        )
        let resolvedPlan = normalizedPlanLabel(
            plan,
            workspaceLabel: resolvedWorkspaceLabel
        )
        let snapshotKey = buildSnapshotKey(
            accountId: accountID,
            email: email,
            isCurrentSystemAccount: isCurrentSystemAccount
        )

        return AccountSnapshot(
            accountId: snapshotKey,
            label: label,
            email: email,
            workspaceLabel: resolvedWorkspaceLabel,
            plan: resolvedPlan,
            color: color,
            source: source,
            isCurrentSystemAccount: isCurrentSystemAccount,
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

    private func resolveWorkspaceLabel(
        payload: [String: Any],
        fallback: String
    ) -> String {
        let directCandidates = [
            "workspace_name",
            "workspaceName",
            "team_workspace_name",
            "teamWorkspaceName",
            "current_workspace_name",
            "currentWorkspaceName",
            "organization_name",
            "organizationName",
            "account_organization",
            "accountOrganization"
        ]

        for key in directCandidates {
            if let value = payload[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }

        let nestedCandidates = [
            "workspace",
            "current_workspace",
            "team",
            "organization",
            "account",
            "identity",
            "subscription"
        ]

        for key in nestedCandidates {
            guard let nested = payload[key] as? [String: Any] else {
                continue
            }

            for nestedKey in [
                "name",
                "title",
                "workspace_name",
                "display_name",
                "organization_name",
                "account_organization"
            ] {
                if let value = nested[nestedKey] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }

        return fallback
    }

    private func resolveOrganizationTitles(from authClaims: [String: Any]?) -> [String] {
        guard let organizations = authClaims?["organizations"] as? [[String: Any]] else {
            return []
        }

        return organizations.compactMap { organization in
            for key in ["title", "name", "display_name"] {
                if let value = organization[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }

            return nil
        }
    }

    private func defaultWorkspaceLabel(for identity: SystemAuthIdentity, plan: String?) -> String {
        if isPersonalPlan(self.displayPlan(plan)) {
            return "Personal"
        }

        if let organizationTitle = identity.organizationTitles.first(where: {
            $0.caseInsensitiveCompare("Personal") != .orderedSame
        }) {
            return organizationTitle
        }

        return "Personal"
    }

    private func resolveWorkspaceName(
        _ payload: [String: Any],
        workspaceItem: WorkspaceItem?,
        identity: SystemAuthIdentity
    ) -> String {
        let fallbackName = workspaceItem?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payloadPlan = payload["plan_type"] as? String ?? identity.planType
        let fallback = fallbackName.isEmpty
            ? self.defaultWorkspaceLabel(for: identity, plan: payloadPlan)
            : fallbackName

        return normalizedWorkspaceLabel(
            self.resolveWorkspaceLabel(
                payload: payload,
                fallback: fallback
            ),
            plan: self.displayPlan(payloadPlan)
        )
    }

    private func normalizeWorkspaceAccountID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        return trimmed.lowercased()
    }

    private func configAccountID(for account: AccountSnapshot, in config: PulseConfig) -> String? {
        guard account.source != "live system auth" else {
            return nil
        }

        let normalizedPrefix = legacyBaseAccountID(from: account.accountId)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedPrefix.isEmpty else {
            return nil
        }

        return config.accounts.first(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedPrefix
        })?.id
    }

    private func buildRemovableAccountIDs(
        for accounts: [AccountSnapshot],
        config: PulseConfig
    ) -> Set<String> {
        Set(
            accounts.compactMap { account in
                self.configAccountID(for: account, in: config).map { _ in account.accountId }
            }
        )
    }

    private func buildWindow(label: String, rawWindow: [String: Any]?) -> UsageWindow {
        guard let rawWindow else {
            return UsageWindow(
                available: false,
                label: label,
                usedMinutes: 0,
                limitMinutes: 0,
                usedPercentage: 0,
                resetsAt: ""
            )
        }

        let limitSeconds = (rawWindow["limit_window_seconds"] as? NSNumber)?.intValue ?? 0
        let resetAtEpoch = (rawWindow["reset_at"] as? NSNumber)?.doubleValue ?? 0
        let usedPercent = (rawWindow["used_percent"] as? NSNumber)?.doubleValue ?? 0
        let limitMinutes = Int(round(Double(limitSeconds) / 60))
        let usedMinutes = Int(round(Double(limitMinutes) * (usedPercent / 100)))

        return UsageWindow(
            available: true,
            label: label,
            usedMinutes: usedMinutes,
            limitMinutes: limitMinutes,
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
        var existingByIdentity: [String: AccountSnapshot] = [:]
        let existingAccounts = existing.accounts

        for account in existing.accounts {
            let identity = self.snapshotIdentity(for: account)
            let prior = existingByIdentity[identity]
            existingByIdentity[identity] = self.preferredStoredSnapshot(prior, candidate: account)
        }

        var activeIdentity: String?

        for snapshot in incoming {
            let identity = self.resolvedIncomingIdentity(
                for: snapshot,
                existingAccounts: existingAccounts,
                mergedAccounts: Array(existingByIdentity.values)
            )
            let prior = existingByIdentity[identity]

            existingByIdentity[identity] = AccountSnapshot(
                accountId: identity,
                label: snapshot.label,
                email: snapshot.email,
                workspaceLabel: snapshot.workspaceLabel,
                plan: snapshot.plan,
                color: snapshot.color,
                source: snapshot.source,
                isCurrentSystemAccount: snapshot.isCurrentSystemAccount,
                lastSyncedAt: snapshot.lastSyncedAt,
                weeklyWindow: snapshot.weeklyWindow,
                rollingWindow: snapshot.rollingWindow,
                pace: snapshot.pace,
                history: self.mergedHistory(
                    existing: prior?.history ?? [],
                    next: snapshot.history.first
                )
            )

            if snapshot.isCurrentSystemAccount == true {
                activeIdentity = identity
            }
        }

        var mergedAccounts = Array(existingByIdentity.values)

        if let activeIdentity {
            mergedAccounts = mergedAccounts.map { account in
                let isActive = account.accountId == activeIdentity

                return AccountSnapshot(
                    accountId: account.accountId,
                    label: account.label,
                    email: account.email,
                    workspaceLabel: account.workspaceLabel,
                    plan: account.plan,
                    color: account.color,
                    source: account.source,
                    isCurrentSystemAccount: isActive,
                    lastSyncedAt: account.lastSyncedAt,
                    weeklyWindow: account.weeklyWindow,
                    rollingWindow: account.rollingWindow,
                    pace: account.pace,
                    history: account.history
                )
            }
        } else {
            mergedAccounts = mergedAccounts.map { account in
                AccountSnapshot(
                    accountId: account.accountId,
                    label: account.label,
                    email: account.email,
                    workspaceLabel: account.workspaceLabel,
                    plan: account.plan,
                    color: account.color,
                    source: account.source,
                    isCurrentSystemAccount: false,
                    lastSyncedAt: account.lastSyncedAt,
                    weeklyWindow: account.weeklyWindow,
                    rollingWindow: account.rollingWindow,
                    pace: account.pace,
                    history: account.history
                )
            }
        }

        mergedAccounts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        return CachePayload(
            meta: CacheMeta(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                cachePath: CodexMuxPaths.cache.path(percentEncoded: false),
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
           last.rollingUsedMinutes == next.rollingUsedMinutes {
            return existing
        }

        return Array((existing + [next]).suffix(12))
    }

    private func snapshotIdentity(for account: AccountSnapshot) -> String {
        buildSnapshotKey(
            accountId: account.accountId,
            email: account.email,
            isCurrentSystemAccount: account.isCurrentSystemAccount == true
        )
    }

    private func resolvedIncomingIdentity(
        for account: AccountSnapshot,
        existingAccounts: [AccountSnapshot],
        mergedAccounts: [AccountSnapshot]
    ) -> String {
        let defaultIdentity = self.snapshotIdentity(for: account)

        guard account.isCurrentSystemAccount == true,
              let matchedIdentity = self.matchingCachedIdentity(
                for: account,
                candidates: existingAccounts + mergedAccounts
              )
        else {
            return defaultIdentity
        }

        return matchedIdentity
    }

    private func matchingCachedIdentity(
        for account: AccountSnapshot,
        candidates: [AccountSnapshot]
    ) -> String? {
        let normalizedEmail = account.email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedWorkspace = account.workspaceLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedPlan = account.plan
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedEmail.isEmpty else {
            return nil
        }

        return candidates.first { candidate in
            guard candidate.isCurrentSystemAccount != true else {
                return false
            }

            let candidateEmail = candidate.email
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let candidateWorkspace = candidate.workspaceLabel
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let candidatePlan = candidate.plan
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            guard candidateEmail == normalizedEmail,
                  candidateWorkspace == normalizedWorkspace,
                  candidatePlan == normalizedPlan
            else {
                return false
            }

            return candidate.accountId.hasPrefix("system::") == false
        }
        .map { self.snapshotIdentity(for: $0) }
    }

    private func preferredStoredSnapshot(
        _ current: AccountSnapshot?,
        candidate: AccountSnapshot
    ) -> AccountSnapshot {
        guard let current else {
            return candidate
        }

        let currentDate = ISO8601DateFormatter().date(from: current.lastSyncedAt) ?? .distantPast
        let candidateDate = ISO8601DateFormatter().date(from: candidate.lastSyncedAt) ?? .distantPast
        let newest = candidateDate >= currentDate ? candidate : current
        let oldest = candidateDate >= currentDate ? current : candidate

        return AccountSnapshot(
            accountId: self.snapshotIdentity(for: newest),
            label: newest.label,
            email: newest.email,
            workspaceLabel: newest.workspaceLabel,
            plan: newest.plan,
            color: newest.color,
            source: newest.source,
            isCurrentSystemAccount: newest.isCurrentSystemAccount,
            lastSyncedAt: newest.lastSyncedAt,
            weeklyWindow: newest.weeklyWindow,
            rollingWindow: newest.rollingWindow,
            pace: newest.pace,
            history: Array((oldest.history + newest.history).suffix(12))
        )
    }

    private func displayPlan(_ rawPlan: String?) -> String {
        guard let rawPlan, !rawPlan.isEmpty else {
            return "Codex"
        }

        return "Codex \(rawPlan.prefix(1).uppercased())\(rawPlan.dropFirst())"
    }

    private func publishMergedSnapshots(
        _ snapshots: [AccountSnapshot],
        config: PulseConfig
    ) {
        let merged = self.mergeSnapshots(
            existing: self.cache,
            incoming: snapshots
        )

        try? self.cacheStore.save(merged)
        self.cache = merged
        self.removableAccountIDs = self.buildRemovableAccountIDs(
            for: merged.accounts,
            config: config
        )
    }
}
