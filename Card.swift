import SwiftUI

struct WindowCardView: View {
    let window: UsageWindow
    let compact: Bool
    let isLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack {
                Text(displayWindowLabel(for: window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(window.available ? windowStatusText(for: window) : "n/a")
                    .font(.caption.weight(.semibold))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 999)
                        .fill(Color.white.opacity(0.08))
                    if !showsExpectedOverlay {
                        expectedFill
                            .frame(
                                width: geometry.size.width * CGFloat(expectedRemainingPercentage(for: window) / 100)
                            )
                    }
                    barFill
                        .frame(width: geometry.size.width)
                        .mask(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 999)
                                .frame(
                                    width: geometry.size.width * CGFloat(Double(remainingPercentage(for: window)) / 100)
                                )
                        }
                    if showsExpectedOverlay {
                        expectedFill
                            .frame(
                                width: geometry.size.width * CGFloat(expectedRemainingPercentage(for: window) / 100)
                            )
                    }
                }
            }
            .frame(height: compact ? 8 : 14)
            .opacity(window.available ? 1 : 0)
        }
    }

    private var barFill: some View {
        Group {
            if isLocked {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.32),
                        Color.white.opacity(0.2),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.4, green: 0.49, blue: 0.92),
                        Color(red: 0.46, green: 0.29, blue: 0.64),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var showsExpectedOverlay: Bool {
        expectedRemainingPercentage(for: window) < Double(remainingPercentage(for: window))
    }

    private var expectedBarColor: Color {
        Color.white.opacity(0.24)
    }

    private var expectedFill: some View {
        RoundedRectangle(cornerRadius: 999)
            .fill(expectedBarColor)
    }
}

struct AccountCardView: View {
    let account: AccountSnapshot
    let displayName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayName)
                        .font(.title3.weight(.semibold))

                    Text(tierLabel(for: account.plan))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            WindowCardView(
                window: account.weeklyWindow,
                compact: false,
                isLocked: account.rollingWindow.available && remainingPercentage(for: account.rollingWindow) == 0
            )

            if account.rollingWindow.available {
                WindowCardView(window: account.rollingWindow, compact: true, isLocked: false)
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

struct NextResetSectionView: View {
    let accounts: [AccountSnapshot]
    let nicknameStore: NicknameStore

    var body: some View {
        if let nextResetAccount = accounts
            .map({ account in (account: account, window: nextResetWindow(for: account)) })
            .filter({ !$0.window.resetsAt.isEmpty })
            .sorted(by: { $0.window.resetsAt < $1.window.resetsAt })
            .first {
            VStack(alignment: .leading, spacing: 12) {
                Text("NEXT RESET")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                HStack {
                    Text(nicknameStore.displayName(for: nextResetAccount.account))
                        .font(.title.weight(.bold))
                    Spacer()
                    Text(formatCountdown(nextResetAccount.window.resetsAt))
                        .font(.title3.weight(.semibold))
                }
            }
            .padding(20)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
    }
}

struct SlimAccountCardView: View {
    let account: AccountSnapshot
    let displayName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(displayName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                if let tag = compactAccountTag(for: account) {
                    Text(tag)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            WindowCardView(
                window: account.weeklyWindow,
                compact: false,
                isLocked: account.rollingWindow.available && remainingPercentage(for: account.rollingWindow) == 0
            )

            if account.rollingWindow.available {
                WindowCardView(window: account.rollingWindow, compact: true, isLocked: false)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
