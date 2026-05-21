import AppKit
import SwiftUI

@MainActor
final class TerminationController {
    static let shared = TerminationController()

    private(set) var allowTermination = false

    func requestQuit() {
        self.allowTermination = true
        NSApp.terminate(nil)
    }
}

final class CodexMuxAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TerminationController.shared.allowTermination ? .terminateNow : .terminateCancel
    }
}

@main
struct CodexMuxApp: App {
    @StateObject private var coordinator = PulseCoordinator()
    @NSApplicationDelegateAdaptor(CodexMuxAppDelegate.self) private var appDelegate

    init() {
        // Keep the menu bar process resident even when it has no regular windows.
        ProcessInfo.processInfo.disableAutomaticTermination("CodexMux menu bar app")
    }

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
        guard let url = AppResources.bundle?.url(forResource: "codex-menubar", withExtension: "png", subdirectory: "assets"),
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
