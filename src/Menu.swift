import AppKit
import SwiftUI

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
            }
            .hidesAppKitScrollIndicators()
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
        .frame(width: 440, height: 620)
        .background(.clear)
        .animation(.easeOut(duration: 0.16), value: self.isManagingAccounts)
    }
}
