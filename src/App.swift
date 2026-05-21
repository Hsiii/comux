import AppKit
import SwiftUI

@MainActor
final class CodexMuxAppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = PulseCoordinator()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.coordinator.start()
        ProcessInfo.processInfo.disableAutomaticTermination("CodexMux menu bar app")
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            self.installStatusItem()
            self.installPopover()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProcessInfo.processInfo.enableAutomaticTermination("CodexMux menu bar app")
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "CodexMuxStatusItem"
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.title = "CM"
            button.image = nil
            button.imagePosition = .noImage
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        self.statusItem = statusItem
    }

    private func installPopover() {
        let hostingController = NSHostingController(rootView: PulseMenuView(coordinator: self.coordinator))
        self.popover.contentViewController = hostingController
        self.popover.behavior = .transient
        self.popover.animates = true
        self.popover.contentSize = NSSize(width: 440, height: 620)
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = self.statusItem?.button else {
            return
        }

        if self.popover.isShown {
            self.popover.performClose(sender)
            return
        }

        self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover.contentViewController?.view.window?.becomeKey()
    }

    private static var codexMenuBarIcon: NSImage {
        guard let url = AppResources.url(forResource: "icon", withExtension: "png", subdirectory: "assets"),
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
