import AppKit
import SwiftUI

private struct ViewHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollIndicatorConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureScrollIndicators(from: view)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            configureScrollIndicators(from: view)
        }
    }

    private func configureScrollIndicators(from view: NSView) {
        var currentView: NSView? = view

        while let view = currentView {
            if let scrollView = view as? NSScrollView {
                scrollView.hasVerticalScroller = true
                scrollView.hasHorizontalScroller = false
                scrollView.autohidesScrollers = true
                scrollView.scrollerStyle = .overlay
                scrollView.verticalScroller?.controlSize = .small
                scrollView.verticalScroller?.alphaValue = 0.35
                return
            }

            currentView = view.superview
        }
    }
}

extension View {
    func usesSubtleAppKitScrollIndicators() -> some View {
        self
            .scrollIndicators(.automatic)
            .background(ScrollIndicatorConfigurator())
    }
}

struct SlimDashboardPanelView: View {
    @ObservedObject var coordinator: PulseCoordinator
    @ObservedObject var nicknameStore: NicknameStore
    @Binding var isManagingAccounts: Bool
    @State private var measuredContentHeight: CGFloat = 88

    private let maxPanelHeight: CGFloat = 620
    private let minPanelHeight: CGFloat = 88

    var body: some View {
        ZStack {
            Color.clear
                .ignoresSafeArea()

            ScrollView {
                self.panelContent
            }
            .frame(height: self.panelHeight)
            .scrollBounceBehavior(.basedOnSize)
            .usesSubtleAppKitScrollIndicators()
        }
        .background {
            self.panelContent
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
        }
        .onPreferenceChange(ViewHeightKey.self) { height in
            self.measuredContentHeight = max(height, self.minPanelHeight)
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

    private var panelContent: some View {
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
                    TerminationController.shared.requestQuit()
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

    private var panelHeight: CGFloat {
        min(max(self.measuredContentHeight, self.minPanelHeight), self.maxPanelHeight)
    }
}

struct PulseMenuView: View {
    @ObservedObject var coordinator: PulseCoordinator
    @StateObject private var nicknameStore = NicknameStore()
    @State private var isManagingAccounts = false

    private let panelWidth: CGFloat = 440

    var body: some View {
        ZStack {
            SlimDashboardPanelView(
                coordinator: coordinator,
                nicknameStore: nicknameStore,
                isManagingAccounts: self.$isManagingAccounts
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
        .frame(width: self.panelWidth)
        .background(.clear)
        .animation(.easeOut(duration: 0.16), value: self.isManagingAccounts)
    }
}
