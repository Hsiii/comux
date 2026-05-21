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

        return payload
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

    private func storageKey(for account: AccountSnapshot) -> String {
        let normalizedEmail = account.email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalizedEmail.isEmpty ? account.accountId : normalizedEmail
    }

    func displayName(for account: AccountSnapshot) -> String {
        let nickname = self.nicknames[self.storageKey(for: account)]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return nickname.isEmpty ? account.label : nickname
    }

    func nickname(for account: AccountSnapshot) -> String {
        self.nicknames[self.storageKey(for: account)] ?? ""
    }

    func saveNicknames(_ values: [String: String], for accounts: [AccountSnapshot]) {
        var nextNicknames = self.loadNicknames()

        for account in accounts {
            let key = self.storageKey(for: account)
            let trimmed = values[account.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if trimmed.isEmpty {
                nextNicknames.removeValue(forKey: key)
            } else {
                nextNicknames[key] = trimmed
            }
        }

        self.persistNicknames(nextNicknames)
    }

    func removeNickname(for account: AccountSnapshot) {
        let key = self.storageKey(for: account)
        var nextNicknames = self.loadNicknames()
        nextNicknames.removeValue(forKey: key)
        self.persistNicknames(nextNicknames)
    }
}
