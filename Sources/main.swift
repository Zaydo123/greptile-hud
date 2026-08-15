import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = PRStore()
    let vibecoders = VibecodersStore()
    private let updater = UpdateController()

    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var escMonitor: Any?
    private var localEscMonitor: Any?
    private var refreshTimer: Timer?
    private var updateCheckTimer: Timer?
    private var vibecodersTimer: Timer?

    private var rightShiftDown = false
    private var pinned = false
    private var usernameFieldEditing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        buildPanel()
        installMonitors()
        promptAccessibilityIfNeeded()

        Task { await store.refresh() }
        Task { await vibecoders.refresh() }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await updater.checkForUpdates(userInitiated: false)
        }
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { await self?.updater.checkForUpdates(userInitiated: false) }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.store.refresh() }
        }
        vibecodersTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.vibecoders.heartbeatIfActive()
            Task { await self?.vibecoders.refresh() }
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
        menu.delegate = self
        statusItem.menu = menu
        populateMenu(menu)
    }

    // MARK: Menu (rebuilt on open so leaderboard/online stay fresh)

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let show = NSMenuItem(title: "Show HUD (pinned)", action: #selector(togglePinned), keyEquivalent: "")
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        [show, refresh, updates].forEach { $0.target = self }
        menu.addItem(show)
        menu.addItem(refresh)
        menu.addItem(updates)

        menu.addItem(.separator())
        addVibecodersMenu(menu)
        menu.addItem(.separator())

        let hint = NSMenuItem(title: "Tip: hold Right Shift to peek", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        let access = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit Greptile HUD", action: #selector(quitApp), keyEquivalent: "q")
        [access, quit].forEach { $0.target = self }
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(access)
        menu.addItem(quit)
    }

    private func addVibecodersMenu(_ menu: NSMenu) {
        let header = NSMenuItem(title: "Vibecoders", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !vibecoders.hasUsername {
            let join = NSMenuItem(title: "Join the devtime leaderboard…", action: #selector(vibecodersSetUsername), keyEquivalent: "")
            join.target = self
            menu.addItem(join)
            return
        }

        let who = NSMenuItem(title: "Crew as @\(vibecoders.username)", action: nil, keyEquivalent: "")
        who.isEnabled = false
        menu.addItem(who)
        let today = NSMenuItem(title: "Devtime today: \(vcDuration(vibecoders.devtimeToday))", action: nil, keyEquivalent: "")
        today.isEnabled = false
        menu.addItem(today)

        if !vibecoders.online.isEmpty {
            menu.addItem(.separator())
            let onl = NSMenuItem(title: "Online now", action: nil, keyEquivalent: "")
            onl.isEnabled = false
            menu.addItem(onl)
            for u in vibecoders.online.prefix(6) {
                let item = NSMenuItem(title: "● \(vcDisplayName(u.name) ?? u.login) — \(vcDuration(u.devtimeToday))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        let lb = NSMenuItem(title: "Leaderboard", action: nil, keyEquivalent: "")
        let lbMenu = NSMenu()
        for e in vibecoders.board.prefix(8) {
            let item = NSMenuItem(title: "\(e.rank).  \(vcDisplayName(e.name) ?? e.login)  \(vcDuration(e.value))",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            lbMenu.addItem(item)
        }
        lb.submenu = lbMenu
        menu.addItem(lb)

        let refreshVC = NSMenuItem(title: "Refresh vibecoders", action: #selector(vibecodersRefresh), keyEquivalent: "")
        let change = NSMenuItem(title: "Change username…", action: #selector(vibecodersSetUsername), keyEquivalent: "")
        let out = NSMenuItem(title: "Forget username", action: #selector(vibecodersForget), keyEquivalent: "")
        [refreshVC, change, out].forEach { $0.target = self }
        menu.addItem(refreshVC)
        menu.addItem(change)
        menu.addItem(out)
    }

    @objc private func vibecodersSetUsername() {
        let alert = NSAlert()
        alert.messageText = "Vibecoders username"
        alert.informativeText = "Pick the name shown on the devtime leaderboard. No GitHub account, no tokens, no tracking — we take your word for it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "username"
        field.stringValue = vibecoders.username
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            vibecoders.setUsername(field.stringValue)
        }
    }

    @objc private func vibecodersRefresh() { Task { await vibecoders.refresh() } }
    @objc private func vibecodersForget() { vibecoders.clearUsername() }

    // MARK: Overlay panel

    private func buildPanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0,
                                           width: HUDMetrics.panelWidth,
                                           height: HUDMetrics.panelHeight),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true   // let the username field take typing without stealing focus on every peek
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentMinSize = NSSize(width: HUDMetrics.panelWidth, height: HUDMetrics.panelHeight)
        p.contentMaxSize = p.contentMinSize

        let host = NSHostingView(rootView: HUDView(store: store, vibecoders: vibecoders, onClose: { [weak self] in
            self?.pinned = false
            self?.usernameFieldEditing = false
            self?.hideOverlay(force: true)
        }, onUsernameEditing: { [weak self] editing in
            self?.usernameFieldEditing = editing
        }))
        host.autoresizingMask = [.width, .height]
        host.frame = p.contentView?.bounds ?? .zero
        p.contentView = host
        self.panel = p
    }

    private func positionPanel() {
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
            guard let self else { return }
            if e.keyCode == 53, self.pinned || self.usernameFieldEditing {   // Esc closes a pinned HUD (or while typing)
                self.pinned = false
                self.usernameFieldEditing = false
                self.hideOverlay(force: true)
            }
        }
        // Global monitors don't fire for our own events; once the app is active
        // (username typing) Esc must be caught here instead.
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53, self.pinned || self.usernameFieldEditing {
                self.pinned = false
                self.usernameFieldEditing = false
                self.hideOverlay(force: true)
            }
            return e
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
            if !usernameFieldEditing { hideOverlay() }   // don't vanish while the username field is focused
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

    @objc private func refreshNow() { Task { await store.refresh(force: true) } }

    @objc private func checkForUpdates() {
        Task { await updater.checkForUpdates(userInitiated: true) }
    }

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

// MARK: - Menu rebuild on open (fresh leaderboard/online state)

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
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
