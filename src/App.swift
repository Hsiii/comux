import AppKit
import SwiftUI

@main
struct CodexMuxApp: App {
    @StateObject private var coordinator = PulseCoordinator()
    @State private var isMenuBarInserted = true

    init() {
        // Reset the system-managed visibility flag so the menu bar extra can recover
        // after a prior hidden-state launch for this bundle identifier.
        UserDefaults.standard.set(true, forKey: "NSStatusItem VisibleCC Item-0")

        // Keep the menu bar process resident even when it has no regular windows.
        ProcessInfo.processInfo.disableAutomaticTermination("CodexMux menu bar app")
    }

    var body: some Scene {
        MenuBarExtra(isInserted: self.$isMenuBarInserted) {
            PulseMenuView(coordinator: coordinator)
                .task {
                    coordinator.start()
                }
        } label: {
            Image(nsImage: Self.codexMenuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private static var codexMenuBarIcon: NSImage {
        guard let url = AppResources.bundle?.url(forResource: "icon", withExtension: "png", subdirectory: "assets"),
              let image = NSImage(contentsOf: url)
        else {
            return NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "CodexMux") ?? NSImage()
        }

        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        image.accessibilityDescription = "CodexMux"
        return image
    }
}
