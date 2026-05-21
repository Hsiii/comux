import AppKit
import SwiftUI

struct AccountManagerOverlayView: View {
    @ObservedObject var coordinator: PulseCoordinator
    @ObservedObject var nicknameStore: NicknameStore
    let onCancel: () -> Void
    let onSave: () -> Void

    @State private var editingAccountID: String?
    @State private var draftNicknames: [String: String]
    @State private var pendingRemoval: AccountSnapshot?
    @FocusState private var focusedAccountID: String?

    init(
        coordinator: PulseCoordinator,
        nicknameStore: NicknameStore,
        onCancel: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.nicknameStore = nicknameStore
        self.onCancel = onCancel
        self.onSave = onSave
        self._draftNicknames = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: coordinator.cache.accounts.map { account in
                    (account.id, nicknameStore.nickname(for: account))
                }
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Manage Accounts")
                .font(.title3.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(coordinator.cache.accounts) { account in
                        VStack(alignment: .leading, spacing: 10) {
                            if self.editingAccountID == account.id {
                                TextField(
                                    account.label,
                                    text: Binding(
                                        get: { self.draftNicknames[account.id] ?? "" },
                                        set: { self.draftNicknames[account.id] = $0 }
                                    )
                                )
                                .focused(self.$focusedAccountID, equals: account.id)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    self.editingAccountID = nil
                                    self.focusedAccountID = nil
                                }
                            } else {
                                Text(self.displayName(for: account))
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        self.editingAccountID = account.id
                                        DispatchQueue.main.async {
                                            self.focusedAccountID = account.id
                                        }
                                    }
                            }

                            HStack(spacing: 12) {
                                Text(account.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)

                                Spacer()

                                Button(self.pendingRemoval?.id == account.id ? "Confirm" : "Remove") {
                                    if self.pendingRemoval?.id == account.id {
                                        try? coordinator.removeAccount(account)
                                        nicknameStore.removeNickname(for: account)
                                        self.draftNicknames.removeValue(forKey: account.id)
                                        self.editingAccountID = nil
                                        self.focusedAccountID = nil
                                        self.pendingRemoval = nil
                                    } else {
                                        self.pendingRemoval = account
                                    }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(
                                    coordinator.isRemovable(account)
                                        ? (self.pendingRemoval?.id == account.id ? .red : .secondary)
                                        : .secondary
                                )
                                .disabled(!coordinator.isRemovable(account))
                            }
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .hidesAppKitScrollIndicators()

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }

                Button("Save") {
                    nicknameStore.saveNicknames(self.draftNicknames, for: coordinator.cache.accounts)
                    self.editingAccountID = nil
                    self.focusedAccountID = nil
                    onSave()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360, height: 460)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture {
            self.editingAccountID = nil
            self.focusedAccountID = nil
            self.pendingRemoval = nil
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.white.opacity(0.12))
        }
        .onChange(of: coordinator.cache.accounts.map(\.id)) { _, accountIDs in
            self.draftNicknames = self.draftNicknames.filter { accountIDs.contains($0.key) }

            for account in coordinator.cache.accounts where self.draftNicknames[account.id] == nil {
                self.draftNicknames[account.id] = nicknameStore.nickname(for: account)
            }
        }
        .onChange(of: self.focusedAccountID) { _, focusedAccountID in
            if focusedAccountID == nil {
                self.editingAccountID = nil
            }
        }
    }

    private func displayName(for account: AccountSnapshot) -> String {
        let nickname = self.draftNicknames[account.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return nickname.isEmpty ? account.label : nickname
    }
}
