import AppKit
import Carbon.HIToolbox
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Screenshot Shelf
//
// Opt-in replacement for the macOS floating screenshot thumbnail. A new
// screenshot is copied to the clipboard straight away, and its thumbnail sits
// in the bottom-right corner of the display it was taken on (not the main one)
// for as long as you've chosen. You can drag it anywhere, click it to open it,
// or show it in Finder. ⌘V pastes the newest screenshot; ⌘⇧V pastes every
// screenshot on the shelf at once. Everything stays on this Mac: files are read locally
// and nothing about them is uploaded.

/// Reads the `com.apple.screencapture` preferences: where screenshots go and
/// whether macOS shows its own floating thumbnail.
enum ScreenCapturePrefs {
    private static let domain = "com.apple.screencapture" as CFString
    private static let thumbnailKey = "show-thumbnail" as CFString

    /// The folder screenshots are saved to (⌘⇧5 ▸ Options), defaulting to the Desktop.
    static func location() -> URL {
        CFPreferencesAppSynchronize(domain)
        if let raw = CFPreferencesCopyAppValue("location" as CFString, domain) as? String {
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
    }

    /// The stored `show-thumbnail` value: `nil` when unset (macOS default: on).
    static var thumbnailSetting: Bool? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(thumbnailKey, domain) as? Bool
    }

    /// Set (or, with `nil`, clear back to the default) macOS's own floating thumbnail.
    static func setThumbnail(_ value: Bool?) {
        CFPreferencesSetAppValue(thumbnailKey, value.map { $0 as CFBoolean }, domain)
        CFPreferencesAppSynchronize(domain)
    }
}

/// A screenshot that just landed in the screenshot folder.
struct ScreenCapture: @unchecked Sendable {
    let url: URL
    /// The captured area in global display points (top-left origin), from the
    /// file's own `kMDItemScreenCaptureGlobalRect` attribute.
    let globalRect: CGRect?
    let thumbnail: CGImage
}

/// Watches the screenshot folder for new captures. All state lives on `queue`,
/// so the folder reads (and any Desktop-access prompt) stay off the main thread.
final class ScreenshotWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "greptilehud.screenshots", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var dir: URL?
    private var seen = Set<String>()
    private let onCapture: @Sendable (ScreenCapture) -> Void

    /// Anything created longer ago than this is an old file, not a fresh capture.
    private static let freshness: TimeInterval = 30

    init(onCapture: @escaping @Sendable (ScreenCapture) -> Void) {
        self.onCapture = onCapture
    }

    func start() { queue.async { self.rearm() } }

    func stop() {
        queue.async {
            self.source?.cancel()
            self.source = nil
            self.dir = nil
            self.seen = []
        }
    }

    /// Re-arm if the screenshot folder moved (⌘⇧5 ▸ Options ▸ Save to).
    func checkLocation() {
        queue.async {
            if self.dir?.standardizedFileURL.path != ScreenCapturePrefs.location().standardizedFileURL.path {
                self.rearm()
            }
        }
    }

    private func rearm() {
        source?.cancel()
        source = nil
        dir = nil
        let target = ScreenCapturePrefs.location()
        guard let names = Self.listing(target) else { return }   // unreadable — retried by checkLocation
        seen = names   // baseline: never surface what was already there
        let fd = open(target.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .rename, .delete],
                                                            queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.isDisjoint(with: [.rename, .delete]) {
                self.rearm()   // the folder itself went away or moved
            } else {
                self.scheduleScans()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        dir = target
    }

    /// screencapture writes a hidden temp file, renames it into place and tags
    /// it; a few passes catch the file whichever order that lands in.
    private func scheduleScans() {
        for delay in [0.2, 0.8, 2.5] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scan() }
        }
    }

    private func scan() {
        guard let dir, let names = Self.listing(dir) else { return }
        seen.formIntersection(names)
        let now = Date()
        for name in names where !seen.contains(name) {
            let url = dir.appendingPathComponent(name)
            guard Self.isImage(url) else { seen.insert(name); continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            let fresh = now.timeIntervalSince(created) < Self.freshness
            guard fresh else { seen.insert(name); continue }
            // Not tagged yet, or not decodable yet: leave it for the next pass.
            guard Self.isScreenCapture(url), let thumb = Self.thumbnail(url) else { continue }
            seen.insert(name)
            onCapture(ScreenCapture(url: url, globalRect: Self.globalRect(url), thumbnail: thumb))
        }
    }

    // MARK: File helpers

    private static func listing(_ dir: URL) -> Set<String>? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return Set(names.filter { !$0.hasPrefix(".") })
    }

    private static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) ?? false
    }

    /// The file's Spotlight attribute, read straight off its extended attributes
    /// so this works even where Spotlight indexing is off.
    private static func metadata(_ url: URL, _ key: String) -> Any? {
        url.withUnsafeFileSystemRepresentation { path -> Any? in
            guard let path else { return nil }
            let name = "com.apple.metadata:" + key
            let len = getxattr(path, name, nil, 0, 0, 0)
            guard len > 0 else { return nil }
            var data = Data(count: len)
            let got = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, len, 0, 0) }
            guard got == len else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
    }

    private static func isScreenCapture(_ url: URL) -> Bool {
        (metadata(url, "kMDItemIsScreenCapture") as? NSNumber)?.boolValue ?? false
    }

    /// `[x, y, width, height]` in global points, top-left origin.
    private static func globalRect(_ url: URL) -> CGRect? {
        guard let raw = metadata(url, "kMDItemScreenCaptureGlobalRect") as? [Any], raw.count == 4 else { return nil }
        let v = raw.compactMap { item -> Double? in
            if let n = item as? NSNumber { return n.doubleValue }
            if let s = item as? String { return Double(s) }
            return nil
        }
        guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    private static func thumbnail(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 720,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// MARK: - Shelf (cards in the corner)

/// One screenshot on the shelf.
@MainActor
final class ShotCard: ObservableObject {
    let url: URL
    let thumbnail: NSImage
    let displayID: CGDirectDisplayID?
    /// Seconds on screen; 0 means "until dismissed".
    let lifetime: TimeInterval
    @Published var remaining: TimeInterval
    /// Whether this card's image is what's on the clipboard right now.
    @Published var onClipboard = false
    /// How many screenshots are on the shelf (all displays) — what ⌘⇧V pastes.
    @Published var shelfCount = 1
    /// Hovering or dragging pauses the countdown.
    @Published var hovering = false { didSet { if !hovering { topUp() } } }
    var dragging = false { didSet { if !dragging { topUp() } } }
    var panel: NSPanel!
    var placed = false

    var paused: Bool { hovering || dragging }

    init(url: URL, thumbnail: NSImage, displayID: CGDirectDisplayID?, lifetime: TimeInterval) {
        self.url = url
        self.thumbnail = thumbnail
        self.displayID = displayID
        self.lifetime = lifetime
        self.remaining = lifetime
    }

    /// After you've touched a card, give it a few more seconds before it goes.
    private func topUp() {
        guard lifetime > 0 else { return }
        remaining = max(remaining, min(lifetime, 5))
    }
}

@MainActor
final class ScreenshotShelf {
    static let enabledKey = "shots.enabled"
    static let lifetimeKey = "shots.lifetime"
    /// What `show-thumbnail` was before we switched it off ("unset" / "on"),
    /// so turning the shelf off puts macOS back exactly as it was.
    static let systemThumbnailKey = "shots.systemThumbnailWas"

    static let lifetimes: [(label: String, seconds: TimeInterval)] = [
        ("15 seconds", 15), ("30 seconds", 30), ("1 minute", 60),
        ("5 minutes", 300), ("Until dismissed", 0),
    ]
    static let defaultLifetime: TimeInterval = 60
    static let maxPerScreen = 5
    private static let margin: CGFloat = 16
    private static let gap: CGFloat = 10

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    var lifetime: TimeInterval {
        get { UserDefaults.standard.object(forKey: Self.lifetimeKey) as? Double ?? Self.defaultLifetime }
        set { UserDefaults.standard.set(newValue, forKey: Self.lifetimeKey) }
    }

    private lazy var watcher = ScreenshotWatcher { [weak self] capture in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.present(capture) }
        }
    }
    private var cards: [ShotCard] = []
    private var tick: Timer?
    private var lastTick = Date()
    private var locationTimer: Timer?
    private var clipboardChangeCount = -1
    /// ⌘⇧V, held only while there's a batch to paste, so "Paste and Match
    /// Style" keeps working everywhere else.
    private lazy var pasteAllKey: GlobalHotKey = {
        let key = GlobalHotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
        key.onPress = { [weak self] in self?.pasteAll() }
        return key
    }()

    func start() {
        guard isEnabled else { return }
        watcher.start()
        locationTimer?.invalidate()
        locationTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watcher.checkLocation() }
        }
    }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            quietSystemThumbnail()
            start()
        } else {
            watcher.stop()
            locationTimer?.invalidate()
            locationTimer = nil
            cards.forEach { dismiss($0, relayout: false) }
            restoreSystemThumbnail()
        }
    }

    func openFolder() {
        NSWorkspace.shared.open(ScreenCapturePrefs.location())
    }

    // MARK: macOS's own thumbnail

    /// With macOS's thumbnail on, the file isn't written until that thumbnail
    /// goes away (~5 s), so you'd see two thumbnails in a row. Switch it off
    /// while the shelf is on, remembering how it was.
    private func quietSystemThumbnail() {
        let current = ScreenCapturePrefs.thumbnailSetting
        guard current != false else { return }   // already off: nothing to restore later
        UserDefaults.standard.set(current == nil ? "unset" : "on", forKey: Self.systemThumbnailKey)
        ScreenCapturePrefs.setThumbnail(false)
    }

    private func restoreSystemThumbnail() {
        guard let was = UserDefaults.standard.string(forKey: Self.systemThumbnailKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.systemThumbnailKey)
        ScreenCapturePrefs.setThumbnail(was == "on" ? true : nil)
    }

    // MARK: Cards

    private func present(_ capture: ScreenCapture) {
        guard isEnabled else { return }
        let image = NSImage(cgImage: capture.thumbnail,
                            size: NSSize(width: capture.thumbnail.width, height: capture.thumbnail.height))
        let screen = Self.screen(for: capture.globalRect)
        let card = ShotCard(url: capture.url, thumbnail: image,
                            displayID: screen.flatMap(Self.displayID), lifetime: lifetime)
        card.panel = makePanel(for: card)
        cards.append(card)
        copy(card)
        trim(displayID: card.displayID)
        layout()

        card.panel.alphaValue = 0
        card.panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            card.panel.animator().alphaValue = 1
        }
        startTicking()
        syncBatch()
    }

    private func makePanel(for card: ShotCard) -> NSPanel {
        let thumb = ShotCardView.thumbSize(for: card.thumbnail.size)
        let size = ShotCardView.panelSize(thumb: thumb)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = ShotCardView(
            card: card, thumb: thumb, size: size,
            onOpen: { NSWorkspace.shared.open(card.url) },
            onCopy: { [weak self] in self?.copy(card) },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([card.url]) },
            onTrash: { [weak self] in
                NSWorkspace.shared.recycle([card.url]) { _, _ in }
                self?.dismiss(card)
            },
            onClose: { [weak self] in self?.dismiss(card) })
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        return p
    }

    /// Image data for pasting into chats and docs, plus the file itself for
    /// Finder, Terminal and anything that takes files.
    private func copy(_ card: ShotCard) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([Self.pasteboardItem(for: card.url)])
        clipboardChangeCount = pb.changeCount
        cards.forEach { $0.onClipboard = ($0 === card) }
    }

    private static func pasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url) {
            item.setData(data, forType: .png)
        } else if let tiff = NSImage(contentsOf: url)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        item.setString(url.absoluteString, forType: .fileURL)
        return item
    }

    // MARK: Paste all (⌘⇧V)

    /// Keep the card counts current, and hold ⌘⇧V only while there are two or
    /// more screenshots to paste.
    private func syncBatch() {
        cards.forEach { $0.shelfCount = cards.count }
        if cards.count >= 2 { pasteAllKey.register() } else { pasteAllKey.unregister() }
    }

    /// Put every screenshot on the shelf (oldest first) on the clipboard as
    /// separate items, paste them with a synthetic ⌘V, then hand ⌘V back to
    /// the newest screenshot alone.
    private func pasteAll() {
        let batch = cards
        guard batch.count >= 2 else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(batch.map { Self.pasteboardItem(for: $0.url) })
        let written = pb.changeCount
        clipboardChangeCount = written
        cards.forEach { $0.onClipboard = true }
        // Typing ⌘V for you needs Accessibility; without it the batch just
        // stays on the clipboard for a manual ⌘V.
        guard AXIsProcessTrusted() else { return }
        Self.afterShiftReleased {
            Self.postCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    // Only if nothing else was copied in the meantime.
                    guard let self, NSPasteboard.general.changeCount == written,
                          let newest = self.cards.last else { return }
                    self.copy(newest)
                }
            }
        }
    }

    /// The synthetic ⌘V must not pick up the Shift you're still holding, or
    /// the app sees ⌘⇧V again. Waits up to a second for it to come up.
    private static func afterShiftReleased(attempt: Int = 0, _ body: @escaping @MainActor () -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskShift, .maskAlternate, .maskControl])
        if held.isEmpty || attempt >= 50 {
            body()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            MainActor.assumeIsolated { afterShiftReleased(attempt: attempt + 1, body) }
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let key = CGKeyCode(kVK_ANSI_V)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private func dismiss(_ card: ShotCard, relayout: Bool = true) {
        guard let index = cards.firstIndex(where: { $0 === card }) else { return }
        cards.remove(at: index)
        let panel = card.panel!
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        if relayout { layout() }
        if cards.isEmpty { stopTicking() }
        syncBatch()
    }

    /// Drop the oldest cards on a display once it has too many, or they'd run
    /// off the top of the screen.
    private func trim(displayID: CGDirectDisplayID?) {
        let screen = Self.screen(id: displayID)
        let room = (screen?.visibleFrame.height ?? 800) - Self.margin * 2
        while true {
            let group = cards.filter { $0.displayID == displayID }
            let height = group.reduce(0) { $0 + $1.panel.frame.height } + Self.gap * CGFloat(max(0, group.count - 1))
            guard group.count > 1, group.count > Self.maxPerScreen || height > room else { return }
            dismiss(group[0], relayout: false)
        }
    }

    /// Newest card in the corner, older ones stacked above it, per display.
    private func layout() {
        let groups = Dictionary(grouping: cards) { $0.displayID ?? 0 }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            for (_, group) in groups {
                guard let screen = Self.screen(id: group[0].displayID) else { continue }
                let vf = screen.visibleFrame
                var y = vf.minY + Self.margin
                for card in group.reversed() {
                    let s = card.panel.frame.size
                    let frame = NSRect(x: vf.maxX - s.width - Self.margin, y: y, width: s.width, height: s.height)
                    if card.placed {
                        card.panel.animator().setFrame(frame, display: true)
                    } else {
                        card.panel.setFrame(frame, display: false)
                        card.placed = true
                    }
                    y += s.height + Self.gap
                }
            }
        }
    }

    // MARK: Countdown

    private func startTicking() {
        guard tick == nil else { return }
        lastTick = Date()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }

    private func stopTicking() {
        tick?.invalidate()
        tick = nil
    }

    private func advance() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        // Something else was copied since: no card is "on the clipboard" now.
        if NSPasteboard.general.changeCount != clipboardChangeCount {
            cards.forEach { $0.onClipboard = false }
        }
        for card in cards where card.lifetime > 0 && !card.paused {
            card.remaining -= dt
            if card.remaining <= 0 { dismiss(card) }
        }
    }

    // MARK: Displays

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The display a card belongs to — or the main one if that display is gone.
    private static func screen(id: CGDirectDisplayID?) -> NSScreen? {
        NSScreen.screens.first { displayID($0) == id } ?? NSScreen.main
    }

    /// The display the capture was taken on: the one it overlaps most, falling
    /// back to wherever the pointer is (it just finished the selection).
    private static func screen(for globalRect: CGRect?) -> NSScreen? {
        let screens = NSScreen.screens
        if let r = globalRect, let primary = screens.first {
            // Global capture coords are top-left origin on the primary display;
            // AppKit's are bottom-left.
            let rect = NSRect(x: r.minX, y: primary.frame.height - r.maxY, width: r.width, height: r.height)
            func overlap(_ s: NSScreen) -> CGFloat {
                let i = s.frame.intersection(rect)
                return i.isNull ? 0 : i.width * i.height
            }
            if let best = screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 {
                return best
            }
        }
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

/// A system-wide shortcut through Carbon's `RegisterEventHotKey`. Unlike an
/// NSEvent monitor it *consumes* the keystroke, so the front app never sees it.
@MainActor
final class GlobalHotKey {
    nonisolated static let signature: OSType = 0x4748_5544   // 'GHUD'
    private static var live: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private let id: UInt32
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var ref: EventHotKeyRef?
    var onPress: () -> Void = {}

    init(keyCode: UInt32, modifiers: UInt32) {
        self.id = Self.nextID
        Self.nextID += 1
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    func register() {
        guard ref == nil else { return }
        Self.installHandler()
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return }
        ref = newRef
        Self.live[id] = self
    }

    func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
        Self.live[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == GlobalHotKey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKey.id
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.live[id]?.onPress() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Lets the first click on an inactive shelf card act immediately (drag,
/// click, buttons) instead of being swallowed.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Card view

struct ShotCardView: View {
    @ObservedObject var card: ShotCard
    let thumb: CGSize
    let size: CGSize
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onReveal: () -> Void
    let onTrash: () -> Void
    let onClose: () -> Void

    static let maxThumb = CGSize(width: 280, height: 180)
    static let minWidth: CGFloat = 220
    static let pad: CGFloat = 8
    static let rowHeight: CGFloat = 28
    static let barHeight: CGFloat = 3
    static let spacing: CGFloat = 6

    static func thumbSize(for image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return maxThumb }
        let scale = min(maxThumb.width / image.width, maxThumb.height / image.height)
        return CGSize(width: max(24, (image.width * scale).rounded()),
                      height: max(24, (image.height * scale).rounded()))
    }

    static func panelSize(thumb: CGSize) -> CGSize {
        CGSize(width: max(thumb.width, minWidth) + pad * 2,
               height: thumb.height + rowHeight + barHeight + spacing * 2 + pad * 2)
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            Image(nsImage: card.thumbnail)
                .resizable()
                .interpolation(.high)
                .frame(width: thumb.width, height: thumb.height)
                .overlay(ShotDragSource(url: card.url, image: card.thumbnail, onClick: onOpen,
                                        onDragging: { card.dragging = $0 }))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Tokyo.stroke(), lineWidth: 1)
                    .allowsHitTesting(false))
                .help("Drag it anywhere · click to open")

            HStack(spacing: 2) {
                Label(statusText, systemImage: card.onClipboard ? "checkmark" : "camera.viewfinder")
                    .foregroundStyle(card.onClipboard ? Tokyo.green : Tokyo.comment)
                    .lineLimit(1)
                    .help(card.shelfCount >= 2
                          ? "⌘V pastes the newest screenshot · ⌘⇧V pastes all \(card.shelfCount)"
                          : "⌘V pastes the newest screenshot")
                Spacer(minLength: 4)
                ShotIconButton(symbol: "doc.on.doc", help: "Copy to clipboard", action: onCopy)
                ShotIconButton(symbol: "folder", help: "Show in Finder", action: onReveal)
                ShotIconButton(symbol: "trash", help: "Move to Trash", action: onTrash)
                ShotIconButton(symbol: "xmark", help: "Dismiss", action: onClose)
            }
            .font(.system(size: 11, weight: .medium))
            .labelStyle(.titleAndIcon)
            .frame(height: Self.rowHeight)

            countdown
        }
        .padding(Self.pad)
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tokyo.bg))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Tokyo.stroke(card.hovering), lineWidth: 1))
        .onHover { card.hovering = $0 }
    }

    /// With a batch on the shelf, advertise ⌘⇧V; otherwise copied-or-not.
    private var statusText: String {
        if card.shelfCount >= 2 { return "⌘⇧V all \(card.shelfCount)" }
        return card.onClipboard ? "Copied" : "Screenshot"
    }

    /// Time left, paused (and dimmed) while you hover.
    private var countdown: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokyo.line)
                if card.lifetime > 0 {
                    Capsule()
                        .fill(card.paused ? Tokyo.comment : Tokyo.blue)
                        .frame(width: geo.size.width * max(0, min(1, card.remaining / card.lifetime)))
                        .animation(.linear(duration: 0.25), value: card.remaining)
                }
            }
        }
        .frame(height: Self.barHeight)
    }
}

private struct ShotIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? Tokyo.fg : Tokyo.fgDim)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Tokyo.surface(2) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// The thumbnail's mouse handling: a click opens the file, a drag carries the
/// file itself into Finder, chats, browsers, editors — on any display.
private struct ShotDragSource: NSViewRepresentable {
    let url: URL
    let image: NSImage
    let onClick: () -> Void
    let onDragging: (Bool) -> Void

    func makeNSView(context: Context) -> DragView {
        let v = DragView()
        update(v)
        return v
    }

    func updateNSView(_ v: DragView, context: Context) { update(v) }

    private func update(_ v: DragView) {
        v.url = url
        v.image = image
        v.onClick = onClick
        v.onDragging = onDragging
    }

    final class DragView: NSView, NSDraggingSource {
        var url: URL?
        var image: NSImage?
        var onClick: () -> Void = {}
        var onDragging: (Bool) -> Void = { _ in }
        private var down: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { down = event }

        override func mouseDragged(with event: NSEvent) {
            guard let down, let url else { return }
            let dx = event.locationInWindow.x - down.locationInWindow.x
            let dy = event.locationInWindow.y - down.locationInWindow.y
            guard dx * dx + dy * dy > 16 else { return }
            self.down = nil
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: image)
            onDragging(true)
            beginDraggingSession(with: [item], event: down, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if down != nil { onClick() }
            down = nil
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy   // the screenshot stays where it was saved
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            onDragging(false)
        }
    }
}
