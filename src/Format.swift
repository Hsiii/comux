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

func sessionBadgeText(for window: UsageWindow) -> String {
    if isRollingWindowLocked(window) {
        return "Session locked"
    }

    if hasJustReset(window) || isFreshResetWindow(window) {
        return "Session fresh"
    }

    return "Session \(percentageText(for: window))"
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

    let delta = currentExpectationDelta(for: window)
    let deltaText = delta > 0 ? "+\(delta)%" : "\(delta)%"
    return "\(deltaText) • Resets in \(formatCountdown(window.resetsAt))"
}

func currentExpectationDelta(for window: UsageWindow) -> Int {
    displayRemainingPercentage(for: window) - Int(round(expectedRemainingPercentage(for: window)))
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
    return buildAccountPrimaryKey(
        email: account.email,
        workspaceId: resolvedWorkspaceIdentity(
            accountId: account.accountId,
            workspaceId: account.workspaceId
        ),
        workspaceLabel: account.workspaceLabel
    )
}

func isPersonalPlan(_ plan: String) -> Bool {
    let normalized = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.contains("free")
        || normalized.contains("plus")
        || normalized.contains("pro")
        || normalized.contains("personal")
}

func isTeamPlan(_ plan: String) -> Bool {
    let normalized = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.contains("team")
}

func normalizedWorkspaceLabel(_ workspaceLabel: String, plan: String) -> String {
    let trimmed = workspaceLabel.trimmingCharacters(in: .whitespacesAndNewlines)

    if isPersonalPlan(plan) {
        return "Personal"
    }

    if trimmed.caseInsensitiveCompare("free") == .orderedSame {
        return "Personal"
    }

    return trimmed
}

func normalizedPlanLabel(_ plan: String, workspaceLabel: String) -> String {
    let trimmedPlan = plan.trimmingCharacters(in: .whitespacesAndNewlines)

    if workspaceLabel == "Personal" && isTeamPlan(trimmedPlan) {
        return "Codex Personal"
    }

    return trimmedPlan
}

func tierLabel(for plan: String) -> String {
    let normalized = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if normalized.contains("team") {
        return "Team"
    }

    if normalized.contains("free") {
        return "Free"
    }

    if normalized.contains("plus") {
        return "Plus"
    }

    if normalized.contains("pro") {
        return "Pro"
    }

    if normalized.contains("personal") {
        return "Personal"
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

    if workspace == "Personal" {
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
    return accounts.sorted { left, right in
        let leftCurrent = displayRemainingPercentage(for: left.weeklyWindow)
        let rightCurrent = displayRemainingPercentage(for: right.weeklyWindow)
        let leftIsFull = leftCurrent == 100
        let rightIsFull = rightCurrent == 100
        let leftIsEmpty = leftCurrent == 0
        let rightIsEmpty = rightCurrent == 0

        if leftIsFull != rightIsFull {
            return leftIsFull
        }

        if leftIsFull && rightIsFull {
            let leftIsPaid = !isPersonalPlan(left.plan)
            let rightIsPaid = !isPersonalPlan(right.plan)

            if leftIsPaid != rightIsPaid {
                return leftIsPaid
            }
        }

        if leftIsEmpty != rightIsEmpty {
            return !leftIsEmpty
        }

        let leftDelta = currentExpectationDelta(for: left.weeklyWindow)
        let rightDelta = currentExpectationDelta(for: right.weeklyWindow)

        if leftDelta != rightDelta {
            return leftDelta > rightDelta
        }

        if leftCurrent != rightCurrent {
            return leftCurrent > rightCurrent
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
