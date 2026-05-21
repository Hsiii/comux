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

func tierLabel(for plan: String) -> String {
    let normalized = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if normalized.contains("team") {
        return "Team"
    }

    if normalized.contains("free") {
        return "Free"
    }

    if normalized.contains("pro") {
        return "Pro"
    }

    if normalized.hasPrefix("codex ") {
        return String(plan.dropFirst(6))
    }

    return plan
}

func compactAccountTag(for account: AccountSnapshot) -> String? {
    let tier = tierLabel(for: account.plan)

    if tier == "Free" {
        return nil
    }

    let workspace = account.workspaceLabel.trimmingCharacters(in: .whitespacesAndNewlines)

    if workspace == "Ambient ~/.codex session" {
        return tier == "Team" ? nil : tier
    }

    return workspace.isEmpty ? tier : workspace
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

func nextResetWindow(for account: AccountSnapshot) -> UsageWindow {
    guard account.rollingWindow.available,
          !account.rollingWindow.resetsAt.isEmpty,
          let rollingReset = ISO8601DateFormatter().date(from: account.rollingWindow.resetsAt)
    else {
        return account.weeklyWindow
    }

    guard !account.weeklyWindow.resetsAt.isEmpty,
          let weeklyReset = ISO8601DateFormatter().date(from: account.weeklyWindow.resetsAt)
    else {
        return account.rollingWindow
    }

    return rollingReset <= weeklyReset ? account.rollingWindow : account.weeklyWindow
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
