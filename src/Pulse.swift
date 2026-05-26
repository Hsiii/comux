import Foundation
import SwiftUI

@MainActor
final class PulseCoordinator: ObservableObject {
    @Published var cache = CachePayload(
        meta: CacheMeta(
            source: "native-swift-cache"
        ),
        accounts: []
    )
    @Published private(set) var removableAccountIDs = Set<String>()

    private let cacheStore = CacheStore()
    private let accountConfigStore = AccountConfigStore()
    private let durableStore = DurableStoreCoordinator.shared
    private var hasStarted = false
    private var isSyncing = false
    nonisolated(unsafe) private var syncTimer: Timer?
    nonisolated(unsafe) private var authMonitorSource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var authMonitorFileDescriptor: CInt = -1
    private var lastObservedAuthSignature: AuthFileSignature?
    private var hasPendingAuthRetry = false

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
        self.lastObservedAuthSignature = self.currentAuthFileSignature()
        self.startAuthFileMonitor()

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
        self.authMonitorSource?.cancel()
        if self.authMonitorFileDescriptor >= 0 {
            close(self.authMonitorFileDescriptor)
            self.authMonitorFileDescriptor = -1
        }
    }

    func syncNow() async {
        guard !self.isSyncing else {
            return
        }

        self.isSyncing = true
        defer {
            self.isSyncing = false
        }

        let config = self.loadConfig()
        var incomingSnapshots: [AccountSnapshot] = []
        var didRefreshSystemState = false

        do {
            let systemRefresh = try await self.buildSystemSnapshotRefresh()
            incomingSnapshots.append(contentsOf: systemRefresh.snapshots)
            didRefreshSystemState = true
        } catch {
            self.lastObservedAuthSignature = self.currentAuthFileSignature()
            self.scheduleAuthRefreshRetryIfNeeded()
        }

        if didRefreshSystemState || !incomingSnapshots.isEmpty {
            self.publishMergedSnapshots(
                incomingSnapshots,
                config: config
            )
        }

        for account in config.accounts {
            do {
                let snapshot = try await self.buildCookieSnapshot(for: account)
                incomingSnapshots.append(snapshot)
                self.publishMergedSnapshots(
                    incomingSnapshots,
                    config: config
                )
            } catch {
                continue
            }
        }

        self.lastObservedAuthSignature = self.currentAuthFileSignature()
    }

    func isRemovable(_ account: AccountSnapshot) -> Bool {
        self.removableAccountIDs.contains(account.accountId)
    }

    func removeAccount(_ account: AccountSnapshot) throws {
        let existingConfig = self.loadConfig()

        guard let configAccountID = self.configAccountID(for: account, in: existingConfig) else {
            return
        }

        let filteredConfig = PulseConfig(
            pollIntervalSeconds: existingConfig.pollIntervalSeconds,
            accounts: existingConfig.accounts.filter { $0.id != configAccountID }
        )
        let filteredAccounts = self.cache.accounts.filter { $0.accountId != account.accountId }
        let filteredCache = CachePayload(
            meta: CacheMeta(
                source: self.cache.meta.source
            ),
            accounts: filteredAccounts
        )

        try self.durableStore.saveCacheAndConfig(
            cache: filteredCache,
            config: filteredConfig,
            event: "account.remove"
        )

        self.cache = filteredCache
        self.removableAccountIDs.remove(account.accountId)
    }

    private func loadConfig() -> PulseConfig {
        self.accountConfigStore.load()
    }

    private func buildSystemSnapshotRefresh() async throws -> SystemSnapshotRefresh {
        guard let identity = try self.loadSystemIdentity() else {
            return SystemSnapshotRefresh(snapshots: [])
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

        var snapshots: [AccountSnapshot] = []

        for workspaceItem in workspaceItems {
            let workspaceAccountID = self.trimmedWorkspaceAccountID(workspaceItem.id)
            let rawUsage: [String: Any]

            if self.normalizeWorkspaceAccountID(workspaceAccountID) == currentWorkspaceAccountID {
                rawUsage = currentUsage
            } else {
                rawUsage = try await self.fetchUsagePayload(
                    accessToken: identity.accessToken,
                    cookieHeader: nil,
                    usageEndpoint: "https://chatgpt.com/backend-api/wham/usage",
                    accountHeader: workspaceAccountID
                )
            }

            let responseWorkspaceAccountID = self.normalizeWorkspaceAccountID(
                rawUsage["account_id"] as? String
            )

            if let workspaceAccountID,
               responseWorkspaceAccountID != nil,
               responseWorkspaceAccountID != self.normalizeWorkspaceAccountID(workspaceAccountID) {
                continue
            }

            snapshots.append(
                try self.normalizeUsage(
                    rawUsage,
                    accountID: workspaceItem.id,
                    label: identity.name ?? rawUsage["email"] as? String ?? identity.email ?? "Current system account",
                    email: rawUsage["email"] as? String ?? identity.email ?? "Unknown account",
                    workspaceID: workspaceItem.id,
                    workspaceLabel: self.resolveWorkspaceName(
                        rawUsage,
                        workspaceItem: workspaceItem,
                        identity: identity
                    ),
                    plan: self.displayPlan(rawUsage["plan_type"] as? String ?? identity.planType),
                    source: "live system auth",
                    systemAuthProfileID: normalizedSystemAuthProfileID(identity.subject ?? identity.email),
                    isCurrentSystemAccount: self.normalizeWorkspaceAccountID(workspaceAccountID) == currentWorkspaceAccountID
                )
            )
        }

        if snapshots.allSatisfy({ $0.isCurrentSystemAccount != true }) {
            snapshots.append(
                try self.buildCurrentSystemSnapshot(
                    currentUsage,
                    identity: identity
                )
            )
        }

        return SystemSnapshotRefresh(snapshots: snapshots)
    }

    private func buildCurrentSystemSnapshot(
        _ currentUsage: [String: Any],
        identity: SystemAuthIdentity
    ) throws -> AccountSnapshot {
        let plan = self.displayPlan(currentUsage["plan_type"] as? String ?? identity.planType)
        let workspaceLabel = self.resolveWorkspaceName(
            currentUsage,
            workspaceItem: nil,
            identity: identity
        )
        let workspaceID = normalizedWorkspaceLabel(workspaceLabel, plan: plan) == "Personal"
            ? nil
            : currentUsage["account_id"] as? String ?? identity.accountId

        return try self.normalizeUsage(
            currentUsage,
            accountID: workspaceID ?? identity.subject ?? UUID().uuidString,
            label: identity.name ?? currentUsage["email"] as? String ?? identity.email ?? "Current system account",
            email: currentUsage["email"] as? String ?? identity.email ?? "Unknown account",
            workspaceID: workspaceID,
            workspaceLabel: workspaceLabel,
            plan: plan,
            source: "live system auth",
            systemAuthProfileID: normalizedSystemAuthProfileID(identity.subject ?? identity.email),
            isCurrentSystemAccount: true
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
        let workspaceAccountID = account.accountHeader?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? account.accountHeader?.trimmingCharacters(in: .whitespacesAndNewlines)
            : (rawUsage["account_id"] as? String)
        let workspaceLabel = (try? await self.fetchWorkspaceLabel(
            accessToken: accessToken,
            cookieHeader: account.chatGPTCookie,
            workspaceAccountID: workspaceAccountID
        )) ?? account.workspaceLabel

        return try self.normalizeUsage(
            rawUsage,
            accountID: account.id,
            label: account.label,
            email: account.email,
            workspaceID: workspaceAccountID,
            workspaceLabel: workspaceLabel,
            plan: self.displayPlan(rawUsage["plan_type"] as? String) == "Codex"
                ? account.plan
                : self.displayPlan(rawUsage["plan_type"] as? String),
            source: account.source ?? "native cookie sync",
            systemAuthProfileID: nil,
            isCurrentSystemAccount: false
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
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PulseError.workspaceListUnavailable
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PulseError.workspaceListUnavailable
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
        workspaceID: String?,
        workspaceLabel: String,
        plan: String,
        source: String,
        systemAuthProfileID: String?,
        isCurrentSystemAccount: Bool
    ) throws -> AccountSnapshot {
        let windows = self.resolveWindows(rateLimit: payload["rate_limit"] as? [String: Any])
        let now = ISO8601DateFormatter().string(from: Date())
        let resolvedWorkspaceLabel = self.resolveWorkspaceLabel(
            payload: payload,
            fallback: workspaceLabel
        )
        let displayWorkspaceLabel = normalizedWorkspaceLabel(
            resolvedWorkspaceLabel,
            plan: plan
        )
        let resolvedPlan = normalizedPlanLabel(
            plan,
            workspaceLabel: displayWorkspaceLabel
        )
        let snapshotKey = buildAccountPrimaryKey(
            email: email,
            workspaceId: workspaceID,
            workspaceLabel: resolvedWorkspaceLabel
        )

        return AccountSnapshot(
            accountId: snapshotKey,
            label: label,
            email: email,
            workspaceId: workspaceID,
            workspaceLabel: resolvedWorkspaceLabel,
            plan: resolvedPlan,
            source: source,
            systemAuthProfileId: systemAuthProfileID,
            isCurrentSystemAccount: isCurrentSystemAccount,
            lastSyncedAt: now,
            weeklyWindow: windows.weeklyWindow,
            rollingWindow: windows.rollingWindow
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

        return self.resolveWorkspaceLabel(
            payload: payload,
            fallback: fallback
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

    private func trimmedWorkspaceAccountID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        return trimmed
    }

    private func configAccountID(for account: AccountSnapshot, in config: PulseConfig) -> String? {
        let accountIdentity = canonicalAccountIdentity(for: account)
        return config.accounts.first(where: {
            buildAccountPrimaryKey(
                email: $0.email,
                workspaceId: $0.accountHeader,
                workspaceLabel: $0.workspaceLabel
            ) == accountIdentity
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

    private func mergeSnapshots(
        existing: CachePayload,
        incoming: [AccountSnapshot]
    ) -> CachePayload {
        var existingByIdentity: [String: AccountSnapshot] = [:]

        for account in existing.accounts {
            if self.shouldDiscardSupersededSystemSnapshot(
                account,
                incoming: incoming
            ) {
                continue
            }

            let prior = existingByIdentity[account.accountId]
            existingByIdentity[account.accountId] = self.preferredStoredSnapshot(prior, candidate: account)
        }

        var activeIdentity: String?

        for snapshot in incoming {
            existingByIdentity[snapshot.accountId] = AccountSnapshot(
                accountId: snapshot.accountId,
                label: snapshot.label,
                email: snapshot.email,
                workspaceId: snapshot.workspaceId,
                workspaceLabel: snapshot.workspaceLabel,
                plan: snapshot.plan,
                source: snapshot.source,
                systemAuthProfileId: snapshot.systemAuthProfileId,
                isCurrentSystemAccount: snapshot.isCurrentSystemAccount,
                lastSyncedAt: snapshot.lastSyncedAt,
                weeklyWindow: snapshot.weeklyWindow,
                rollingWindow: snapshot.rollingWindow
            )

            if snapshot.isCurrentSystemAccount == true {
                activeIdentity = snapshot.accountId
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
                    workspaceId: account.workspaceId,
                    workspaceLabel: account.workspaceLabel,
                    plan: account.plan,
                    source: account.source,
                    systemAuthProfileId: account.systemAuthProfileId,
                    isCurrentSystemAccount: isActive,
                    lastSyncedAt: account.lastSyncedAt,
                    weeklyWindow: account.weeklyWindow,
                    rollingWindow: account.rollingWindow
                )
            }
        } else {
            mergedAccounts = mergedAccounts.map { account in
                AccountSnapshot(
                    accountId: account.accountId,
                    label: account.label,
                    email: account.email,
                    workspaceId: account.workspaceId,
                    workspaceLabel: account.workspaceLabel,
                    plan: account.plan,
                    source: account.source,
                    systemAuthProfileId: account.systemAuthProfileId,
                    isCurrentSystemAccount: false,
                    lastSyncedAt: account.lastSyncedAt,
                    weeklyWindow: account.weeklyWindow,
                    rollingWindow: account.rollingWindow
                )
            }
        }

        mergedAccounts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        return CachePayload(
            meta: CacheMeta(
                source: "native-swift-cache"
            ),
            accounts: mergedAccounts
        )
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

        return AccountSnapshot(
            accountId: newest.accountId,
            label: newest.label,
            email: newest.email,
            workspaceId: newest.workspaceId,
            workspaceLabel: newest.workspaceLabel,
            plan: newest.plan,
            source: newest.source,
            systemAuthProfileId: newest.systemAuthProfileId,
            isCurrentSystemAccount: newest.isCurrentSystemAccount,
            lastSyncedAt: newest.lastSyncedAt,
            weeklyWindow: newest.weeklyWindow,
            rollingWindow: newest.rollingWindow
        )
    }

    private func shouldDiscardSupersededSystemSnapshot(
        _ existing: AccountSnapshot,
        incoming: [AccountSnapshot]
    ) -> Bool {
        guard existing.source == "live system auth",
              let existingProfileID = normalizedSystemAuthProfileID(existing.systemAuthProfileId)
        else {
            return false
        }

        let incomingForProfile = incoming.filter {
            $0.source == "live system auth"
                && normalizedSystemAuthProfileID($0.systemAuthProfileId) == existingProfileID
        }

        guard !incomingForProfile.isEmpty else {
            return false
        }

        let existingWorkspaceSlot = self.systemWorkspaceSlot(for: existing)
        guard existingWorkspaceSlot != nil else {
            return false
        }

        return incomingForProfile.contains { candidate in
            candidate.accountId != existing.accountId
                && self.systemWorkspaceSlot(for: candidate) == existingWorkspaceSlot
        }
    }

    private func systemWorkspaceSlot(for account: AccountSnapshot) -> String? {
        if let workspaceID = resolvedWorkspaceIdentity(
            accountId: account.accountId,
            workspaceId: account.workspaceId
        ) {
            return workspaceID.lowercased()
        }

        return nil
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

    private func scheduleAuthRefreshRetryIfNeeded() {
        guard !self.hasPendingAuthRetry else {
            return
        }

        self.hasPendingAuthRetry = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            self.hasPendingAuthRetry = false
            await self.syncNow()
        }
    }

    private func startAuthFileMonitor() {
        let authDirectoryURL = CodexMuxPaths.codexAuth.deletingLastPathComponent()
        let directoryPath = authDirectoryURL.path(percentEncoded: false)
        let fileDescriptor = open(directoryPath, O_EVTONLY)

        guard fileDescriptor >= 0 else {
            return
        }

        self.authMonitorFileDescriptor = fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            let currentSignature = self.currentAuthFileSignature()
            guard currentSignature != self.lastObservedAuthSignature else {
                return
            }

            self.lastObservedAuthSignature = currentSignature
            Task { @MainActor in
                await self.syncNow()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self else {
                return
            }

            if self.authMonitorFileDescriptor >= 0 {
                close(self.authMonitorFileDescriptor)
                self.authMonitorFileDescriptor = -1
            }
        }

        self.authMonitorSource = source
        source.resume()
    }

    private func currentAuthFileSignature() -> AuthFileSignature? {
        let authPath = CodexMuxPaths.codexAuth.path(percentEncoded: false)

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: authPath) else {
            return nil
        }

        let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        return AuthFileSignature(
            modificationDate: modificationDate,
            size: size
        )
    }
}

private struct SystemSnapshotRefresh {
    let snapshots: [AccountSnapshot]
}

private struct AuthFileSignature: Equatable {
    let modificationDate: Date
    let size: Int64
}
