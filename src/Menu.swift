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
private let controlHeight: CGFloat = 28
private let controlDividerSpacing: CGFloat = 6
private let cardBlockEdgePadding: CGFloat = 16
private let cardBlockHorizontalPadding: CGFloat = 16
private let controlDividerHorizontalInset: CGFloat = 16
private let controlRowHorizontalInset: CGFloat = 12
private let controlSectionBottomPadding: CGFloat = 12
private let controlTextLeadingInset: CGFloat = 14
private let controlHoverInset: CGFloat = 4
private let controlHoverCornerRadius: CGFloat = 8
private let editDialogWidth: CGFloat = 328
private let editDialogOuterPadding: CGFloat = 20
private let editDialogContentSpacing: CGFloat = 16
private let editDialogButtonSpacing: CGFloat = 12

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

private struct ControlRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: controlHoverCornerRadius, style: .continuous)
                    .fill(self.backgroundColor(isPressed: configuration.isPressed))
                    .padding(.horizontal, controlHoverInset)
            }
            .foregroundStyle(self.foregroundColor)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private var foregroundColor: Color {
        isHovered ? Color(nsColor: .selectedMenuItemTextColor) : .primary
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isHovered || isPressed else {
            return .clear
        }

        let color = NSColor.selectedContentBackgroundColor
        return Color(nsColor: color.withAlphaComponent(isPressed ? 0.96 : 0.88))
    }
}

private struct EditDisplayNameSheet: View {
    let account: AccountSnapshot
    @Binding var draftName: String
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: editDialogContentSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Edit Display Name")
                    .font(.title3.weight(.semibold))

                Text("Choose the name shown for \(account.email).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField(account.label, text: self.$draftName)
                .textFieldStyle(.roundedBorder)
                .focused(self.$isNameFieldFocused)
                .frame(maxWidth: .infinity)
                .onSubmit(self.onSave)

            HStack(spacing: editDialogButtonSpacing) {
                Spacer(minLength: 0)

                Button("Cancel", action: self.onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Save", action: self.onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(editDialogOuterPadding)
        .frame(width: editDialogWidth, alignment: .leading)
        .onAppear {
            self.isNameFieldFocused = true
        }
    }
}

struct SlimDashboardPanelView: View {
    @ObservedObject var coordinator: PulseCoordinator
    @ObservedObject var nicknameStore: NicknameStore
    @ObservedObject var launchAtLoginStore: LaunchAtLoginStore
    @Binding var measuredContentHeight: CGFloat
    let onEditDisplayNameRequested: (AccountSnapshot) -> Void

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
            self.accountCardStack

            self.controlStrip
        }
    }

    private var accountCardStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sortedAccounts) { account in
                AccountCardView(
                    account: account,
                    displayName: nicknameStore.displayName(for: account),
                    canRemove: coordinator.isRemovable(account),
                    onEditDisplayName: {
                        self.promptForDisplayName(account)
                    },
                    onRemove: {
                        self.confirmRemoval(of: account)
                    }
                )
            }
        }
        .padding(.top, cardBlockEdgePadding)
        .padding(.horizontal, cardBlockHorizontalPadding)
    }

    private var launchAtLoginTitle: String {
        "Open at Login"
    }

    private var controlStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.bottom, controlDividerSpacing)
                .padding(.horizontal, controlDividerHorizontalInset)

            self.controlRow(
                self.launchAtLoginTitle,
                showsCheckmark: launchAtLoginStore.opensAtLogin
            ) {
                launchAtLoginStore.setEnabled(!launchAtLoginStore.opensAtLogin)
            }
            Divider()
                .padding(.vertical, controlDividerSpacing)
                .padding(.horizontal, controlDividerHorizontalInset)

            self.controlRow("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.bottom, controlSectionBottomPadding)
    }

    private func controlRow(
        _ title: String,
        showsCheckmark: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .regular))
                .frame(maxWidth: .infinity, minHeight: controlHeight, alignment: .leading)
                .padding(.leading, controlTextLeadingInset)
                .overlay(alignment: .leading) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: controlTextLeadingInset, alignment: .center)
                        .opacity(showsCheckmark ? 1 : 0)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, controlRowHorizontalInset)
        }
        .buttonStyle(ControlRowButtonStyle())
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

    private func promptForDisplayName(_ account: AccountSnapshot) {
        self.onEditDisplayNameRequested(account)
    }

    private func confirmRemoval(of account: AccountSnapshot) {
        guard coordinator.isRemovable(account) else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Remove Account?"
        alert.informativeText = "This removes \(account.email) from CodexMux."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        do {
            try coordinator.removeAccount(account)
            nicknameStore.removeNickname(for: account)
        } catch {
            let errorAlert = NSAlert(error: error)
            errorAlert.runModal()
        }
    }
}



struct PulseMenuView: View {
    @ObservedObject var coordinator: PulseCoordinator
    @StateObject private var nicknameStore = NicknameStore()
    @StateObject private var launchAtLoginStore = LaunchAtLoginStore()
    @State private var dashboardContentHeight: CGFloat = 620
    @State private var isShowingLaunchAtLoginError = false
    @State private var editingAccount: AccountSnapshot?
    @State private var draftDisplayName = ""

    var body: some View {
        SlimDashboardPanelView(
            coordinator: coordinator,
            nicknameStore: nicknameStore,
            launchAtLoginStore: launchAtLoginStore,
            measuredContentHeight: self.$dashboardContentHeight,
            onEditDisplayNameRequested: { account in
                self.promptForDisplayName(account)
            }
        )
        .frame(width: panelWidth, height: self.panelHeight)
        .background(.clear)
        .onChange(of: self.launchAtLoginStore.errorMessage) { _, errorMessage in
            self.isShowingLaunchAtLoginError = errorMessage != nil
        }
        .sheet(item: self.$editingAccount) { account in
            EditDisplayNameSheet(
                account: account,
                draftName: self.$draftDisplayName,
                onCancel: {
                    self.cancelDisplayNameEditing()
                },
                onSave: {
                    self.saveDisplayName(for: account)
                }
            )
        }
        .alert("Couldn’t Update Login Item", isPresented: self.$isShowingLaunchAtLoginError) {
            Button("OK") {
                self.launchAtLoginStore.clearError()
            }
        } message: {
            Text(self.launchAtLoginStore.errorMessage ?? "")
        }
    }

    private func promptForDisplayName(_ account: AccountSnapshot) {
        self.draftDisplayName = self.nicknameStore.nickname(for: account)
        self.editingAccount = account
    }

    private func cancelDisplayNameEditing() {
        self.editingAccount = nil
        self.draftDisplayName = ""
    }

    private func saveDisplayName(for account: AccountSnapshot) {
        self.nicknameStore.saveNicknames(
            [account.id: self.draftDisplayName],
            for: [account]
        )
        self.cancelDisplayNameEditing()
    }

    private var panelHeight: CGFloat {
        min(
            max(self.dashboardContentHeight, minPanelHeight),
            maxPanelHeight
        )
    }
}
