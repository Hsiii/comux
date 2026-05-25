import Foundation
import SwiftUI

final class CacheStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func load() -> CachePayload {
        self.ensureSeeded()

        guard let data = try? Data(contentsOf: CodexMuxPaths.cache),
              let payload = try? self.decoder.decode(CachePayload.self, from: data)
        else {
            return self.emptyPayload()
        }

        let migratedPayload = self.migrateLegacyAccounts(in: payload)
        let migratedData = try? self.encoder.encode(migratedPayload)
        let originalData = try? self.encoder.encode(payload)

        if migratedData != originalData {
            try? self.save(migratedPayload)
        }

        return migratedPayload
    }

    func save(_ payload: CachePayload) throws {
        try FileManager.default.createDirectory(
            at: CodexMuxPaths.root,
            withIntermediateDirectories: true
        )
        try self.encoder.encode(payload).write(to: CodexMuxPaths.cache)
    }

    func removeAccount(withID accountID: String) throws -> CachePayload {
        let existing = self.load()
        let filteredAccounts = existing.accounts.filter { $0.accountId != accountID }
        let payload = CachePayload(
            meta: CacheMeta(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                cachePath: CodexMuxPaths.cache.path(percentEncoded: false),
                source: existing.meta.source
            ),
            accounts: filteredAccounts
        )
        try self.save(payload)
        return payload
    }

    private func ensureSeeded() {
        if FileManager.default.fileExists(atPath: CodexMuxPaths.cache.path(percentEncoded: false)) {
            return
        }

        try? FileManager.default.createDirectory(
            at: CodexMuxPaths.root,
            withIntermediateDirectories: true
        )

        if let data = try? self.encoder.encode(self.emptyPayload()) {
            try? data.write(to: CodexMuxPaths.cache)
        }
    }

    private func emptyPayload() -> CachePayload {
        CachePayload(
            meta: CacheMeta(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                cachePath: CodexMuxPaths.cache.path(percentEncoded: false),
                source: "native-swift-cache"
            ),
            accounts: []
        )
    }

    private func migrateLegacyAccounts(in payload: CachePayload) -> CachePayload {
        var accountsByIdentity: [String: AccountSnapshot] = [:]

        for account in payload.accounts {
            let normalizedAccount = self.normalizedAccountIdentity(
                for: account,
                within: payload.accounts
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
                generatedAt: payload.meta.generatedAt,
                cachePath: payload.meta.cachePath,
                source: payload.meta.source
            ),
            accounts: migratedAccounts
        )
    }

    private func normalizedAccountIdentity(
        for account: AccountSnapshot,
        within accounts: [AccountSnapshot]
    ) -> AccountSnapshot {
        let normalizedAccountID: String

        if self.shouldRewriteLegacySystemIdentity(for: account, within: accounts) {
            normalizedAccountID = buildSnapshotKey(
                accountId: account.accountId,
                email: account.email,
                isCurrentSystemAccount: true
            )
        } else {
            normalizedAccountID = account.accountId
        }

        return AccountSnapshot(
            accountId: normalizedAccountID,
            label: account.label,
            email: account.email,
            workspaceLabel: account.workspaceLabel,
            plan: account.plan,
            color: account.color,
            source: account.source,
            isCurrentSystemAccount: account.isCurrentSystemAccount,
            lastSyncedAt: account.lastSyncedAt,
            weeklyWindow: account.weeklyWindow,
            rollingWindow: account.rollingWindow,
            pace: account.pace,
            history: account.history
        )
    }

    private func shouldRewriteLegacySystemIdentity(
        for account: AccountSnapshot,
        within accounts: [AccountSnapshot]
    ) -> Bool {
        guard account.source == "live system auth",
              account.accountId.hasPrefix("system::") == false,
              account.isCurrentSystemAccount != true
        else {
            return false
        }

        let normalizedEmail = account.email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedEmail.isEmpty else {
            return false
        }

        return accounts.contains { candidate in
            guard candidate.accountId != account.accountId else {
                return false
            }

            let candidateEmail = candidate.email
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            guard candidateEmail == normalizedEmail else {
                return false
            }

            let candidateIsStableSystem = candidate.accountId == "system::\(normalizedEmail)"
            let candidateLooksCanonical = candidate.accountId.hasPrefix("user-")
                || candidate.accountId.hasPrefix("org-")
                || candidate.accountId.hasPrefix("workspace-")

            return candidateIsStableSystem || candidateLooksCanonical
        }
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
        let oldest = candidateDate >= currentDate ? current : candidate
        let mergedHistory = Array((oldest.history + newest.history).suffix(12))

        return AccountSnapshot(
            accountId: newest.accountId,
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
            history: mergedHistory
        )
    }
}

final class AccountConfigStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func load() -> PulseConfig {
        guard let data = try? Data(contentsOf: CodexMuxPaths.config),
              let config = try? self.decoder.decode(PulseConfig.self, from: data) else {
            return .default
        }

        return config
    }

    func save(_ config: PulseConfig) throws {
        try FileManager.default.createDirectory(
            at: CodexMuxPaths.root,
            withIntermediateDirectories: true
        )
        try self.encoder.encode(config).write(to: CodexMuxPaths.config, options: [.atomic])
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

    private let defaultsKey = "codexmux.nicknames.v1"
    private let legacyDefaultsKey = "codexboard.nicknames.v1"
    private let decoder = JSONDecoder()

    init() {
        let nicknames = Self.loadNicknames(for: self.defaultsKey)

        if nicknames.isEmpty {
            let legacyNicknames = Self.loadNicknames(for: self.legacyDefaultsKey)
            self.nicknames = legacyNicknames

            if !legacyNicknames.isEmpty {
                UserDefaults.standard.set(legacyNicknames, forKey: self.defaultsKey)
            }
        } else {
            self.nicknames = nicknames
        }

        let migratedNicknames = self.migrateLegacyNicknames(self.nicknames)

        if migratedNicknames != self.nicknames {
            self.persistNicknames(migratedNicknames)
        }
    }

    private static func loadNicknames(for defaultsKey: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    private func loadNicknames() -> [String: String] {
        Self.loadNicknames(for: self.defaultsKey)
    }

    private func persistNicknames(_ nicknames: [String: String]) {
        self.nicknames = nicknames
        UserDefaults.standard.set(nicknames, forKey: self.defaultsKey)
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
        guard let data = try? Data(contentsOf: CodexMuxPaths.cache),
              let payload = try? self.decoder.decode(CachePayload.self, from: data)
        else {
            return []
        }

        return payload.accounts.map { account in
            let stableAccountID = buildSnapshotKey(
                accountId: account.accountId,
                email: account.email,
                isCurrentSystemAccount: account.source == "live system auth" || account.isCurrentSystemAccount == true
            )

            return AccountSnapshot(
                accountId: stableAccountID,
                label: account.label,
                email: account.email,
                workspaceLabel: account.workspaceLabel,
                plan: account.plan,
                color: account.color,
                source: account.source,
                isCurrentSystemAccount: account.isCurrentSystemAccount,
                lastSyncedAt: account.lastSyncedAt,
                weeklyWindow: account.weeklyWindow,
                rollingWindow: account.rollingWindow,
                pace: account.pace,
                history: account.history
            )
        }
    }
}
