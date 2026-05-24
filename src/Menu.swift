import AppKit
import SwiftUI

private struct ViewHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// Layout constants and helpers for the menu panel
private let minPanelHeight: CGFloat = 88
private let panelWidth: CGFloat = 360
private let managerHeight: CGFloat = 460
private let controlHeight: CGFloat = 28
private let controlDividerSpacing: CGFloat = 6
private let controlSectionHorizontalInset: CGFloat = 0
private let controlStateColumnWidth: CGFloat = 8
private let controlStateSpacing: CGFloat = 4

private var maxPanelHeight: CGFloat {
    let visibleScreenHeight = NSScreen.main?.visibleFrame.height ?? 900
    return max(620, min(visibleScreenHeight - 120, 820))
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

private final class FirstResponderResetView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(nil)
        }
    }
}

private struct InitialFirstResponderResetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        FirstResponderResetView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
    @ObservedObject var launchAtLoginStore: LaunchAtLoginStore
    @Binding var isManagingAccounts: Bool
    @Binding var measuredContentHeight: CGFloat
    private let panelPadding: CGFloat = 12

    var body: some View {
        ZStack {
            Color.clear
                .ignoresSafeArea()

            ScrollView {
                self.panelContent
            }
            .scrollBounceBehavior(.basedOnSize)
            .usesSubtleAppKitScrollIndicators()
        }
        .overlay(alignment: .topLeading) {
            self.measuringContent
        }
        .onPreferenceChange(ViewHeightKey.self) { height in
            self.measuredContentHeight = max(height, minPanelHeight)
        }
        .preferredColorScheme(.dark)
        .background(InitialFirstResponderResetter())
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

            self.controlStrip
        }
        .padding(panelPadding)
    }

    private var launchAtLoginTitle: String {
        launchAtLoginStore.opensAtLogin ? "Don't Open at Login" : "Open at Login"
    }

    private var controlStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.bottom, controlDividerSpacing)

            self.controlRow(
                self.launchAtLoginTitle,
                showsCheckmark: launchAtLoginStore.opensAtLogin
            ) {
                launchAtLoginStore.setEnabled(!launchAtLoginStore.opensAtLogin)
            }

            self.controlRow("Manage Accounts…") {
                isManagingAccounts = true
            }

            Divider()
                .padding(.vertical, controlDividerSpacing)

            self.controlRow("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, controlSectionHorizontalInset)
    }

    private func controlRow(
        _ title: String,
        showsCheckmark: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: controlStateSpacing) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: controlStateColumnWidth, alignment: .center)
                    .opacity(showsCheckmark ? 1 : 0)

                Text(title)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: controlHeight, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private var measuringContent: some View {
        self.panelContent
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                Color.clear
                    .preference(key: ViewHeightKey.self, value: geometry.size.height)
                }
            }
            .frame(width: panelWidth, alignment: .topLeading)
            .hidden()
            .allowsHitTesting(false)
    }
}



struct PulseMenuView: View {
    @ObservedObject var coordinator: PulseCoordinator
    @StateObject private var nicknameStore = NicknameStore()
    @StateObject private var launchAtLoginStore = LaunchAtLoginStore()
    @State private var isManagingAccounts = false
    @State private var dashboardContentHeight: CGFloat = 620
    @State private var isShowingLaunchAtLoginError = false

    var body: some View {
        ZStack {
            SlimDashboardPanelView(
                coordinator: coordinator,
                nicknameStore: nicknameStore,
                launchAtLoginStore: launchAtLoginStore,
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
        .frame(width: panelWidth, height: self.panelHeight)
        .background(.clear)
        .animation(.easeOut(duration: 0.16), value: self.isManagingAccounts)
        .onChange(of: self.launchAtLoginStore.errorMessage) { _, errorMessage in
            self.isShowingLaunchAtLoginError = errorMessage != nil
        }
        .alert("Couldn’t Update Login Item", isPresented: self.$isShowingLaunchAtLoginError) {
            Button("OK") {
                self.launchAtLoginStore.clearError()
            }
        } message: {
            Text(self.launchAtLoginStore.errorMessage ?? "")
        }
    }

    private var panelHeight: CGFloat {
        let fittedDashboardHeight = min(
            max(self.dashboardContentHeight, minPanelHeight),
            maxPanelHeight
        )

        if self.isManagingAccounts {
            return max(fittedDashboardHeight, managerHeight)
        }

        return fittedDashboardHeight
    }
}
