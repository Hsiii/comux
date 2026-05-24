import AppKit
import SwiftUI

private let statusPanelGap: CGFloat = 6
private let statusPanelWidth: CGFloat = 360

@MainActor
final class PopoverHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        super.loadView()
        self.view.wantsLayer = true
        self.view.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

@MainActor
final class StatusPanel: NSPanel {
    var onCloseRequest: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        self.onCloseRequest?()
    }
}

@MainActor
final class CodexMuxAppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = PulseCoordinator()
    private var statusItem: NSStatusItem?
    private var panel: StatusPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?

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
        self.teardownEventMonitors()
        ProcessInfo.processInfo.enableAutomaticTermination("CodexMux menu bar app")
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "CodexMuxStatusItem"
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.title = ""
            button.image = Self.codexMenuBarIcon
            button.imagePosition = .imageOnly
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        self.statusItem = statusItem
    }

    private func installPopover() {
        let hostingController = PopoverHostingController(
            rootView: PulseMenuView(coordinator: self.coordinator) { [weak self] height in
                self?.updatePanelHeight(height)
            }
        )
        let panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: statusPanelWidth, height: 620),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.onCloseRequest = { [weak self] in
            self?.closePanel()
        }
        self.panel = panel
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = self.statusItem?.button else {
            return
        }

        guard let panel else {
            return
        }

        if panel.isVisible {
            self.closePanel()
            return
        }

        self.positionPanel(relativeTo: button, panel: panel)
        self.installEventMonitors()
        panel.orderFrontRegardless()
        panel.makeKey()
        DispatchQueue.main.async { [weak self] in
            self?.panel?.makeFirstResponder(nil)
        }
    }

    private func positionPanel(relativeTo button: NSStatusBarButton, panel: NSPanel) {
        guard let buttonWindow = button.window else {
            return
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? buttonFrameOnScreen.insetBy(dx: -200, dy: -200)
        let panelSize = panel.frame.size

        var originX = buttonFrameOnScreen.midX - (panelSize.width / 2)
        originX = min(max(originX, visibleFrame.minX + statusPanelGap), visibleFrame.maxX - panelSize.width - statusPanelGap)

        let originY = buttonFrameOnScreen.minY - panelSize.height - statusPanelGap
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func updatePanelHeight(_ height: CGFloat) {
        guard height > 0, let panel = self.panel else {
            return
        }

        let size = NSSize(width: statusPanelWidth, height: height)
        if panel.contentView?.frame.size != size {
            panel.setContentSize(size)
        }

        guard panel.isVisible, let button = self.statusItem?.button else {
            return
        }

        self.positionPanel(relativeTo: button, panel: panel)
    }

    private func installEventMonitors() {
        self.teardownEventMonitors()

        self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else {
                return event
            }

            if event.type == .keyDown, event.keyCode == 53 {
                self.closePanel()
                return nil
            }

            guard let panel = self.panel, panel.isVisible else {
                return event
            }

            if let eventWindow = event.window, self.isPanelInteractionWindow(eventWindow, panel: panel) {
                return event
            }

            self.closePanel()
            return event
        }

        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func teardownEventMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func closePanel() {
        self.panel?.orderOut(nil)
        self.teardownEventMonitors()
    }

    private func isPanelInteractionWindow(_ window: NSWindow, panel: NSPanel) -> Bool {
        if window === panel || window === self.statusItem?.button?.window {
            return true
        }

        if window.sheetParent === panel || window.parent === panel {
            return true
        }

        if panel.attachedSheet === window {
            return true
        }

        return panel.childWindows?.contains(where: { $0 === window }) == true
    }

    private static var codexMenuBarIcon: NSImage {
        let image = AppResources.image(named: "icon", withExtension: "png", subdirectory: "assets")
            ?? AppResources.image(named: "CodexMux", withExtension: "icns")
            ?? NSApplication.shared.applicationIconImage

        guard let image else {
            return NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "CodexMux") ?? NSImage()
        }

        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        image.accessibilityDescription = "CodexMux"
        return image
    }
}
