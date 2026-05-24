import AppKit
import SwiftUI

private struct ViewHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// Layout constants and helpers for the menu panel
private let minPanelHeight: CGFloat = 88
private let panelWidth: CGFloat = 360
private let panelCornerRadius: CGFloat = 12
private let panelOuterPadding: CGFloat = 12
private let controlHeight: CGFloat = 28
private let controlDividerSpacing: CGFloat = 6
private let cardBlockEdgePadding: CGFloat = 16
private let cardBlockHorizontalPadding: CGFloat = 16
private let cardStackSpacing: CGFloat = 16
private let controlDividerHorizontalInset: CGFloat = 16
private let controlRowHorizontalInset: CGFloat = 12
private let controlTextLeadingInset: CGFloat = 14
private let controlHoverInset: CGFloat = 6
private let controlHoverCornerRadius: CGFloat = 8
private let editDialogWidth: CGFloat = 328
private let editDialogOuterPadding: CGFloat = 20
private let editDialogContentSpacing: CGFloat = 16
private let editDialogButtonSpacing: CGFloat = 12

private var controlSectionBottomPadding: CGFloat {
    controlHoverInset
}
private let syncStatusRowHeight: CGFloat = 24
private let syncStatusTopPadding: CGFloat = 8

private struct AccountRowModel: Identifiable {
    let account: AccountSnapshot
    let displayName: String
    let canRemove: Bool

    var id: String { self.account.id }
}

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

private struct LiquidGlassMaterialView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.state = .active
        nsView.blendingMode = .behindWindow
        nsView.isEmphasized = false
    }
}

private struct ControlRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct HoverTrackingArea: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onHoverChanged: onHoverChanged)
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        context.coordinator.onHoverChanged = onHoverChanged
        nsView.coordinator = context.coordinator
    }

    final class Coordinator: NSObject {
        var onHoverChanged: (Bool) -> Void

        init(onHoverChanged: @escaping (Bool) -> Void) {
            self.onHoverChanged = onHoverChanged
        }
    }

    final class TrackingView: NSView {
        weak var coordinator: Coordinator?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                self.removeTrackingArea(trackingArea)
            }

            let nextTrackingArea = NSTrackingArea(
                rect: self.bounds,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil
            )

            self.addTrackingArea(nextTrackingArea)
            self.trackingArea = nextTrackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            self.coordinator?.onHoverChanged(true)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            self.coordinator?.onHoverChanged(false)
        }
    }
}

private struct ControlRowContent: View {
    let id: String
    let title: String
    let showsCheckmark: Bool
    @Binding var hoveredRowID: String?

    private var isHovered: Bool {
        hoveredRowID == id
    }

    var body: some View {
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
            .background {
                RoundedRectangle(cornerRadius: controlHoverCornerRadius, style: .continuous)
                    .fill(self.backgroundColor)
                    .padding(.horizontal, controlHoverInset)
            }
            .overlay {
                HoverTrackingArea { hovering in
                    self.hoveredRowID = hovering ? id : nil
                }
            }
            .foregroundStyle(self.foregroundColor)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onDisappear {
                if self.hoveredRowID == id {
                    self.hoveredRowID = nil
                }
            }
    }

    private var foregroundColor: Color {
        isHovered ? Color(nsColor: .selectedMenuItemTextColor) : .primary
    }

    private var backgroundColor: Color {
        guard isHovered else {
            return .clear
        }

        let color = NSColor.selectedContentBackgroundColor
        return Color(nsColor: color.withAlphaComponent(0.88))
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

private struct RemoveAccountSheet: View {
    let account: AccountSnapshot
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: editDialogContentSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Remove Account")
                    .font(.title3.weight(.semibold))

                Text("Remove the saved account for \(account.email) from CodexMux?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(account.label)
                    .font(.headline.weight(.semibold))

                Text(account.email)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let tag = compactAccountTag(for: account) {
                    Text(tag)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("This only removes the saved account from CodexMux. It does not change the underlying ChatGPT account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: editDialogButtonSpacing) {
                Spacer(minLength: 0)

                Button("Cancel", role: .cancel, action: self.onCancel)
                    .keyboardShortcut(.defaultAction)

                Button("Remove", role: .destructive, action: self.onConfirm)
            }
        }
        .padding(editDialogOuterPadding)
        .frame(width: editDialogWidth, alignment: .leading)
    }
}

private enum AccountDialogRoute: Identifiable {
    case edit(AccountSnapshot)
    case remove(AccountSnapshot)

    var id: String {
        switch self {
        case .edit(let account):
            return "edit:\(account.id)"
        case .remove(let account):
            return "remove:\(account.id)"
        }
    }
}

struct SlimDashboardPanelView: View {
    @ObservedObject var coordinator: PulseCoordinator
    @ObservedObject var nicknameStore: NicknameStore
    @ObservedObject var launchAtLoginStore: LaunchAtLoginStore
    @Binding var measuredContentHeight: CGFloat
    let onEditDisplayNameRequested: (AccountSnapshot) -> Void
    let onRemoveRequested: (AccountSnapshot) -> Void
    @State private var hoveredControlRowID: String?

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
        .onPreferenceChange(ViewHeightKey.self) { height in
            self.measuredContentHeight = max(height, minPanelHeight)
        }
        .preferredColorScheme(.dark)
        .background(InitialFirstResponderResetter())
    }

    private var rows: [AccountRowModel] {
        let sortedAccounts = sortedAccountsByResetTime(coordinator.cache.accounts) { account in
            nicknameStore.displayName(for: account)
        }

        return sortedAccounts.map { account in
            AccountRowModel(
                account: account,
                displayName: nicknameStore.displayName(for: account),
                canRemove: coordinator.isRemovable(account)
            )
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if coordinator.syncStatus.phase == .syncing {
                self.syncStatusRow
            }

            self.accountCardStack

            self.controlStrip
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .preference(key: ViewHeightKey.self, value: geometry.size.height)
            }
        }
    }

    private var accountCardStack: some View {
        VStack(alignment: .leading, spacing: cardStackSpacing) {
            ForEach(rows) { row in
                AccountCardView(
                    account: row.account,
                    displayName: row.displayName,
                    canRemove: row.canRemove,
                    onEditDisplayName: {
                        self.promptForDisplayName(row.account)
                    },
                    onRemove: {
                        self.promptForRemoval(row.account)
                    }
                )
            }
        }
        .padding(.top, cardBlockEdgePadding)
        .padding(.horizontal, cardBlockHorizontalPadding)
    }

    private var syncStatusRow: some View {
        HStack(spacing: 8) {
            if coordinator.syncStatus.phase == .syncing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }

            Text(self.syncStatusText)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, minHeight: syncStatusRowHeight, alignment: .leading)
        .padding(.top, syncStatusTopPadding)
        .padding(.horizontal, cardBlockHorizontalPadding)
    }

    private var syncStatusText: String {
        switch coordinator.syncStatus.phase {
        case .idle:
            return ""
        case .syncing:
            let completedCount = coordinator.syncStatus.completedCount
            let totalCount = max(coordinator.syncStatus.totalCount, completedCount)

            if totalCount == 0 {
                return "Syncing accounts…"
            }

            return "Syncing \(completedCount) of \(totalCount) accounts…"
        }
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
        .onDisappear {
            self.hoveredControlRowID = nil
        }
    }

    private func controlRow(
        _ title: String,
        showsCheckmark: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ControlRowContent(
                id: title,
                title: title,
                showsCheckmark: showsCheckmark,
                hoveredRowID: self.$hoveredControlRowID
            )
        }
        .buttonStyle(ControlRowButtonStyle())
        .focusable(false)
    }

    private func promptForDisplayName(_ account: AccountSnapshot) {
        self.onEditDisplayNameRequested(account)
    }

    private func promptForRemoval(_ account: AccountSnapshot) {
        guard coordinator.isRemovable(account) else {
            NSSound.beep()
            return
        }
        self.onRemoveRequested(account)
    }
}



struct PulseMenuView: View {
    @ObservedObject var coordinator: PulseCoordinator
    let onPanelHeightChange: (CGFloat) -> Void
    @StateObject private var nicknameStore = NicknameStore()
    @StateObject private var launchAtLoginStore = LaunchAtLoginStore()
    @State private var dashboardContentHeight: CGFloat = 620
    @State private var activeDialog: AccountDialogRoute?
    @State private var draftDisplayName = ""

    var body: some View {
        ZStack {
            SlimDashboardPanelView(
                coordinator: coordinator,
                nicknameStore: nicknameStore,
                launchAtLoginStore: launchAtLoginStore,
                measuredContentHeight: self.$dashboardContentHeight,
                onEditDisplayNameRequested: { account in
                    self.promptForDisplayName(account)
                },
                onRemoveRequested: { account in
                    self.promptForRemoval(account)
                }
            )

            if let route = self.activeDialog {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()

                self.accountDialog(for: route)
                    .background(
                        LiquidGlassMaterialView(material: .hudWindow)
                            .overlay {
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.14),
                                        Color.white.opacity(0.04),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(0.28), radius: 20, y: 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(width: panelWidth, height: self.panelHeight)
        .background(
            LiquidGlassMaterialView(material: .hudWindow)
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.03),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        )
        .overlay {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .animation(.easeOut(duration: 0.14), value: self.activeDialog?.id)
        .onAppear {
            self.onPanelHeightChange(self.panelHeight)
        }
        .onChange(of: self.panelHeight) { _, newHeight in
            self.onPanelHeightChange(newHeight)
        }
        .alert("Couldn’t Update Login Item", isPresented: self.isShowingLaunchAtLoginError) {
            Button("OK") {
                self.launchAtLoginStore.clearError()
            }
        } message: {
            Text(self.launchAtLoginStore.errorMessage ?? "")
        }
    }

    private func promptForDisplayName(_ account: AccountSnapshot) {
        self.draftDisplayName = self.nicknameStore.nickname(for: account)
        self.activeDialog = .edit(account)
    }

    private func promptForRemoval(_ account: AccountSnapshot) {
        self.activeDialog = .remove(account)
    }

    private func cancelDisplayNameEditing() {
        self.activeDialog = nil
        self.draftDisplayName = ""
    }

    private func saveDisplayName(for account: AccountSnapshot) {
        self.nicknameStore.saveNicknames(
            [account.id: self.draftDisplayName],
            for: [account]
        )
        self.cancelDisplayNameEditing()
    }

    private func cancelRemoval() {
        self.activeDialog = nil
    }

    private func confirmRemoval(of account: AccountSnapshot) {
        do {
            try self.coordinator.removeAccount(account)
            self.nicknameStore.removeNickname(for: account)
            self.activeDialog = nil
        } catch {
            self.activeDialog = nil
            let errorAlert = NSAlert(error: error)
            errorAlert.runModal()
        }
    }

    @ViewBuilder
    private func accountDialog(for route: AccountDialogRoute) -> some View {
        switch route {
        case .edit(let account):
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
        case .remove(let account):
            RemoveAccountSheet(
                account: account,
                onCancel: {
                    self.cancelRemoval()
                },
                onConfirm: {
                    self.confirmRemoval(of: account)
                }
            )
        }
    }

    private var panelHeight: CGFloat {
        min(
            max(
                max(self.dashboardContentHeight, self.estimatedPanelHeight),
                minPanelHeight
            ),
            maxPanelHeight
        )
    }

    private var estimatedPanelHeight: CGFloat {
        let accountCount = max(self.coordinator.accountCount, 1)
        let cardsHeight = CGFloat(accountCount) * AccountCardView.height
        let cardGapsHeight = CGFloat(max(accountCount - 1, 0)) * cardStackSpacing
        let controlSectionHeight = controlHeight * 2 + controlDividerSpacing * 3 + controlSectionBottomPadding + 1
        let syncStatusHeight = self.coordinator.syncStatus.phase == .syncing
            ? (syncStatusTopPadding + syncStatusRowHeight + 16)
            : 0
        let contentHeight =
            syncStatusHeight +
            cardBlockEdgePadding +
            cardsHeight +
            cardGapsHeight +
            controlSectionHeight +
            panelOuterPadding

        return contentHeight
    }

    private var isShowingLaunchAtLoginError: Binding<Bool> {
        Binding(
            get: {
                self.launchAtLoginStore.errorMessage != nil
            },
            set: { isPresented in
                if !isPresented {
                    self.launchAtLoginStore.clearError()
                }
            }
        )
    }
}
