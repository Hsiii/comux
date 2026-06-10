import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginStore: ObservableObject {
    @Published private(set) var opensAtLogin = false
    @Published var errorMessage: String?

    init() {
        self.refresh()
    }

    func refresh() {
        self.opensAtLogin = Self.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            self.opensAtLogin = enabled
            self.errorMessage = nil
        } catch {
            self.opensAtLogin = Self.isEnabled
            self.errorMessage = Self.message(for: enabled, error: error)
        }
    }

    func clearError() {
        self.errorMessage = nil
    }

    private static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private static func message(for enabled: Bool, error: Error) -> String {
        let fallback = enabled
            ? "comux could not be added to Login Items. Install the app in /Applications and try again."
            : "comux could not be removed from Login Items."

        let details = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if details.isEmpty || details == "The operation couldn’t be completed." {
            return fallback
        }

        return "\(fallback) \(details)"
    }
}
