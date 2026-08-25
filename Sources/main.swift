import AppKit
import SwiftUI

/// The HUD stays nonactivating for normal peeks, but must be allowed to become
/// key when an interactive control explicitly requests keyboard focus.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

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
    private var liveTimer: Timer?
    private var hideToken = 0
    private var updateCheckTimer: Timer?
    private var vibecodersTimer: Timer?

    private var rightShiftDown = false
    private var latchTimer: Timer?

    /// Latched-open state, mirrored into `hudState` so the overlay can show it.
    private let hudState = HUDState()
    private var pinned: Bool {
        get { hudState.pinned }
        set { hudState.pinned = newValue }
    }
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
        let reset = NSMenuItem(title: "Reset Position & Size", action: #selector(resetPanelFrame), keyEquivalent: "")
        [show, refresh, updates, reset].forEach { $0.target = self }
        menu.addItem(show)
        menu.addItem(refresh)
        menu.addItem(updates)
        menu.addItem(reset)

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
        let p = HUDPanel(contentRect: NSRect(x: 0, y: 0,
                                            width: HUDMetrics.panelWidth,
                                            height: HUDMetrics.panelHeight),
                         styleMask: [.borderless, .nonactivatingPanel, .resizable],
                         backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true   // drag the HUD anywhere by its background
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true   // let the username field take typing without stealing focus on every peek
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentMinSize = NSSize(width: HUDMetrics.minPanelWidth, height: HUDMetrics.minPanelHeight)
        p.contentMaxSize = NSSize(width: 4000, height: 3000)
        p.delegate = self

        let host = NSHostingView(rootView: HUDView(store: store, vibecoders: vibecoders, hud: hudState, onClose: { [weak self] in
            self?.dismissOverlay()
        }, onUsernameEditing: { [weak self] editing in
            self?.usernameFieldEditing = editing
        }, onResize: { [weak self] translation in
            self?.resizePanel(translation: translation)
        }, onResizeEnded: { [weak self] in
            self?.endResizePanel()
        }))
        host.autoresizingMask = [.width, .height]
        host.frame = p.contentView?.bounds ?? .zero
        p.contentView = host
        self.panel = p
    }

    /// Put the HUD back where you left it. Only falls back to centring under the
    /// mouse when there's no usable saved frame — e.g. first run, or the screen
    /// it was parked on is gone.
    private func positionPanel() {
        if let saved = savedFrame() {
            panel.setFrame(saved, display: false)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.frame else { return }
        let f = panel.frame
        panel.setFrameOrigin(NSPoint(x: visible.midX - f.width / 2,
                                     y: visible.midY - f.height / 2))
    }

    // MARK: Frame persistence + resize

    private static let frameKey = "hud.panel.frame"

    /// The remembered frame, if it still lands on a connected screen.
    private func savedFrame() -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: Self.frameKey) else { return nil }
        let rect = NSRectFromString(raw)
        guard rect.width >= HUDMetrics.minPanelWidth,
              rect.height >= HUDMetrics.minPanelHeight else { return nil }
        // Needs a decent chunk on-screen, or a since-disconnected display would
        // strand the HUD somewhere you can't reach it.
        let visible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(rect)
            return overlap.width > 120 && overlap.height > 80
        }
        return visible ? rect : nil
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    private var resizeStart: NSRect?

    /// Corner-drag resize. The top-left corner stays put while the bottom-right
    /// follows the cursor, clamped to the minimum size and the current screen.
    private func resizePanel(translation: CGSize) {
        let start = resizeStart ?? panel.frame
        if resizeStart == nil { resizeStart = start }
        let limit = (panel.screen ?? NSScreen.main)?.visibleFrame.size
            ?? NSSize(width: 4000, height: 3000)
        let w = min(limit.width, max(HUDMetrics.minPanelWidth, start.width + translation.width))
        let h = min(limit.height, max(HUDMetrics.minPanelHeight, start.height + translation.height))
        panel.setFrame(NSRect(x: start.minX, y: start.maxY - h, width: w, height: h), display: true)
    }

    private func endResizePanel() {
        resizeStart = nil
        saveFrame()
    }

    @objc private func resetPanelFrame() {
        UserDefaults.standard.removeObject(forKey: Self.frameKey)
        panel.setContentSize(NSSize(width: HUDMetrics.panelWidth, height: HUDMetrics.panelHeight))
        positionPanel()
        saveFrame()
    }

    private func showOverlay(pinned: Bool) {
        if pinned { self.pinned = true }
        Task { await store.refresh() }
        startLiveRefresh()
        hideToken += 1   // supersede any fade-out still in flight

        // A latched overlay stays where it is — only a fresh show re-centers it,
        // so tapping Right Shift doesn't make a pinned HUD hop between screens.
        if !panel.isVisible {
            positionPanel()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            positionPanel()
        }
        // Covers the re-peek-mid-fade case too: the panel is still "visible" but
        // halfway transparent, so fade it back in rather than leaving it dim.
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    /// While the HUD is actually on screen, poll far more often than the
    /// once-a-minute background sweep — Actions runs and their steps move
    /// second to second. Stops the moment the overlay goes away.
    private func startLiveRefresh() {
        guard liveTimer == nil else { return }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { await self?.store.refreshLive() }
        }
    }

    private func stopLiveRefresh() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    /// Every explicit close (✕, Esc, the pin button) goes through here: drop the
    /// latch, cancel any in-flight hold so it can't re-latch a hidden HUD, hide.
    private func dismissOverlay() {
        pinned = false
        usernameFieldEditing = false
        latchTimer?.invalidate()
        latchTimer = nil
        hudState.holdStartedAt = nil
        hideOverlay(force: true)
    }

    private func hideOverlay(force: Bool = false) {
        if pinned && !force { return }
        hideToken += 1
        let token = hideToken
        let panel = self.panel!
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A show that landed during the fade wins — don't order out under it.
                guard let self, self.hideToken == token else { return }
                panel.orderOut(nil)
            }
        })
        stopLiveRefresh()
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
                self.dismissOverlay()
            }
        }
        // Global monitors don't fire for our own events; once the app is active
        // (username typing) Esc must be caught here instead.
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53, self.pinned || self.usernameFieldEditing {
                self.dismissOverlay()
            }
            return e
        }
    }

    private func handleFlags(_ e: NSEvent) {
        guard e.keyCode == 60 else { return }   // 60 = Right Shift
        let down = e.modifierFlags.contains(.shift)
        if down && !rightShiftDown {
            rightShiftDown = true
            // Already latched? Then Right Shift is the toggle that closes it —
            // same key in, same key out, no hold needed.
            if pinned {
                dismissOverlay()
                return
            }
            hudState.holdStartedAt = Date()
            showOverlay(pinned: false)
            // Keep holding and the peek latches into a pinned HUD — see
            // `latchFromHold`. Dropping it again is a click, not a hold.
            latchTimer?.invalidate()
            latchTimer = Timer.scheduledTimer(withTimeInterval: HUDState.latchDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.latchFromHold() }
            }
        } else if !down && rightShiftDown {
            rightShiftDown = false
            hudState.holdStartedAt = nil
            latchTimer?.invalidate()
            latchTimer = nil
            if !usernameFieldEditing { hideOverlay() }   // no-op once latched; don't vanish mid-typing either
        }
    }

    /// Fired once Right Shift has been held for `HUDState.latchDelay`: latch the
    /// overlay open so it survives the release. Unlatching is a click on the pin
    /// (or Esc / ✕) — never another hold.
    private func latchFromHold() {
        latchTimer = nil
        guard rightShiftDown, panel.isVisible, !pinned else { return }
        pinned = true
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

extension AppDelegate: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
}

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
