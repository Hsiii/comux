import Foundation
import SwiftUI

final class CacheStore {
    private let durableStore = DurableStoreCoordinator.shared
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func load() -> CachePayload {
        let payload = self.durableStore.loadCache(
            fallback: self.emptyPayload()
        )

        let migratedPayload = self.migrateLegacyAccounts(in: payload)
        let migratedData = try? self.encoder.encode(migratedPayload)
        let originalData = try? self.encoder.encode(payload)

        if migratedData != originalData {
            try? self.save(migratedPayload)
        }

        return migratedPayload
    }

    func save(_ payload: CachePayload) throws {
        try self.durableStore.saveCache(
            payload,
            event: "cache.save"
        )
    }

    func removeAccount(withID accountID: String) throws -> CachePayload {
        let existing = self.load()
        let filteredAccounts = existing.accounts.filter { $0.accountId != accountID }
        let payload = CachePayload(
            meta: CacheMeta(
                source: existing.meta.source
            ),
            accounts: filteredAccounts
        )
        try self.save(payload)
        return payload
    }

    private func emptyPayload() -> CachePayload {
        CachePayload(
            meta: CacheMeta(
                source: "native-swift-cache"
            ),
            accounts: []
        )
    }

    private func migrateLegacyAccounts(in payload: CachePayload) -> CachePayload {
        var accountsByIdentity: [String: AccountSnapshot] = [:]

        for account in payload.accounts {
            let normalizedAccount = self.normalizedAccountIdentity(
                for: account
            )
            let prior = accountsByIdentity[normalizedAccount.accountId]
            accountsByIdentity[normalizedAccount.accountId] = self.preferredAccountSnapshot(
                current: prior,
                candidate: normalizedAccount
            )
        }

        let migratedAccounts = accountsByIdentity.values.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }

        return CachePayload(
            meta: CacheMeta(
                source: payload.meta.source
            ),
            accounts: migratedAccounts
        )
    }

    private func normalizedAccountIdentity(
        for account: AccountSnapshot
    ) -> AccountSnapshot {
        let workspaceID = resolvedWorkspaceIdentity(
            accountId: account.accountId,
            workspaceId: account.workspaceId
        )
        let normalizedAccountID = buildAccountPrimaryKey(
            email: account.email,
            workspaceId: workspaceID,
            workspaceLabel: account.workspaceLabel
        )

        return AccountSnapshot(
            accountId: normalizedAccountID,
            label: account.label,
            email: account.email,
            workspaceId: workspaceID,
            workspaceLabel: account.workspaceLabel,
            plan: account.plan,
            source: account.source,
            systemAuthProfileId: account.systemAuthProfileId,
            isCurrentSystemAccount: account.isCurrentSystemAccount,
            lastSyncedAt: account.lastSyncedAt,
            weeklyWindow: account.weeklyWindow,
            rollingWindow: account.rollingWindow
        )
    }

    private func preferredAccountSnapshot(
        current: AccountSnapshot?,
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
}

final class AccountConfigStore {
    private let durableStore = DurableStoreCoordinator.shared

    func load() -> PulseConfig {
        self.durableStore.loadConfig(
            fallback: .default
        )
    }

    func save(_ config: PulseConfig) throws {
        try self.durableStore.saveConfig(
            config,
            event: "config.save"
        )
    }

    func removeAccount(withID accountID: String) throws {
        let existing = self.load()
        let filteredAccounts = existing.accounts.filter { $0.id != accountID }
        try self.save(
            PulseConfig(
                pollIntervalSeconds: existing.pollIntervalSeconds,
                accounts: filteredAccounts
            )
        )
    }
}

final class NicknameStore: ObservableObject {
    @Published private(set) var nicknames: [String: String]

    private let durableStore = DurableStoreCoordinator.shared
    private let defaultsKey = "codexmux.nicknames.v1"
    private let legacyDefaultsKey = "codexboard.nicknames.v1"

    init() {
        let fileNicknames = self.durableStore.loadNicknames()
        let defaultsNicknames = Self.loadNicknames(for: self.defaultsKey)
        let legacyNicknames = Self.loadNicknames(for: self.legacyDefaultsKey)
        let seedNicknames = !fileNicknames.isEmpty
            ? fileNicknames
            : (!defaultsNicknames.isEmpty ? defaultsNicknames : legacyNicknames)

        self.nicknames = seedNicknames

        let migratedNicknames = self.migrateLegacyNicknames(self.nicknames)

        if migratedNicknames != self.nicknames {
            self.persistNicknames(migratedNicknames)
        } else if fileNicknames != seedNicknames {
            self.persistNicknames(seedNicknames)
        }
    }

    private static func loadNicknames(for defaultsKey: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    private func loadNicknames() -> [String: String] {
        self.durableStore.loadNicknames()
    }

    private func persistNicknames(_ nicknames: [String: String]) {
        self.nicknames = nicknames
        try? self.durableStore.saveNicknames(
            nicknames,
            event: "nicknames.save"
        )
    }

    private func normalizedEmail(for account: AccountSnapshot) -> String {
        let normalizedEmail = account.email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalizedEmail
    }

    private func preferredStorageKey(for account: AccountSnapshot) -> String {
        let canonicalIdentity = canonicalAccountIdentity(for: account)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !canonicalIdentity.isEmpty, !canonicalIdentity.hasPrefix("::") {
            return canonicalIdentity
        }

        let normalizedEmail = self.normalizedEmail(for: account)
        return normalizedEmail.isEmpty ? account.accountId : normalizedEmail
    }

    private func legacyCanonicalIdentity(for account: AccountSnapshot) -> String {
        let normalizedEmail = self.normalizedEmail(for: account)
        let normalizedPlan = account.plan
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedEmail.isEmpty, !normalizedPlan.isEmpty else {
            return ""
        }

        return "\(normalizedEmail)::\(normalizedPlan)"
    }

    private func legacyStorageKeys(for account: AccountSnapshot) -> [String] {
        let baseAccountId = legacyBaseAccountID(from: account.accountId)

        return [
            self.preferredStorageKey(for: account),
            self.legacyCanonicalIdentity(for: account),
            self.normalizedEmail(for: account),
            account.accountId,
            baseAccountId
        ]
        .filter { !$0.isEmpty }
        .reduce(into: [String]()) { keys, key in
            if !keys.contains(key) {
                keys.append(key)
            }
        }
    }

    private func resolvedNickname(for account: AccountSnapshot) -> String {
        for key in self.legacyStorageKeys(for: account) {
            let nickname = self.nicknames[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !nickname.isEmpty {
                return nickname
            }
        }

        return ""
    }

    func displayName(for account: AccountSnapshot) -> String {
        let nickname = self.resolvedNickname(for: account)
        return nickname.isEmpty ? account.label : nickname
    }

    func nickname(for account: AccountSnapshot) -> String {
        self.resolvedNickname(for: account)
    }

    func saveNicknames(_ values: [String: String], for accounts: [AccountSnapshot]) {
        var nextNicknames = self.loadNicknames()

        for account in accounts {
            let keys = self.legacyStorageKeys(for: account)
            let preferredKey = self.preferredStorageKey(for: account)
            let trimmed = values[account.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            for key in keys {
                nextNicknames.removeValue(forKey: key)
            }

            if !trimmed.isEmpty {
                nextNicknames[preferredKey] = trimmed
            }
        }

        self.persistNicknames(nextNicknames)
    }

    func removeNickname(for account: AccountSnapshot) {
        var nextNicknames = self.loadNicknames()

        for key in self.legacyStorageKeys(for: account) {
            nextNicknames.removeValue(forKey: key)
        }

        self.persistNicknames(nextNicknames)
    }

    private func migrateLegacyNicknames(_ nicknames: [String: String]) -> [String: String] {
        guard !nicknames.isEmpty else {
            return nicknames
        }

        let cacheAccounts = self.loadAccountsForNicknameMigration()
        guard !cacheAccounts.isEmpty else {
            return nicknames
        }

        var migratedNicknames = nicknames

        for account in cacheAccounts {
            let preferredKey = self.preferredStorageKey(for: account)
            let legacyKeys = self.legacyStorageKeys(for: account)

            guard !preferredKey.isEmpty else {
                continue
            }

            let legacyNickname = legacyKeys.lazy
                .compactMap { key -> String? in
                    let trimmed = migratedNicknames[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : trimmed
                }
                .first

            guard let legacyNickname else {
                continue
            }

            for key in legacyKeys where key != preferredKey {
                migratedNicknames.removeValue(forKey: key)
            }

            migratedNicknames[preferredKey] = legacyNickname
        }

        return migratedNicknames
    }

    private func loadAccountsForNicknameMigration() -> [AccountSnapshot] {
        let payload = self.durableStore.loadCache(
            fallback: CachePayload(
                meta: CacheMeta(
                    source: "native-swift-cache"
                ),
                accounts: []
            )
        )

        return payload.accounts.map { account in
            let workspaceID = resolvedWorkspaceIdentity(
                accountId: account.accountId,
                workspaceId: account.workspaceId
            )
            let stableAccountID = buildAccountPrimaryKey(
                email: account.email,
                workspaceId: workspaceID,
                workspaceLabel: account.workspaceLabel
            )

            return AccountSnapshot(
                accountId: stableAccountID,
                label: account.label,
                email: account.email,
                workspaceId: workspaceID,
                workspaceLabel: account.workspaceLabel,
                plan: account.plan,
                source: account.source,
                systemAuthProfileId: account.systemAuthProfileId,
                isCurrentSystemAccount: account.isCurrentSystemAccount,
                lastSyncedAt: account.lastSyncedAt,
                weeklyWindow: account.weeklyWindow,
                rollingWindow: account.rollingWindow
            )
        }
    }
}
