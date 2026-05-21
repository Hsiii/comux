import SwiftUI

func formatCountdown(_ value: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: value) else {
        return "n/a"
    }

    let diff = Int(date.timeIntervalSinceNow)

    if diff <= 0 {
        return "just reset"
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

func formatRelative(_ value: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: value) else {
        return value
    }

    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

func clampPercentage(_ value: Double) -> Double {
    min(100, max(0, value))
}

func remainingPercentage(for window: UsageWindow) -> Int {
    Int(round(clampPercentage(100 - window.usedPercentage)))
}

func hasJustReset(_ window: UsageWindow, now: Date = Date()) -> Bool {
    guard let resetDate = ISO8601DateFormatter().date(from: window.resetsAt) else {
        return false
    }

    return resetDate <= now
}

func displayRemainingPercentage(for window: UsageWindow) -> Int {
    hasJustReset(window) ? 100 : remainingPercentage(for: window)
}

func percentageText(for window: UsageWindow) -> String {
    "\(displayRemainingPercentage(for: window))%"
}

func sessionResetText(for window: UsageWindow) -> String {
    if hasJustReset(window) || isFreshResetWindow(window) {
        return "Fresh session"
    }

    return "Session resets in \(formatCountdown(window.resetsAt))"
}

func resetPaceText(for window: UsageWindow) -> String {
    if hasJustReset(window) {
        return "Fresh"
    }

    let delta = displayRemainingPercentage(for: window) - Int(round(expectedRemainingPercentage(for: window)))
    let deltaText = delta > 0 ? "+\(delta)%" : "\(delta)%"
    return "\(deltaText) • Resets in \(formatCountdown(window.resetsAt))"
}

func displayWindowLabel(for window: UsageWindow) -> String {
    let label = window.label.lowercased()

    if label.contains("week") {
        return "Weekly"
    }

    if label.contains("5-hour") || label.contains("5h") {
        return "5h"
    }

    return window.label
}

func canonicalAccountIdentity(for account: AccountSnapshot) -> String {
    [
        account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        account.plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    ].joined(separator: "::")
}

func isPersonalPlan(_ plan: String) -> Bool {
    let normalized = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.contains("free") || normalized.contains("personal")
}

func normalizedWorkspaceLabel(_ workspaceLabel: String, plan: String) -> String {
    let trimmed = workspaceLabel.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.caseInsensitiveCompare("free") == .orderedSame {
        return "Personal"
    }

    if trimmed.isEmpty && isPersonalPlan(plan) {
        return "Personal"
    }

    return trimmed
}

func tierLabel(for plan: String) -> String {
    let normalized = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if normalized.contains("team") {
        return "Team"
    }

    if isPersonalPlan(plan) {
        return "Personal"
    }

    if normalized.contains("pro") {
        return "Pro"
    }

    if normalized.hasPrefix("codex ") {
        return String(plan.dropFirst(6))
    }

    return plan
}

func accountTierText(for account: AccountSnapshot) -> String {
    let tier = tierLabel(for: account.plan)
    let workspace = normalizedWorkspaceLabel(account.workspaceLabel, plan: account.plan)

    if workspace == "Ambient ~/.codex session" {
        return tier
    }

    if tier == "Team" && !workspace.isEmpty {
        return "Team \(workspace)"
    }

    return workspace.isEmpty ? tier : workspace
}

func compactAccountTag(for account: AccountSnapshot) -> String? {
    accountTierText(for: account)
}

func windowDuration(for window: UsageWindow) -> TimeInterval? {
    let label = window.label.lowercased()

    if label.contains("week") {
        return 7 * 24 * 60 * 60
    }

    if label.contains("5-hour") || label.contains("5h") {
        return 5 * 60 * 60
    }

    return nil
}

func expectedRemainingPercentage(for window: UsageWindow) -> Double {
    guard window.available,
          let duration = windowDuration(for: window),
          let resetDate = ISO8601DateFormatter().date(from: window.resetsAt)
    else {
        return 0
    }

    let startDate = resetDate.addingTimeInterval(-duration)
    let elapsed = Date().timeIntervalSince(startDate)
    return clampPercentage(100 - ((elapsed / duration) * 100))
}

func isFreshResetWindow(_ window: UsageWindow, now: Date = Date()) -> Bool {
    guard window.available,
          window.usedMinutes == 0,
          remainingPercentage(for: window) == 100,
          let resetDate = ISO8601DateFormatter().date(from: window.resetsAt)
    else {
        return false
    }

    return resetDate <= now
}

func isRollingWindowLocked(_ window: UsageWindow) -> Bool {
    window.available && remainingPercentage(for: window) == 0 && !hasJustReset(window)
}

func sortedAccountsByResetTime(
    _ accounts: [AccountSnapshot],
    displayName: (AccountSnapshot) -> String
) -> [AccountSnapshot] {
    let now = Date()

    return accounts.sorted { left, right in
        let leftFresh = isFreshResetWindow(left.weeklyWindow, now: now)
        let rightFresh = isFreshResetWindow(right.weeklyWindow, now: now)

        if leftFresh != rightFresh {
            return leftFresh
        }

        let leftDate = ISO8601DateFormatter().date(from: left.weeklyWindow.resetsAt)
        let rightDate = ISO8601DateFormatter().date(from: right.weeklyWindow.resetsAt)

        switch (leftDate, rightDate) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate < rightDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return displayName(left).localizedCaseInsensitiveCompare(displayName(right)) == .orderedAscending
        }
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
