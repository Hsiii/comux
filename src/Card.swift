import SwiftUI

enum WindowHeaderPlacement {
    case above
    case below
    case hidden
}

struct WindowCardView: View {
    let window: UsageWindow
    let compact: Bool
    let isLocked: Bool
    let headerPlacement: WindowHeaderPlacement

    init(
        window: UsageWindow,
        compact: Bool,
        isLocked: Bool,
        headerPlacement: WindowHeaderPlacement = .above
    ) {
        self.window = window
        self.compact = compact
        self.isLocked = isLocked
        self.headerPlacement = headerPlacement
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            if headerPlacement == .above {
                header
            }

            bar

            if headerPlacement == .below {
                header
            }
        }
    }

    private var header: some View {
        HStack {
            Text(displayWindowLabel(for: window))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(window.available ? resetPaceText(for: window) : "n/a")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var bar: some View {
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
                                width: geometry.size.width * CGFloat(Double(displayRemainingPercentage(for: window)) / 100)
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
        expectedRemainingPercentage(for: window) < Double(displayRemainingPercentage(for: window))
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
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayName)
                        .font(.title3.weight(.semibold))

                    Text(tierLabel(for: account.plan))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)

                Text(resetPaceText(for: account.weeklyWindow))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text(percentageText(for: account.weeklyWindow))
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: false)
            }

            WindowCardView(
                window: account.weeklyWindow,
                compact: false,
                isLocked: isRollingWindowLocked(account.rollingWindow),
                headerPlacement: .hidden
            )

            if account.rollingWindow.available {
                WindowCardView(
                    window: account.rollingWindow,
                    compact: true,
                    isLocked: false,
                    headerPlacement: .below
                )
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

struct SlimAccountCardView: View {
    let account: AccountSnapshot
    let displayName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
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
                }
                .fixedSize(horizontal: true, vertical: false)

                Text(resetPaceText(for: account.weeklyWindow))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text(percentageText(for: account.weeklyWindow))
                    .font(.headline.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: false)
            }

            WindowCardView(
                window: account.weeklyWindow,
                compact: false,
                isLocked: isRollingWindowLocked(account.rollingWindow),
                headerPlacement: .hidden
            )

            if account.rollingWindow.available {
                WindowCardView(
                    window: account.rollingWindow,
                    compact: true,
                    isLocked: false,
                    headerPlacement: .below
                )
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
