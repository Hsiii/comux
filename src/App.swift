import AppKit
import SwiftUI

@main
struct CodexMuxApp: App {
    @StateObject private var coordinator = PulseCoordinator()

    var body: some Scene {
        MenuBarExtra {
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
        guard let url = Bundle.module.url(forResource: "codex-menubar", withExtension: "pdf"),
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
