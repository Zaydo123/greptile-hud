import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = PRStore()

    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var escMonitor: Any?
    private var refreshTimer: Timer?

    private var rightShiftDown = false
    private var pinned = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        buildPanel()
        installMonitors()
        promptAccessibilityIfNeeded()

        Task { await store.refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.store.refresh() }
        }
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "eyes", accessibilityDescription: "Greptile HUD")
            b.toolTip = "Greptile HUD — hold Right ⇧ to peek"
        }

        let menu = NSMenu()
        let show = NSMenuItem(title: "Show HUD (pinned)", action: #selector(togglePinned), keyEquivalent: "")
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        let hint = NSMenuItem(title: "Tip: hold Right Shift to peek", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        let access = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit Greptile HUD", action: #selector(quitApp), keyEquivalent: "q")
        [show, refresh, access, quit].forEach { $0.target = self }

        menu.addItem(show)
        menu.addItem(refresh)
        menu.addItem(.separator())
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(access)
        menu.addItem(quit)
        statusItem.menu = menu
    }

    // MARK: Overlay panel

    private func buildPanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 588, height: 400),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: HUDView(store: store, onClose: { [weak self] in
            self?.pinned = false
            self?.hideOverlay(force: true)
        }))
        host.autoresizingMask = [.width, .height]
        host.frame = p.contentView?.bounds ?? .zero
        p.contentView = host
        self.panel = p
    }

    private func positionPanel() {
        if let host = panel.contentView as? NSHostingView<HUDView> {
            host.layoutSubtreeIfNeeded()
            let fit = host.fittingSize
            if fit.width > 1, fit.height > 1 { panel.setContentSize(fit) }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.frame else { return }
        let f = panel.frame
        panel.setFrameOrigin(NSPoint(x: visible.midX - f.width / 2,
                                     y: visible.midY - f.height / 2))
    }

    private func showOverlay(pinned: Bool) {
        if pinned { self.pinned = true }
        Task { await store.refresh() }
        positionPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        positionPanel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hideOverlay(force: Bool = false) {
        if pinned && !force { return }
        let panel = self.panel!
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    // MARK: Hotkey + monitors

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] e in
            self?.handleFlags(e)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] e in
            self?.handleFlags(e); return e
        }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self = self else { return }
            if e.keyCode == 53, self.pinned {   // Esc closes a pinned HUD
                self.pinned = false
                self.hideOverlay(force: true)
            }
        }
    }

    private func handleFlags(_ e: NSEvent) {
        guard e.keyCode == 60 else { return }   // 60 = Right Shift
        let down = e.modifierFlags.contains(.shift)
        if down && !rightShiftDown {
            rightShiftDown = true
            showOverlay(pinned: false)
        } else if !down && rightShiftDown {
            rightShiftDown = false
            hideOverlay()
        }
    }

    // MARK: Menu actions

    @objc private func togglePinned() {
        if pinned || panel.isVisible {
            pinned = false
            hideOverlay(force: true)
        } else {
            showOverlay(pinned: true)
        }
    }

    @objc private func refreshNow() { Task { await store.refresh() } }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func promptAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if trusted { return }
        let a = NSAlert()
        a.messageText = "Enable Right-Shift Peek"
        a.informativeText = """
        Greptile HUD needs Accessibility access to notice when you hold the Right Shift key.

        Open System Settings ▸ Privacy & Security ▸ Accessibility, switch on “GreptileHUD”, then relaunch the app.
        """
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { openAccessibility() }
    }
}

// MARK: - Entry point

@MainActor
func launch() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon
    app.run()
}

MainActor.assumeIsolated { launch() }
