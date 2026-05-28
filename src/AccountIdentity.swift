import Foundation

struct AccountIdentityKey: Hashable {
    let storageKey: String
    let workspaceSlot: String?
    let normalizedEmail: String
}

enum AccountIdentity {
    static func normalizedEmail(_ email: String) -> String {
        email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func trimmedWorkspaceID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    static func legacyBaseAccountID(from accountID: String) -> String {
        let legacySeparator = "::"

        guard let separatorRange = accountID.range(of: legacySeparator) else {
            return accountID
        }

        return String(accountID[..<separatorRange.lowerBound])
    }

    static func resolvedWorkspaceID(
        accountId: String,
        workspaceId: String?
    ) -> String? {
        if let trimmedWorkspaceID = trimmedWorkspaceID(workspaceId) {
            return trimmedWorkspaceID
        }

        let legacyAccountID = legacyBaseAccountID(from: accountId)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !legacyAccountID.isEmpty else {
            return nil
        }

        if legacyAccountID.hasPrefix("user-")
            || legacyAccountID.hasPrefix("org-")
            || legacyAccountID.hasPrefix("workspace-") {
            return legacyAccountID
        }

        return nil
    }

    static func preferredStorageWorkspaceID(
        workspaceId: String?,
        fallbackAccountId: String?
    ) -> String? {
        if let workspaceId = trimmedWorkspaceID(workspaceId) {
            return workspaceId
        }

        return trimmedWorkspaceID(fallbackAccountId)
    }

    static func storageKey(
        email: String,
        workspaceId: String?,
        workspaceLabel: String
    ) -> String {
        let normalizedEmail = normalizedEmail(email)
        let normalizedWorkspaceID = workspaceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let normalizedWorkspace = workspaceLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if !normalizedEmail.isEmpty && !normalizedWorkspaceID.isEmpty {
            return "\(normalizedEmail)::\(normalizedWorkspaceID)"
        }

        if !normalizedEmail.isEmpty && !normalizedWorkspace.isEmpty {
            return "\(normalizedEmail)::\(normalizedWorkspace)"
        }

        if !normalizedEmail.isEmpty {
            return normalizedEmail
        }

        if !normalizedWorkspaceID.isEmpty {
            return "workspace::\(normalizedWorkspaceID)"
        }

        return normalizedWorkspace.isEmpty ? UUID().uuidString : "workspace::\(normalizedWorkspace)"
    }

    static func key(
        email: String,
        accountId: String,
        workspaceId: String?,
        workspaceLabel: String
    ) -> AccountIdentityKey {
        let workspaceSlot = resolvedWorkspaceID(
            accountId: accountId,
            workspaceId: workspaceId
        )

        return AccountIdentityKey(
            storageKey: storageKey(
                email: email,
                workspaceId: workspaceSlot,
                workspaceLabel: workspaceLabel
            ),
            workspaceSlot: workspaceSlot?.lowercased(),
            normalizedEmail: normalizedEmail(email)
        )
    }

    static func key(for snapshot: AccountSnapshot) -> AccountIdentityKey {
        key(
            email: snapshot.email,
            accountId: snapshot.accountId,
            workspaceId: snapshot.workspaceId,
            workspaceLabel: snapshot.workspaceLabel
        )
    }

    static func key(for config: AccountConfig) -> AccountIdentityKey {
        key(
            email: config.email,
            accountId: config.id,
            workspaceId: config.accountHeader,
            workspaceLabel: config.workspaceLabel
        )
    }

    static func legacyPlanIdentity(for snapshot: AccountSnapshot) -> String {
        let email = normalizedEmail(snapshot.email)
        let plan = snapshot.plan
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !email.isEmpty, !plan.isEmpty else {
            return ""
        }

        return "\(email)::\(plan)"
    }

    static func legacyDisplayNameKeys(for snapshot: AccountSnapshot) -> [String] {
        let email = normalizedEmail(snapshot.email)
        let accountID = snapshot.accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseAccountID = legacyBaseAccountID(from: snapshot.accountId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalIdentity = key(for: snapshot).storageKey
        let planIdentity = legacyPlanIdentity(for: snapshot)

        return [
            email,
            canonicalIdentity,
            planIdentity,
            accountID,
            baseAccountID,
            email.isEmpty ? "" : "system::\(email)",
        ]
        .filter { !$0.isEmpty }
        .reduce(into: [String]()) { keys, key in
            if !keys.contains(key) {
                keys.append(key)
            }
        }
    }

    static func emailFromLegacyDisplayNameKey(_ key: String) -> String? {
        var candidate = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if candidate.hasPrefix("system::") {
            candidate.removeFirst("system::".count)
        }

        if let separatorRange = candidate.range(of: "::") {
            candidate = String(candidate[..<separatorRange.lowerBound])
        }

        return candidate.contains("@") ? normalizedEmail(candidate) : nil
    }
}
