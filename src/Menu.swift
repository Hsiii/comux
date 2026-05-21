import AppKit
import SwiftUI

private struct ViewHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollIndicatorHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            hideScrollIndicators(from: view)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            hideScrollIndicators(from: view)
        }
    }

    private func hideScrollIndicators(from view: NSView) {
        var currentView: NSView? = view

        while let view = currentView {
            if let scrollView = view as? NSScrollView {
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
                scrollView.autohidesScrollers = true
                return
            }

            currentView = view.superview
        }
    }
}

extension View {
    func hidesAppKitScrollIndicators() -> some View {
        self
            .scrollIndicators(.hidden)
            .background(ScrollIndicatorHider())
    }
}

struct SlimDashboardPanelView: View {
    @ObservedObject var coordinator: PulseCoordinator
    @ObservedObject var nicknameStore: NicknameStore
    @Binding var isManagingAccounts: Bool
    @Binding var measuredContentHeight: CGFloat

    var body: some View {
        ZStack {
            Color.clear
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sortedAccounts) { account in
                        SlimAccountCardView(
                            account: account,
                            displayName: nicknameStore.displayName(for: account)
                        )
                    }

                    HStack(spacing: 8) {
                        Spacer()

                        Button("Edit") {
                            isManagingAccounts = true
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                        Button("Quit") {
                            NSApplication.shared.terminate(nil)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(16)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(key: ViewHeightKey.self, value: geometry.size.height)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .hidesAppKitScrollIndicators()
            .onPreferenceChange(ViewHeightKey.self) { height in
                self.measuredContentHeight = height
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await coordinator.syncNow()
        }
    }

    private var sortedAccounts: [AccountSnapshot] {
        sortedAccountsByResetTime(coordinator.cache.accounts) { account in
            nicknameStore.displayName(for: account)
        }
    }
}

struct PulseMenuView: View {
    @ObservedObject var coordinator: PulseCoordinator
    @StateObject private var nicknameStore = NicknameStore()
    @State private var isManagingAccounts = false
    @State private var dashboardContentHeight: CGFloat = 620

    private let panelWidth: CGFloat = 440
    private let maxPanelHeight: CGFloat = 620
    private let managerHeight: CGFloat = 460

    var body: some View {
        ZStack {
            SlimDashboardPanelView(
                coordinator: coordinator,
                nicknameStore: nicknameStore,
                isManagingAccounts: self.$isManagingAccounts,
                measuredContentHeight: self.$dashboardContentHeight
            )

            if self.isManagingAccounts {
                Color.black.opacity(0.24)
                    .ignoresSafeArea()

                AccountManagerOverlayView(
                    coordinator: coordinator,
                    nicknameStore: nicknameStore,
                    onCancel: {
                        self.isManagingAccounts = false
                    },
                    onSave: {
                        self.isManagingAccounts = false
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(1)
            }
        }
        .frame(width: self.panelWidth, height: self.panelHeight)
        .background(.clear)
        .animation(.easeOut(duration: 0.16), value: self.isManagingAccounts)
    }

    private var panelHeight: CGFloat {
        let fittedDashboardHeight = min(
            max(self.dashboardContentHeight, 1),
            self.maxPanelHeight
        )

        if self.isManagingAccounts {
            return max(fittedDashboardHeight, self.managerHeight)
        }

        return fittedDashboardHeight
    }
}
