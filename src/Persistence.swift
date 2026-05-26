import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct NicknamePayload: Codable {
    let schemaVersion: Int
    let updatedAt: String
    let nicknames: [String: String]

    static let empty = NicknamePayload(
        schemaVersion: 1,
        updatedAt: ISO8601DateFormatter().string(from: .distantPast),
        nicknames: [:]
    )
}

struct StorageLogEntry: Codable {
    let id: String
    let event: String
    let status: String
    let committedAt: String
    let touchedPaths: [String]
}

final class DurableStoreCoordinator: @unchecked Sendable {
    static let shared = DurableStoreCoordinator()

    private let queue = DispatchQueue(label: "com.codexmux.storage", qos: .userInitiated)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let defaultsKey = "codexmux.nicknames.v1"
    private let legacyDefaultsKey = "codexboard.nicknames.v1"
    private var database: OpaquePointer?

    private init() {}

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func loadCache(fallback: @autoclosure () -> CachePayload) -> CachePayload {
        self.queue.sync {
            do {
                try self.prepareDatabaseIfNeededLocked()

                let source = try self.metaValueLocked(for: "cache.source") ?? fallback().meta.source
                let accounts = try self.fetchAccountSnapshotsLocked()
                return CachePayload(
                    meta: CacheMeta(source: source),
                    accounts: accounts
                )
            } catch {
                return fallback()
            }
        }
    }

    func saveCache(
        _ payload: CachePayload,
        event: String
    ) throws {
        try self.queue.sync {
            try self.prepareDatabaseIfNeededLocked()
            try self.inTransactionLocked(event: event, touchedPaths: ["meta", "account_snapshots"]) {
                try self.replaceMetaValueLocked(payload.meta.source, for: "cache.source")
                try self.replaceAccountSnapshotsLocked(payload.accounts)
            }
        }
    }

    func loadConfig(fallback: @autoclosure () -> PulseConfig) -> PulseConfig {
        self.queue.sync {
            do {
                try self.prepareDatabaseIfNeededLocked()
                let pollIntervalText = try self.metaValueLocked(for: "config.poll_interval_seconds")
                let pollInterval = pollIntervalText.flatMap(Double.init) ?? fallback().pollIntervalSeconds
                let accounts = try self.fetchAccountConfigsLocked()

                return PulseConfig(
                    pollIntervalSeconds: pollInterval,
                    accounts: accounts
                )
            } catch {
                return fallback()
            }
        }
    }

    func saveConfig(
        _ config: PulseConfig,
        event: String
    ) throws {
        try self.queue.sync {
            try self.prepareDatabaseIfNeededLocked()
            try self.inTransactionLocked(event: event, touchedPaths: ["meta", "account_configs"]) {
                try self.replaceMetaValueLocked(String(config.pollIntervalSeconds), for: "config.poll_interval_seconds")
                try self.replaceAccountConfigsLocked(config.accounts)
            }
        }
    }

    func saveCacheAndConfig(
        cache: CachePayload,
        config: PulseConfig,
        event: String
    ) throws {
        try self.queue.sync {
            try self.prepareDatabaseIfNeededLocked()
            try self.inTransactionLocked(
                event: event,
                touchedPaths: ["meta", "account_snapshots", "account_configs"]
            ) {
                try self.replaceMetaValueLocked(cache.meta.source, for: "cache.source")
                try self.replaceMetaValueLocked(String(config.pollIntervalSeconds), for: "config.poll_interval_seconds")
                try self.replaceAccountSnapshotsLocked(cache.accounts)
                try self.replaceAccountConfigsLocked(config.accounts)
            }
        }
    }

    func loadNicknames() -> [String: String] {
        self.queue.sync {
            do {
                try self.prepareDatabaseIfNeededLocked()
                return try self.fetchNicknamesLocked()
            } catch {
                return [:]
            }
        }
    }

    func saveNicknames(
        _ nicknames: [String: String],
        event: String
    ) throws {
        try self.queue.sync {
            try self.prepareDatabaseIfNeededLocked()
            try self.inTransactionLocked(event: event, touchedPaths: ["nicknames"]) {
                try self.replaceNicknamesLocked(nicknames)
            }
        }
    }

    private func prepareDatabaseIfNeededLocked() throws {
        if self.database != nil {
            return
        }

        try FileManager.default.createDirectory(
            at: CodexMuxPaths.root,
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(
            CodexMuxPaths.database.path(percentEncoded: false),
            &database,
            flags,
            nil
        ) == SQLITE_OK, let database else {
            let message = database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Could not open SQLite database."
            sqlite3_close(database)
            throw DatabaseError.openFailed(message)
        }

        self.database = database

        do {
            try self.executeLocked("PRAGMA journal_mode = WAL;")
            try self.executeLocked("PRAGMA synchronous = FULL;")
            try self.executeLocked("PRAGMA foreign_keys = ON;")
            try self.executeLocked("PRAGMA busy_timeout = 5000;")
            try self.createSchemaLocked()
            try self.migrateAccountSnapshotSchemaIfNeededLocked()
            try self.migrateLegacyStorageIfNeededLocked()
        } catch {
            sqlite3_close(database)
            self.database = nil
            throw error
        }
    }

    private func createSchemaLocked() throws {
        try self.executeLocked(
            """
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )
        try self.executeLocked(
            """
            CREATE TABLE IF NOT EXISTS account_snapshots (
                account_id TEXT PRIMARY KEY,
                label TEXT NOT NULL,
                email TEXT NOT NULL,
                workspace_id TEXT,
                workspace_label TEXT NOT NULL,
                plan TEXT NOT NULL,
                source TEXT NOT NULL,
                system_auth_profile_id TEXT,
                is_current_system_account INTEGER,
                last_synced_at TEXT NOT NULL,
                weekly_available INTEGER NOT NULL,
                weekly_label TEXT NOT NULL,
                weekly_used_minutes INTEGER NOT NULL,
                weekly_limit_minutes INTEGER NOT NULL,
                weekly_used_percentage REAL NOT NULL,
                weekly_resets_at TEXT NOT NULL,
                rolling_available INTEGER NOT NULL,
                rolling_label TEXT NOT NULL,
                rolling_used_minutes INTEGER NOT NULL,
                rolling_limit_minutes INTEGER NOT NULL,
                rolling_used_percentage REAL NOT NULL,
                rolling_resets_at TEXT NOT NULL
            );
            """
        )
        try self.executeLocked(
            """
            CREATE TABLE IF NOT EXISTS account_configs (
                id TEXT PRIMARY KEY,
                label TEXT NOT NULL,
                email TEXT NOT NULL,
                workspace_label TEXT NOT NULL,
                plan TEXT NOT NULL,
                color TEXT NOT NULL,
                chatgpt_cookie TEXT NOT NULL,
                source TEXT,
                session_endpoint TEXT,
                usage_endpoint TEXT,
                account_header TEXT
            );
            """
        )
        try self.executeLocked(
            """
            CREATE TABLE IF NOT EXISTS nicknames (
                storage_key TEXT PRIMARY KEY,
                nickname TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            """
        )
        try self.executeLocked(
            """
            CREATE TABLE IF NOT EXISTS storage_log (
                id TEXT PRIMARY KEY,
                event TEXT NOT NULL,
                status TEXT NOT NULL,
                committed_at TEXT NOT NULL,
                touched_paths_json TEXT NOT NULL
            );
            """
        )
    }

    private func migrateLegacyStorageIfNeededLocked() throws {
        guard try self.metaValueLocked(for: "storage.engine") == nil else {
            return
        }

        let cache = self.loadLegacyCacheLocked()
        let config = self.loadLegacyConfigLocked()
        let nicknames = self.loadLegacyNicknamesLocked()
        let importedAnyData = !cache.accounts.isEmpty || !config.accounts.isEmpty || !nicknames.isEmpty

        try self.inTransactionLocked(
            event: importedAnyData ? "storage.migrate_legacy" : "storage.bootstrap",
            touchedPaths: ["meta", "account_snapshots", "account_configs", "nicknames"]
        ) {
            try self.replaceMetaValueLocked("sqlite", for: "storage.engine")
            try self.replaceMetaValueLocked(cache.meta.source, for: "cache.source")
            try self.replaceMetaValueLocked(String(config.pollIntervalSeconds), for: "config.poll_interval_seconds")
            try self.replaceAccountSnapshotsLocked(cache.accounts)
            try self.replaceAccountConfigsLocked(config.accounts)
            try self.replaceNicknamesLocked(nicknames)
        }
    }

    private func migrateAccountSnapshotSchemaIfNeededLocked() throws {
        guard try !self.columnExistsLocked(
            table: "account_snapshots",
            column: "system_auth_profile_id"
        ) else {
            return
        }

        try self.executeLocked(
            """
            ALTER TABLE account_snapshots
            ADD COLUMN system_auth_profile_id TEXT;
            """
        )
    }

    private func loadLegacyCacheLocked() -> CachePayload {
        guard let data = try? Data(contentsOf: CodexMuxPaths.cache),
              let payload = try? self.decoder.decode(CachePayload.self, from: data) else {
            return CachePayload(
                meta: CacheMeta(source: "native-swift-cache"),
                accounts: []
            )
        }

        return payload
    }

    private func loadLegacyConfigLocked() -> PulseConfig {
        guard let data = try? Data(contentsOf: CodexMuxPaths.config),
              let config = try? self.decoder.decode(PulseConfig.self, from: data) else {
            return .default
        }

        return config
    }

    private func loadLegacyNicknamesLocked() -> [String: String] {
        if let data = try? Data(contentsOf: CodexMuxPaths.nicknames),
           let payload = try? self.decoder.decode(NicknamePayload.self, from: data) {
            return payload.nicknames
        }

        let defaultsNicknames = UserDefaults.standard.dictionary(forKey: self.defaultsKey) as? [String: String] ?? [:]
        if !defaultsNicknames.isEmpty {
            return defaultsNicknames
        }

        return UserDefaults.standard.dictionary(forKey: self.legacyDefaultsKey) as? [String: String] ?? [:]
    }

    private func inTransactionLocked(
        event: String,
        touchedPaths: [String],
        body: () throws -> Void
    ) throws {
        try self.executeLocked("BEGIN IMMEDIATE TRANSACTION;")

        do {
            try body()
            try self.insertStorageLogLocked(
                StorageLogEntry(
                    id: UUID().uuidString,
                    event: event,
                    status: "committed",
                    committedAt: ISO8601DateFormatter().string(from: Date()),
                    touchedPaths: touchedPaths
                )
            )
            try self.executeLocked("COMMIT;")
        } catch {
            try? self.executeLocked("ROLLBACK;")
            throw error
        }
    }

    private func executeLocked(_ sql: String) throws {
        guard let database else {
            throw DatabaseError.notOpen
        }

        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.sqlite(message: String(cString: sqlite3_errmsg(database)))
        }
    }

    private func columnExistsLocked(
        table: String,
        column: String
    ) throws -> Bool {
        let statement = try self.prepareLocked("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if self.columnText(statement, index: 1) == column {
                return true
            }
        }

        return false
    }

    private func metaValueLocked(for key: String) throws -> String? {
        guard self.database != nil else {
            throw DatabaseError.notOpen
        }

        let statement = try self.prepareLocked("SELECT value FROM meta WHERE key = ?;")
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)

        if sqlite3_step(statement) == SQLITE_ROW {
            return self.columnText(statement, index: 0)
        }

        return nil
    }

    private func replaceMetaValueLocked(_ value: String, for key: String) throws {
        let statement = try self.prepareLocked(
            "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, value, -1, SQLITE_TRANSIENT)
        try self.stepDoneLocked(statement)
    }

    private func fetchAccountSnapshotsLocked() throws -> [AccountSnapshot] {
        let statement = try self.prepareLocked(
            """
            SELECT
                account_id,
                label,
                email,
                workspace_id,
                workspace_label,
                plan,
                source,
                system_auth_profile_id,
                is_current_system_account,
                last_synced_at,
                weekly_available,
                weekly_label,
                weekly_used_minutes,
                weekly_limit_minutes,
                weekly_used_percentage,
                weekly_resets_at,
                rolling_available,
                rolling_label,
                rolling_used_minutes,
                rolling_limit_minutes,
                rolling_used_percentage,
                rolling_resets_at
            FROM account_snapshots
            ORDER BY label COLLATE NOCASE ASC;
            """
        )
        defer { sqlite3_finalize(statement) }

        var snapshots: [AccountSnapshot] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let weekly = UsageWindow(
                available: sqlite3_column_int(statement, 10) != 0,
                label: self.columnText(statement, index: 11) ?? "",
                usedMinutes: Int(sqlite3_column_int(statement, 12)),
                limitMinutes: Int(sqlite3_column_int(statement, 13)),
                usedPercentage: sqlite3_column_double(statement, 14),
                resetsAt: self.columnText(statement, index: 15) ?? ""
            )
            let rolling = UsageWindow(
                available: sqlite3_column_int(statement, 16) != 0,
                label: self.columnText(statement, index: 17) ?? "",
                usedMinutes: Int(sqlite3_column_int(statement, 18)),
                limitMinutes: Int(sqlite3_column_int(statement, 19)),
                usedPercentage: sqlite3_column_double(statement, 20),
                resetsAt: self.columnText(statement, index: 21) ?? ""
            )

            snapshots.append(
                AccountSnapshot(
                    accountId: self.columnText(statement, index: 0) ?? "",
                    label: self.columnText(statement, index: 1) ?? "",
                    email: self.columnText(statement, index: 2) ?? "",
                    workspaceId: self.columnText(statement, index: 3),
                    workspaceLabel: self.columnText(statement, index: 4) ?? "",
                    plan: self.columnText(statement, index: 5) ?? "",
                    source: self.columnText(statement, index: 6) ?? "",
                    systemAuthProfileId: self.columnText(statement, index: 7),
                    isCurrentSystemAccount: sqlite3_column_type(statement, 8) == SQLITE_NULL
                        ? nil
                        : sqlite3_column_int(statement, 8) != 0,
                    lastSyncedAt: self.columnText(statement, index: 9) ?? "",
                    weeklyWindow: weekly,
                    rollingWindow: rolling
                )
            )
        }

        return snapshots
    }

    private func replaceAccountSnapshotsLocked(_ snapshots: [AccountSnapshot]) throws {
        try self.executeLocked("DELETE FROM account_snapshots;")

        let statement = try self.prepareLocked(
            """
            INSERT INTO account_snapshots (
                account_id,
                label,
                email,
                workspace_id,
                workspace_label,
                plan,
                source,
                system_auth_profile_id,
                is_current_system_account,
                last_synced_at,
                weekly_available,
                weekly_label,
                weekly_used_minutes,
                weekly_limit_minutes,
                weekly_used_percentage,
                weekly_resets_at,
                rolling_available,
                rolling_label,
                rolling_used_minutes,
                rolling_limit_minutes,
                rolling_used_percentage,
                rolling_resets_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }

        for snapshot in snapshots {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            self.bindText(snapshot.accountId, to: statement, index: 1)
            self.bindText(snapshot.label, to: statement, index: 2)
            self.bindText(snapshot.email, to: statement, index: 3)
            self.bindOptionalText(snapshot.workspaceId, to: statement, index: 4)
            self.bindText(snapshot.workspaceLabel, to: statement, index: 5)
            self.bindText(snapshot.plan, to: statement, index: 6)
            self.bindText(snapshot.source, to: statement, index: 7)
            self.bindOptionalText(snapshot.systemAuthProfileId, to: statement, index: 8)
            self.bindOptionalBool(snapshot.isCurrentSystemAccount, to: statement, index: 9)
            self.bindText(snapshot.lastSyncedAt, to: statement, index: 10)
            sqlite3_bind_int(statement, 11, snapshot.weeklyWindow.available ? 1 : 0)
            self.bindText(snapshot.weeklyWindow.label, to: statement, index: 12)
            sqlite3_bind_int(statement, 13, Int32(snapshot.weeklyWindow.usedMinutes))
            sqlite3_bind_int(statement, 14, Int32(snapshot.weeklyWindow.limitMinutes))
            sqlite3_bind_double(statement, 15, snapshot.weeklyWindow.usedPercentage)
            self.bindText(snapshot.weeklyWindow.resetsAt, to: statement, index: 16)
            sqlite3_bind_int(statement, 17, snapshot.rollingWindow.available ? 1 : 0)
            self.bindText(snapshot.rollingWindow.label, to: statement, index: 18)
            sqlite3_bind_int(statement, 19, Int32(snapshot.rollingWindow.usedMinutes))
            sqlite3_bind_int(statement, 20, Int32(snapshot.rollingWindow.limitMinutes))
            sqlite3_bind_double(statement, 21, snapshot.rollingWindow.usedPercentage)
            self.bindText(snapshot.rollingWindow.resetsAt, to: statement, index: 22)

            try self.stepDoneLocked(statement)
        }
    }

    private func fetchAccountConfigsLocked() throws -> [AccountConfig] {
        let statement = try self.prepareLocked(
            """
            SELECT
                id,
                label,
                email,
                workspace_label,
                plan,
                color,
                chatgpt_cookie,
                source,
                session_endpoint,
                usage_endpoint,
                account_header
            FROM account_configs
            ORDER BY label COLLATE NOCASE ASC;
            """
        )
        defer { sqlite3_finalize(statement) }

        var configs: [AccountConfig] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            configs.append(
                AccountConfig(
                    id: self.columnText(statement, index: 0) ?? "",
                    label: self.columnText(statement, index: 1) ?? "",
                    email: self.columnText(statement, index: 2) ?? "",
                    workspaceLabel: self.columnText(statement, index: 3) ?? "",
                    plan: self.columnText(statement, index: 4) ?? "",
                    color: self.columnText(statement, index: 5) ?? "",
                    chatGPTCookie: self.columnText(statement, index: 6) ?? "",
                    source: self.columnText(statement, index: 7),
                    sessionEndpoint: self.columnText(statement, index: 8),
                    usageEndpoint: self.columnText(statement, index: 9),
                    accountHeader: self.columnText(statement, index: 10)
                )
            )
        }

        return configs
    }

    private func replaceAccountConfigsLocked(_ configs: [AccountConfig]) throws {
        try self.executeLocked("DELETE FROM account_configs;")

        let statement = try self.prepareLocked(
            """
            INSERT INTO account_configs (
                id,
                label,
                email,
                workspace_label,
                plan,
                color,
                chatgpt_cookie,
                source,
                session_endpoint,
                usage_endpoint,
                account_header
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }

        for config in configs {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            self.bindText(config.id, to: statement, index: 1)
            self.bindText(config.label, to: statement, index: 2)
            self.bindText(config.email, to: statement, index: 3)
            self.bindText(config.workspaceLabel, to: statement, index: 4)
            self.bindText(config.plan, to: statement, index: 5)
            self.bindText(config.color, to: statement, index: 6)
            self.bindText(config.chatGPTCookie, to: statement, index: 7)
            self.bindOptionalText(config.source, to: statement, index: 8)
            self.bindOptionalText(config.sessionEndpoint, to: statement, index: 9)
            self.bindOptionalText(config.usageEndpoint, to: statement, index: 10)
            self.bindOptionalText(config.accountHeader, to: statement, index: 11)

            try self.stepDoneLocked(statement)
        }
    }

    private func fetchNicknamesLocked() throws -> [String: String] {
        let statement = try self.prepareLocked(
            "SELECT storage_key, nickname FROM nicknames ORDER BY storage_key COLLATE NOCASE ASC;"
        )
        defer { sqlite3_finalize(statement) }

        var nicknames: [String: String] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            if let key = self.columnText(statement, index: 0),
               let nickname = self.columnText(statement, index: 1) {
                nicknames[key] = nickname
            }
        }

        return nicknames
    }

    private func replaceNicknamesLocked(_ nicknames: [String: String]) throws {
        try self.executeLocked("DELETE FROM nicknames;")

        let statement = try self.prepareLocked(
            "INSERT INTO nicknames (storage_key, nickname, updated_at) VALUES (?, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }

        let timestamp = ISO8601DateFormatter().string(from: Date())

        for (key, nickname) in nicknames {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            self.bindText(key, to: statement, index: 1)
            self.bindText(nickname, to: statement, index: 2)
            self.bindText(timestamp, to: statement, index: 3)
            try self.stepDoneLocked(statement)
        }
    }

    private func insertStorageLogLocked(_ entry: StorageLogEntry) throws {
        let statement = try self.prepareLocked(
            "INSERT INTO storage_log (id, event, status, committed_at, touched_paths_json) VALUES (?, ?, ?, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }

        let touchedPathsData = try self.encoder.encode(entry.touchedPaths)
        let touchedPathsJSON = String(decoding: touchedPathsData, as: UTF8.self)

        self.bindText(entry.id, to: statement, index: 1)
        self.bindText(entry.event, to: statement, index: 2)
        self.bindText(entry.status, to: statement, index: 3)
        self.bindText(entry.committedAt, to: statement, index: 4)
        self.bindText(touchedPathsJSON, to: statement, index: 5)
        try self.stepDoneLocked(statement)
    }

    private func prepareLocked(_ sql: String) throws -> OpaquePointer? {
        guard let database else {
            throw DatabaseError.notOpen
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.sqlite(message: String(cString: sqlite3_errmsg(database)))
        }

        return statement
    }

    private func stepDoneLocked(_ statement: OpaquePointer?) throws {
        guard let database else {
            throw DatabaseError.notOpen
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.sqlite(message: String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }

        self.bindText(value, to: statement, index: index)
    }

    private func bindOptionalBool(_ value: Bool?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }

        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }

        return String(cString: value)
    }
}

private enum DatabaseError: Error {
    case notOpen
    case openFailed(String)
    case sqlite(message: String)
}
