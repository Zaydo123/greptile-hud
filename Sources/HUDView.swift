import SwiftUI
import AppKit

enum HUDMetrics {
    /// Default size. The panel is user-resizable from here (see `ResizeGrip`);
    /// nothing in the layout may size itself from content.
    static let contentWidth: CGFloat = 780
    static let contentHeight: CGFloat = 560
    static let padding: CGFloat = 24
    static let panelWidth = contentWidth + padding * 2
    static let panelHeight = contentHeight + padding * 2

    /// The header and tab bar don't compress below the default width without
    /// clipping, so the HUD only ever grows horizontally. Height is free to
    /// shrink — a shorter HUD just shows fewer rows.
    static let minContentWidth: CGFloat = contentWidth
    static let minContentHeight: CGFloat = 360
    static let minPanelWidth = minContentWidth + padding * 2
    static let minPanelHeight = minContentHeight + padding * 2
}

/// Corner handle that resizes the whole overlay. Reports the drag in points;
/// the app delegate owns the window frame maths.
struct ResizeGrip: View {
    var onChanged: (CGSize) -> Void
    var onEnded: () -> Void
    @State private var hovered = false

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(hovered ? Tokyo.cyan : Tokyo.comment.opacity(0.7))
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onChanged($0.translation) }
                    .onEnded { _ in onEnded() }
            )
            .help("Drag to resize")
    }
}

// MARK: - Spinner (TimelineView so it animates even while our app isn't key)

struct Spinner: View {
    var size: CGFloat = 14
    var color: Color = Tokyo.blue
    var body: some View {
        TimelineView(.animation) { ctx in
            let angle = (ctx.date.timeIntervalSinceReferenceDate * 320).truncatingRemainder(dividingBy: 360)
            Circle()
                .trim(from: 0.05, to: 0.75)
                .stroke(color, style: StrokeStyle(lineWidth: max(1.5, size / 8), lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(angle))
        }
    }
}

// MARK: - Loading placeholders

/// A 2pt sweep used as a "working on it" line under a section header.
struct IndeterminateBar: View {
    var color: Color = Tokyo.cyan
    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { ctx in
                let phase = (ctx.date.timeIntervalSinceReferenceDate * 0.9).truncatingRemainder(dividingBy: 1)
                Capsule()
                    .fill(color.opacity(0.85))
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: -geo.size.width * 0.35 + phase * geo.size.width * 1.35)
            }
        }
        .frame(height: 2)
        .clipped()
    }
}

/// A shimmering placeholder bar. Used to show the *shape* of what's coming
/// instead of an empty box, so a slow fetch doesn't read as "nothing here".
struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 10

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
        TimelineView(.animation) { ctx in
            let phase = (ctx.date.timeIntervalSinceReferenceDate * 0.7).truncatingRemainder(dividingBy: 1)
            shape.fill(Tokyo.surface(1))
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Tokyo.fg.opacity(0.10), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.45)
                            .offset(x: -geo.size.width * 0.45 + phase * geo.size.width * 1.45)
                    }
                }
                .clipShape(shape)
                .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
    }
}

/// Placeholder in the shape of a `PRCard`, shown on the very first load.
struct PRCardSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            Capsule().fill(Tokyo.surface(1)).frame(width: 4, height: 42)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Tokyo.surface(1)).frame(width: 56, height: 48)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(width: 240, height: 11)
                SkeletonBar(width: 150, height: 9)
                SkeletonBar(width: 190, height: 8)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(Tokyo.surface(0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokyo.stroke()))
    }
}

/// Placeholder in the shape of a `RunRow`.
struct RunRowSkeleton: View {
    var body: some View {
        HStack(spacing: 9) {
            Capsule().fill(Tokyo.surface(1)).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBar(width: 120, height: 10)
                SkeletonBar(width: 160, height: 8)
                SkeletonBar(width: 80, height: 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokyo.surface(0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tokyo.stroke()))
    }
}

// MARK: - Safe URL open

/// Open a URL string in the browser only if it's a web (http/https) scheme — defends against a
/// non-web URL ever arriving from the GitHub API. (The System Settings deep-link in main.swift is a
/// hardcoded x-apple.systempreferences: scheme and is intentionally not routed through here.)
func openWebURL(_ string: String) {
    guard let url = URL(string: string),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else { return }
    NSWorkspace.shared.open(url)
}

// MARK: - Shared formatting

/// Compact "3m", "2h", "4d" age string.
func hudAgo(_ d: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

/// Running-clock style duration, e.g. "1h 04m" / "3m 12s" / "9s".
func hudDuration(_ from: Date, _ to: Date) -> String {
    let s = max(0, Int(to.timeIntervalSince(from)))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return String(format: "%dh %02dm", h, m) }
    if m > 0 { return String(format: "%dm %02ds", m, sec) }
    return "\(sec)s"
}

// MARK: - Username field (typing in a nonactivating overlay)

/// An `NSTextField` that force-activates the app and keys the panel when
/// clicked, so the HUD overlay — a nonactivating panel that never takes focus
/// on its own — can actually receive keyboard input for the username.
final class FocusableTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

/// SwiftUI wrapper that reports focus changes (the app keeps the overlay up
/// while the field is focused) and submits on Enter.
struct UsernameField: NSViewRepresentable {
    @Binding var text: String
    var onEditing: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusableTextField {
        let field = FocusableTextField()
        field.placeholderString = "username"
        field.isBezeled = false
        field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        field.textColor = NSColor(Tokyo.fg)
        field.alignment = .left
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        return field
    }

    func updateNSView(_ nsView: FocusableTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var parent: UsernameField
        init(_ parent: UsernameField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ obj: Notification) { parent.onEditing(true) }
        func controlTextDidEndEditing(_ obj: Notification) { parent.onEditing(false) }
        @objc func submit(_ sender: Any?) { parent.onSubmit() }
    }
}

// MARK: - Overlay

struct HUDView: View {
    @ObservedObject var store: PRStore
    @ObservedObject var vibecoders: VibecodersStore
    @ObservedObject var hud: HUDState = HUDState()
    var onClose: () -> Void = {}
    /// Fired when the username field gains/loses focus: the overlay is a
    /// nonactivating panel, so the app must activate itself to take typing,
    /// and the overlay must stay up while typing even if Right Shift releases.
    var onUsernameEditing: (Bool) -> Void = { _ in }
    /// Corner-drag resize, forwarded to the panel.
    var onResize: (CGSize) -> Void = { _ in }
    var onResizeEnded: () -> Void = {}

    @State private var tab: Tab = .open
    @State private var showStale: Bool = false
    @State private var staleHovered: Bool = false
    @State private var usernameDraft = ""
    private enum Tab { case open, train, merged, crew }

    private static let staleThreshold: TimeInterval = 14 * 86400

    private func isStale(_ pr: PR) -> Bool {
        let last = pr.updatedAt ?? pr.lastCommitAt ?? .distantPast
        return Date().timeIntervalSince(last) > Self.staleThreshold
    }

    private var freshPRs: [PR] { store.prs.filter { !isStale($0) } }
    private var stalePRs: [PR] { store.prs.filter { isStale($0) } }
    private var trainCandidateCount: Int { store.trainGroups.reduce(0) { $0 + $1.prs.count } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                tabBar
                if let err = store.errorText {
                    banner(err, color: Tokyo.orange, icon: "exclamationmark.triangle.fill")
                }
                Rectangle().fill(Tokyo.line).frame(height: 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(tab)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.16), value: tab)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !store.runs.isEmpty {
                Rectangle().fill(Tokyo.line).frame(width: 1)
                RunsColumn(store: store).frame(width: 240)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [Tokyo.bg.opacity(0.97), Tokyo.bgDark.opacity(0.98)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Tokyo.border.opacity(0.9), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 30, y: 14)
        .padding(HUDMetrics.padding)
        .tint(Tokyo.blue)
        .foregroundStyle(Tokyo.fg)
        .preferredColorScheme(.dark)
    }

    private func banner(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(text).lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(color.opacity(0.28)))
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var reviewingCount: Int { store.prs.filter { $0.reviewing }.count }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "eyes")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tokyo.blue)
                .frame(width: 34, height: 34)
                .background(Tokyo.blue.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Tokyo.blue.opacity(0.30)))
            Text("Greptile Reviews")
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if !store.prs.isEmpty {
                Text("\(store.prs.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Tokyo.fgDim)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Tokyo.surface(1), in: Capsule())
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if reviewingCount > 0 {
                HStack(spacing: 5) {
                    Spinner(size: 10, color: Tokyo.blue)
                    Text("\(reviewingCount) active")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokyo.blue)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Tokyo.blue.opacity(0.14), in: Capsule())
                .fixedSize()
            }
            clock
            latchIndicator
            iconButton(store.refreshing ? nil : "arrow.clockwise", help: "Refresh now") {
                Task { await store.refresh(force: true) }
            }
            .disabled(store.refreshing)
            iconButton("xmark", help: "Close", action: onClose)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    /// Wall clock + last-sync age. The seconds tick live so the HUD reads as
    /// something running, not a screenshot.
    private var clock: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { ctx in
            VStack(alignment: .trailing, spacing: 1) {
                Text(HUDClock.time.string(from: ctx.date))
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(Tokyo.cyan)
                    .monospacedDigit()
                Text(syncLine(ctx.date))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Tokyo.comment)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Tokyo.bgDark.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Tokyo.border.opacity(0.6)))
            .help("Local time · \(HUDClock.date.string(from: ctx.date))")
        }
        .fixedSize()
    }

    /// Shows the hold-to-latch progress while Right Shift is down, then stays as
    /// a lit pin once the overlay is latched open. Hidden the rest of the time.
    @ViewBuilder private var latchIndicator: some View {
        if hud.pinned {
            // One click drops the latch — unpinning is never a hold.
            Button(action: onClose) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Tokyo.magenta)
                    .frame(width: 30, height: 30)
                    .background(Tokyo.magenta.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Tokyo.magenta.opacity(0.4)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Latched open — click or press Esc to close")
        } else if let start = hud.holdStartedAt {
            TimelineView(.animation) { ctx in
                let p = min(1, max(0, ctx.date.timeIntervalSince(start) / HUDState.latchDelay))
                ZStack {
                    Circle().strokeBorder(Tokyo.border.opacity(0.5), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: p)
                        .stroke(Tokyo.magenta, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "pin")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(p >= 1 ? Tokyo.magenta : Tokyo.comment)
                }
                .frame(width: 26, height: 26)
                .frame(width: 30, height: 30)
            }
            .help("Keep holding Right ⇧ to latch the HUD open")
        }
    }

    private func syncLine(_ now: Date) -> String {
        guard let d = store.lastRefresh else { return "no sync yet" }
        let s = Int(now.timeIntervalSince(d))
        if s < 5 { return "synced now" }
        if s < 60 { return "synced \(s)s ago" }
        return "synced \(s / 60)m ago"
    }

    private func iconButton(_ symbol: String?, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol) }
                else { Spinner(size: 12, color: Tokyo.comment) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Tokyo.fgDim)
            .frame(width: 30, height: 30)
            .background(Tokyo.surface(1), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Tokyo.stroke()))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Thin Bebop send-off bar with the session clock.
    private var footer: some View {
        HStack(spacing: 8) {
            Text(Bebop.signoff)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .kerning(1.6)
                .foregroundStyle(Tokyo.comment.opacity(0.85))
                .fixedSize()
            Spacer(minLength: 6)
            Text(Bebop.sessionTitle)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(Tokyo.comment.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 6)
            TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                Text("UPTIME \(hudDuration(HUDClock.launchedAt, ctx.date))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Tokyo.comment.opacity(0.85))
                    .monospacedDigit()
            }
            ResizeGrip(onChanged: onResize, onEnded: onResizeEnded)
        }
        .padding(.leading, 16).padding(.trailing, 4)
        .frame(height: 22)
        .background(Tokyo.bgDark.opacity(0.55))
        .overlay(Rectangle().fill(Tokyo.line).frame(height: 1), alignment: .top)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .open:   openContent
        case .train:  TrainTab(store: store)
        case .merged: mergedContent
        case .crew:   crewContent
        }
    }

    // Segmented Open / Train / Merged / Crew switcher for the main list.
    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton("Open", icon: "arrow.triangle.branch", count: store.prs.count, on: tab == .open) {
                tab = .open
            }
            tabButton("Train", icon: "tram.fill", count: trainCandidateCount, on: tab == .train,
                      accent: Tokyo.teal) {
                tab = .train
            }
            tabButton("Merged", icon: "arrow.triangle.merge", count: store.merged.count, on: tab == .merged) {
                tab = .merged
            }
            tabButton("Crew", icon: "person.3", count: vibecoders.online.count, on: tab == .crew,
                      accent: Tokyo.magenta) {
                tab = .crew
            }
        }
        .padding(4)
        .background(Tokyo.bgDark.opacity(0.75), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Tokyo.stroke()))
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func tabButton(_ label: String, icon: String, count: Int, on: Bool,
                           accent: Color = Tokyo.blue,
                           _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(on ? accent : Tokyo.comment)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(on ? accent.opacity(0.18) : Tokyo.surface(0), in: Capsule())
            }
            .foregroundStyle(on ? accent : Tokyo.comment)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(on ? accent.opacity(0.13) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(on ? accent.opacity(0.35) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(label.lowercased())")
    }

    @ViewBuilder private var openContent: some View {
        if store.prs.isEmpty && store.refreshing {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { _ in PRCardSkeleton() }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.prs.isEmpty {
            emptyState(icon: "checkmark.seal", text: "No open PRs", sub: "The gate is clear, cowboy.")
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(freshPRs) { pr in
                        PRCard(pr: pr, store: store)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)),
                                                    removal: .opacity))
                    }
                    if !stalePRs.isEmpty {
                        staleDisclosure
                        if showStale {
                            ForEach(stalePRs) { pr in PRCard(pr: pr, store: store) }
                        }
                    }
                }
                .padding(12)
                .animation(.easeInOut(duration: 0.22), value: store.prs.map(\.id))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var staleDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showStale.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "archivebox")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20)
                Text("Stale pull requests")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(stalePRs.count)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Tokyo.surface(1), in: Capsule())
                Spacer()
                Text(showStale ? "Hide" : "Show")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(showStale ? 90 : 0))
            }
            .foregroundStyle(Tokyo.comment)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(Tokyo.surface(staleHovered ? 1 : 0),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Tokyo.stroke(staleHovered)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { staleHovered = $0 }
        .help(showStale ? "Hide stale pull requests" : "Show stale pull requests")
    }

    @ViewBuilder private var mergedContent: some View {
        if store.merged.isEmpty && store.refreshing {
            ScrollView {
                VStack(spacing: 8) { ForEach(0..<3, id: \.self) { _ in PRCardSkeleton() } }
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.merged.isEmpty {
            emptyState(icon: "tray", text: "No recent merges", sub: nil)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.merged) { m in MergedRow(pr: m) }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyState(icon: String, text: String, sub: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Tokyo.comment)
                .frame(width: 48, height: 48)
                .background(Tokyo.surface(0), in: Circle())
                .overlay(Circle().strokeBorder(Tokyo.stroke()))
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokyo.fgDim)
            if let sub {
                Text(sub)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Tokyo.comment)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Crew tab (vibecoders)

    @ViewBuilder private var crewContent: some View {
        if !vibecoders.hasUsername {
            VStack(spacing: 14) {
                Image(systemName: "person.3")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Tokyo.magenta)
                    .frame(width: 56, height: 56)
                    .background(Tokyo.magenta.opacity(0.13), in: Circle())
                Text("Join the vibecoders leaderboard")
                    .font(.system(size: 14, weight: .semibold))
                Text("Pick a username and your devtime starts counting the moment\nan editor is open. No GitHub sign-in, no tokens — we trust you.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokyo.comment)
                    .multilineTextAlignment(.center)
                UsernameField(text: $usernameDraft,
                              onEditing: onUsernameEditing,
                              onSubmit: { vibecoders.setUsername(usernameDraft) })
                    .frame(width: 220, height: 36)
                    .padding(.horizontal, 8)
                    .background(Tokyo.bgDark.opacity(0.8), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Tokyo.stroke(true)))
                Button {
                    vibecoders.setUsername(usernameDraft)
                } label: {
                    Text("Join the crew")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokyo.bgDark)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Tokyo.magenta,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let err = vibecoders.errorText {
                    Text(err).font(.system(size: 11)).foregroundStyle(Tokyo.orange)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                crewHeader
                Rectangle().fill(Tokyo.line).frame(height: 1)
                if vibecoders.selectedProfileLogin != nil {
                    crewProfileContent
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            onlineStrip
                            leaderboardBlock
                        }
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var crewHeader: some View {
        HStack(spacing: 10) {
            Text(String(vibecoders.username.prefix(1)).uppercased())
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Tokyo.magenta)
                .frame(width: 30, height: 30)
                .background(Tokyo.magenta.opacity(0.17), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("@\(vibecoders.username)")
                    .font(.system(size: 13, weight: .bold))
                if let name = vcDisplayName(vibecoders.user?.name) {
                    Text(name)
                        .font(.system(size: 10)).foregroundStyle(Tokyo.comment)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tokyo.magenta)
                Text("\(vcDuration(vibecoders.devtimeToday)) today")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Tokyo.magenta.opacity(0.14), in: Capsule())
            .help(vibecoders.todayPeriodDescription)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var onlineStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionLabel("Online now")
                if !vibecoders.online.isEmpty {
                    Circle().fill(Tokyo.green).frame(width: 6, height: 6)
                }
                Spacer()
            }
            if vibecoders.online.isEmpty {
                Text("Nobody vibing right now — first heartbeat within 5 minutes of launching an editor counts.")
                    .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vibecoders.online, id: \.login) { u in
                            Button {
                                vibecoders.showProfile(login: u.login)
                            } label: {
                                HStack(spacing: 7) {
                                    Circle().fill(Tokyo.green).frame(width: 7, height: 7)
                                    Text(vcDisplayName(u.name) ?? u.login)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1).truncationMode(.tail)
                                    Text(vcDuration(u.devtimeToday))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Tokyo.comment).monospacedDigit()
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(minHeight: 32)
                                .background(Tokyo.surface(1),
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("View @\(u.login)'s profile")
                        }
                    }
                }
            }
        }
        .padding(11)
        .background(Tokyo.surface(0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Tokyo.stroke()))
    }

    private var leaderboardBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionLabel("Leaderboard")
                Spacer(minLength: 4)
                crewPeriodPicker
            }
            if vibecoders.boardRefreshing {
                IndeterminateBar(color: Tokyo.magenta)
            }
            if let range = vibecoders.leaderboardPeriodRange {
                periodRangeLabel(range, help: vibecoders.leaderboardPeriodDescription)
            }
            if vibecoders.board.isEmpty {
                Text("No devtime yet — open an editor and the minutes start stacking.")
                    .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 18)
            } else {
                VStack(spacing: 6) {
                    ForEach(vibecoders.board.prefix(10), id: \.login) { e in
                        CrewRow(entry: e) { vibecoders.showProfile(login: e.login) }
                    }
                }
            }
            if let err = vibecoders.errorText {
                Text(err).font(.system(size: 10)).foregroundStyle(Tokyo.orange)
            }
        }
        .padding(11)
        .background(Tokyo.surface(0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Tokyo.stroke()))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .textCase(.uppercase)
            .foregroundStyle(Tokyo.comment)
            .kerning(1.2)
    }

    @ViewBuilder private var crewProfileContent: some View {
        if let profile = vibecoders.crewProfile {
            ScrollView {
                crewProfileCard(profile)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vibecoders.profileLoading {
            VStack(spacing: 12) {
                Spinner(size: 18, color: Tokyo.magenta)
                Text("Loading profile…")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokyo.fgDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Text(vibecoders.profileError ?? "Couldn’t load this profile")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokyo.orange)
                Button("Back") { vibecoders.dismissProfile() }
                    .buttonStyle(.plain).foregroundStyle(Tokyo.magenta)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func crewProfileCard(_ profile: VCCrewProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(String(profile.user.login.prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Tokyo.magenta)
                    .frame(width: 42, height: 42)
                    .background(Tokyo.magenta.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(vcDisplayName(profile.user.name) ?? profile.user.login)
                        .font(.system(size: 16, weight: .bold))
                    Text("@\(profile.user.login)")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Tokyo.comment)
                }
                Spacer()
                Button { vibecoders.dismissProfile() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Tokyo.fgDim)
                        .frame(width: 30, height: 30)
                        .background(Tokyo.surface(1), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).help("Back to Crew")
            }

            HStack(spacing: 10) {
                profileMetric(profile.period.profileLabel, vcDuration(profile.devtimePeriod), icon: "calendar")
                profileMetric("All time", vcDuration(profile.devtimeAll), icon: "clock.fill")
            }

            VStack(alignment: .leading, spacing: 10) {
                profileDetail("Status", profile.online ? "Online now" : "Offline",
                              icon: profile.online ? "circle.fill" : "moon.fill",
                              tone: profile.online ? Tokyo.green : Tokyo.comment)
                if let lastSeen = profile.user.lastSeen {
                    profileDetail("Last online", lastSeen.formatted(date: .abbreviated, time: .shortened),
                                  icon: "clock.arrow.circlepath", tone: Tokyo.cyan)
                }
                if let joined = profile.user.createdAt {
                    profileDetail("Joined", joined.formatted(date: .long, time: .omitted),
                                  icon: "calendar", tone: Tokyo.magenta)
                }
            }
            .padding(14)
            .background(Tokyo.surface(0), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokyo.stroke()))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionLabel("Sprints")
                    Spacer()
                    Text("\(profile.sprints.count)")
                        .font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Tokyo.magenta)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Tokyo.magenta.opacity(0.14), in: Capsule())
                }
                HStack(spacing: 8) {
                    crewPeriodPicker
                    if vibecoders.profileLoading {
                        Spinner(size: 11, color: Tokyo.magenta)
                    }
                }
                if let range = vcPeriodRange(start: profile.periodStart, end: profile.periodEnd) {
                    periodRangeLabel(range,
                                     help: vcExactPeriodDescription(profile.period.profileLabel,
                                                                    start: profile.periodStart,
                                                                    end: profile.periodEnd))
                }
                if vibecoders.profileLoading {
                    IndeterminateBar(color: Tokyo.magenta)
                }
                SprintMap(period: profile.period,
                          sprints: profile.sprints,
                          periodStart: profile.periodStart,
                          periodEnd: profile.periodEnd)
                if profile.sprints.isEmpty {
                    Text("No sprint history for this period yet. Sessions begin appearing after the first activity heartbeat.")
                        .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 6) {
                        ForEach(profile.sprints) { sprint in
                            sprintRow(sprint)
                        }
                    }
                }
            }
            .padding(14)
            .background(Tokyo.surface(0), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokyo.stroke()))
        }
        .padding(16)
        .background(Tokyo.bgDark.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Tokyo.stroke(true)))
    }

    private func profileMetric(_ label: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokyo.magenta)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Tokyo.comment)
                Text(value).font(.system(size: 15, weight: .bold)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(Tokyo.magenta.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
    }

    private var crewPeriodPicker: some View {
        HStack(spacing: 2) {
            ForEach(VCLeaderboardPeriod.allCases) { period in
                Button {
                    vibecoders.selectLeaderboardPeriod(period)
                } label: {
                    Text(period.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(vibecoders.leaderboardPeriod == period ? Tokyo.magenta : Tokyo.comment)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(vibecoders.leaderboardPeriod == period ? Tokyo.magenta.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Tokyo.surface(1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .help(vibecoders.leaderboardPeriodDescription)
    }

    private func periodRangeLabel(_ text: String, help: String) -> some View {
        Label(text, systemImage: "calendar")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Tokyo.comment)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(help)
    }

    private func profileDetail(_ label: String, _ value: String, icon: String, tone: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tone).frame(width: 16)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokyo.comment)
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
    }

    private func sprintRow(_ sprint: VCSprint) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 2) {
                Circle()
                    .fill(sprint.active ? Tokyo.green : Tokyo.magenta)
                    .frame(width: 8, height: 8)
                Capsule().fill(Tokyo.line).frame(width: 2, height: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(sprint.startedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokyo.comment)
                Text("\(sprint.startedAt.formatted(date: .omitted, time: .shortened)) – \(sprintEndLabel(sprint))")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(vcDuration(sprint.durationSeconds))
                    .font(.system(size: 12, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Tokyo.magenta)
                if sprint.active {
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(Tokyo.green)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(Tokyo.surface(1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func sprintEndLabel(_ sprint: VCSprint) -> String {
        if Calendar.current.isDate(sprint.startedAt, inSameDayAs: sprint.endedAt) {
            return sprint.endedAt.formatted(date: .omitted, time: .shortened)
        }
        return sprint.endedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Sprint activity map (UTC, matching Crew period boundaries)

struct SprintMap: View {
    let period: VCLeaderboardPeriod
    let sprints: [VCSprint]
    let periodStart: Date?
    let periodEnd: Date?

    private static var utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private var bounds: (start: Date, end: Date) {
        let calendar = Self.utcCalendar
        let fallbackStart = calendar.startOfDay(for: Date())
        let start = periodStart ?? fallbackStart
        let fallbackEnd: Date
        switch period {
        case .today: fallbackEnd = calendar.date(byAdding: .day, value: 1, to: start)!
        case .week: fallbackEnd = calendar.date(byAdding: .day, value: 7, to: start)!
        case .month: fallbackEnd = calendar.date(byAdding: .month, value: 1, to: start)!
        }
        return (start, periodEnd ?? fallbackEnd)
    }

    private var days: [Date] {
        var result: [Date] = []
        var day = bounds.start
        while day < bounds.end, result.count < 31 {
            result.append(day)
            day = Self.utcCalendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(period == .month ? "DAILY ACTIVITY" : "HOURLY ACTIVITY")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Tokyo.comment)
                    .kerning(0.8)
                Spacer()
                Text("UTC")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Tokyo.comment)
            }
            if period == .month {
                monthGrid
            } else {
                hourlyGrid
            }
        }
        .padding(10)
        .background(Tokyo.bgDark.opacity(0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Tokyo.stroke()))
    }

    private var hourlyGrid: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                Color.clear.frame(width: 34, height: 1)
                Text("00").frame(maxWidth: .infinity, alignment: .leading)
                Text("06").frame(maxWidth: .infinity)
                Text("12").frame(maxWidth: .infinity)
                Text("18").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 8, weight: .medium)).foregroundStyle(Tokyo.comment)
            ForEach(days, id: \.self) { day in
                HStack(spacing: 3) {
                    Text(dayLabel(day))
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Tokyo.comment)
                        .frame(width: 34, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        let start = Self.utcCalendar.date(byAdding: .hour, value: hour, to: day)!
                        let seconds = activeSeconds(from: start,
                                                    to: Self.utcCalendar.date(byAdding: .hour, value: 1, to: start)!)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(activityColor(seconds: seconds, maximum: 3600))
                            .frame(maxWidth: .infinity, minHeight: 10, maxHeight: 10)
                            .help("\(hourLabel(start)): \(vcDuration(Int64(seconds))) active")
                    }
                }
            }
        }
    }

    private var monthGrid: some View {
        let leading = max(0, Self.utcCalendar.component(.weekday, from: bounds.start) - 1)
        let cells = Array(repeating: Optional<Date>.none, count: leading) + days.map(Optional.some)
        let columns = Array(repeating: GridItem(.fixed(14), spacing: 5), count: 7)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, label in
                    Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(Tokyo.comment)
                        .frame(width: 14)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let next = Self.utcCalendar.date(byAdding: .day, value: 1, to: day)!
                        let seconds = activeSeconds(from: day, to: next)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(activityColor(seconds: seconds, maximum: 8 * 3600))
                            .frame(width: 14, height: 14)
                            .help("\(fullDayLabel(day)): \(vcDuration(Int64(seconds))) active")
                    } else {
                        Color.clear.frame(width: 14, height: 14)
                    }
                }
            }
        }
    }

    private func activeSeconds(from start: Date, to end: Date) -> TimeInterval {
        min(end.timeIntervalSince(start), sprints.reduce(0) { total, sprint in
            total + max(0, min(end, sprint.endedAt).timeIntervalSince(max(start, sprint.startedAt)))
        })
    }

    private func activityColor(seconds: TimeInterval, maximum: TimeInterval) -> Color {
        guard seconds > 0 else { return Tokyo.surface(1) }
        let intensity = min(1, seconds / maximum)
        return Tokyo.magenta.opacity(0.22 + intensity * 0.70)
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = period == .today ? "MMM d" : "EEE"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func fullDayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func hourLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm 'UTC'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

/// Overlay state the app delegate drives and the HUD reacts to: whether the
/// panel is latched open, and how long Right Shift has been held (the latch
/// fills over `latchDelay`).
@MainActor
final class HUDState: ObservableObject {
    /// Hold Right Shift this long and the overlay stays up after you let go.
    /// Short enough to feel like a deliberate press, long enough that a normal
    /// peek never trips it.
    static let latchDelay: TimeInterval = 1.2

    @Published var pinned = false
    @Published var holdStartedAt: Date?
}

/// Formatters + launch stamp for the HUD clock, built once.
enum HUDClock {
    static let launchedAt = Date()
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()
}

// MARK: - One PR row

struct PRCard: View {
    let pr: PR
    @ObservedObject var store: PRStore
    @State private var hovered = false
    /// Merging is irreversible, so the button arms on the first click and only
    /// fires on the second (auto-disarming after a few seconds).
    @State private var mergeArmed = false
    @State private var disarmTask: Task<Void, Never>?

    /// The one color that tells the whole story at a glance.
    private var statusColor: Color { pr.reviewing ? Tokyo.blue : scoreColor }

    var body: some View {
        HStack(spacing: 12) {
            Capsule().fill(statusColor).frame(width: 4, height: 42)
            scoreBlock
            VStack(alignment: .leading, spacing: 5) {
                Text(pr.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Tokyo.fgDim).lineLimit(1)
                    Text("#\(pr.number)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokyo.comment)
                    if let rc = pr.reviewCount {
                        Text("\(rc) review\(rc == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Tokyo.comment)
                            .help("\(rc) Greptile review\(rc == 1 ? "" : "s")")
                    }
                    if pr.reviewing { reviewingPill }
                    if let why = pr.mergeBlockReason, !pr.reviewing { blockPill(why) }
                }
                freshnessLine
            }
            Spacer(minLength: 8)
            if pr.canQuickMerge { mergeButton }
            rereviewButton
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(Tokyo.surface(hovered ? 1 : 0),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { openWebURL(pr.url) }
        .onHover { hovered = $0 }
        .help(pr.url)
        .onDisappear { disarmTask?.cancel() }
    }

    private var borderColor: Color {
        if pr.reviewing { return Tokyo.blue.opacity(0.38) }
        if pr.canQuickMerge { return Tokyo.green.opacity(0.32) }
        return Tokyo.stroke()
    }

    // Big, bold score — the primary thing your eye lands on.
    private var scoreBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(scoreColor.opacity(0.14))
            if pr.hasScore {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(pr.scoreNum ?? 0)")
                        .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(scoreColor)
                    Text("/\(pr.scoreDen ?? 5)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(scoreColor.opacity(0.72))
                }
            } else if pr.reviewing {
                Spinner(size: 20, color: Tokyo.blue)
            } else {
                Text("—").font(.system(size: 22, weight: .bold)).foregroundStyle(Tokyo.comment)
            }
        }
        .frame(width: 56, height: 48)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(scoreColor.opacity(0.30)))
    }

    private var reviewingPill: some View {
        HStack(spacing: 5) {
            Spinner(size: 10, color: Tokyo.blue)
            if let since = pr.reviewingSince {
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    Text(hudDuration(since, ctx.date))
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokyo.blue)
                        .monospacedDigit()
                }
            } else {
                Text("reviewing").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokyo.blue)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Tokyo.blue.opacity(0.14), in: Capsule())
    }

    private func blockPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Tokyo.orange)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Tokyo.orange.opacity(0.13), in: Capsule())
            .help("GitHub won’t merge this right now: \(text)")
    }

    // Push/review recency — when the PR last got a commit and when Greptile last reviewed.
    @ViewBuilder private var freshnessLine: some View {
        if pr.lastCommitAt != nil || pr.lastReviewAt != nil {
            HStack(spacing: 8) {
                if let c = pr.lastCommitAt {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 9))
                        Text("Pushed \(hudAgo(c)) ago").font(.system(size: 10))
                    }
                    .foregroundStyle(Tokyo.comment)
                }
                if let r = pr.lastReviewAt {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 9))
                        Text("Reviewed \(hudAgo(r)) ago").font(.system(size: 10))
                    }
                    .foregroundStyle(Tokyo.comment)
                }
            }
        }
    }

    /// Only shown on a perfect Greptile score that GitHub will actually accept.
    private var mergeButton: some View {
        Button {
            if pr.merging { return }
            if mergeArmed {
                disarmTask?.cancel()
                mergeArmed = false
                Task { await store.merge(pr) }
            } else {
                mergeArmed = true
                disarmTask?.cancel()
                disarmTask = Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if !Task.isCancelled { mergeArmed = false }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if pr.merging {
                    Spinner(size: 11, color: Tokyo.bgDark)
                } else {
                    Image(systemName: mergeArmed ? "exclamationmark.circle.fill" : "arrow.triangle.merge")
                        .font(.system(size: 11, weight: .bold))
                }
                Text(pr.merging ? "Merging" : (mergeArmed ? "Confirm" : "Merge"))
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(Tokyo.bgDark)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(mergeArmed ? Tokyo.orange : Tokyo.green,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pr.merging)
        .help(mergeArmed
              ? "Click again to squash-merge #\(pr.number)"
              : "Perfect \(pr.scoreNum ?? 5)/\(pr.scoreDen ?? 5) — squash-merge #\(pr.number)")
    }

    private var rereviewButton: some View {
        Button {
            Task { await store.triggerReview(pr) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Tokyo.surface(1)).frame(width: 34, height: 34)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Tokyo.stroke()).frame(width: 34, height: 34)
                if pr.triggering {
                    Spinner(size: 16, color: Tokyo.fgDim)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokyo.fgDim)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(pr.triggering)
        .help("Re-trigger Greptile (posts “@greptile”)")
    }

    private var scoreColor: Color {
        guard let n = pr.scoreNum, let d = pr.scoreDen, d > 0 else { return Tokyo.comment }
        let r = Double(n) / Double(d)
        if r >= 1.0 { return Tokyo.green }
        if r >= 0.8 { return Tokyo.teal }
        if r >= 0.6 { return Tokyo.yellow }
        if r >= 0.4 { return Tokyo.orange }
        return Tokyo.red
    }
}

// MARK: - Merge train tab

/// Combine several compatible PRs into one branch and one pull request, so a
/// deploy pipeline runs once instead of once per merge.
struct TrainTab: View {
    @ObservedObject var store: PRStore

    private var groups: [TrainGroup] { store.trainGroups }
    private var selected: [PR] { store.selectedPRs }
    private var conflicts: [TrainConflict] { store.selectionConflicts }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Rectangle().fill(Tokyo.line).frame(height: 1)
            // A stack that already exists stays visible (and flattenable) even once
            // there's nothing left to build from. So does a train in motion.
            if groups.isEmpty && store.detectedStacks.isEmpty
                && store.activeTrains.isEmpty && store.trainResult == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if let r = store.trainResult { resultCard(r) }
                        ForEach(store.activeTrains) { t in activeTrainCard(t) }
                        if let n = store.trainNotice { noticeCard(n) }
                        if let n = store.stackNotice { noticeCard(n) }
                        if let e = store.trainError { errorCard(e) }
                        ForEach(store.detectedStacks) { st in stackCard(st) }
                        if !conflicts.isEmpty { conflictCard }
                        if store.trainMode == .stack && selected.count >= 2 { stackOrderCard }
                        ForEach(groups) { group in groupBlock(group) }
                    }
                    .padding(12)
                    .animation(.easeInOut(duration: 0.2), value: store.trainSelection)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "tram.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokyo.teal)
                    .frame(width: 28, height: 28)
                    .background(Tokyo.teal.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Merge train").font(.system(size: 13, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Tokyo.comment)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                modeSwitch
            }
            HStack(spacing: 8) {
                pillButton("Smart select", icon: "wand.and.stars", tone: Tokyo.cyan,
                           help: "Pick the largest set of PRs on one base branch that don’t touch the same files") {
                    store.smartSelectTrain()
                }
                .disabled(groups.isEmpty || store.trainBuilding)
                if !selected.isEmpty {
                    pillButton("Clear", icon: "xmark", tone: Tokyo.comment, help: "Clear the selection") {
                        store.clearTrainSelection()
                    }
                    .disabled(store.trainBuilding)
                }
                Spacer(minLength: 4)
                buildButton
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var subtitle: String {
        if selected.isEmpty {
            return store.trainMode == .stack
                ? "Chain PRs into a GitHub stack — one landing, reviews intact"
                : "Merge PRs onto one branch — always a single pipeline"
        }
        return "\(selected.count) selected · \(uniqueFileCount) files touched"
    }

    /// Stack (native GitHub chain) vs Combine (one throwaway branch).
    private var modeSwitch: some View {
        HStack(spacing: 3) {
            ForEach(PRStore.TrainMode.allCases, id: \.rawValue) { mode in
                Button { store.trainMode = mode } label: {
                    Text(mode.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(store.trainMode == mode ? Tokyo.teal : Tokyo.comment)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(store.trainMode == mode ? Tokyo.teal.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode == .stack
                      ? "Point each PR at the one below it — GitHub's stacked pull requests"
                      : "Merge everything onto one new branch and open a single combined PR")
            }
        }
        .padding(3)
        .background(Tokyo.bgDark.opacity(0.8), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tokyo.stroke()))
        .disabled(store.trainBuilding)
    }

    private var uniqueFileCount: Int {
        Set(selected.flatMap(\.changedFiles)).count
    }

    private func pillButton(_ label: String, icon: String, tone: Color, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(tone)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tone.opacity(0.3)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// File overlap blocks a Combine (it merges immediately, so a clash is fatal)
    /// but only warns for a Stack — nothing is merged when stacking, and GitHub
    /// reports each layer's mergeability afterwards.
    private var canBuild: Bool {
        guard selected.count >= 2, !store.trainBuilding else { return false }
        return store.trainMode == .stack || conflicts.isEmpty
    }

    private var buildButton: some View {
        Button {
            Task {
                if store.trainMode == .stack { await store.buildStack() }
                else { await store.buildTrain() }
            }
        } label: {
            HStack(spacing: 6) {
                if store.trainBuilding { Spinner(size: 11, color: Tokyo.bgDark) }
                else {
                    Image(systemName: store.trainMode == .stack
                          ? "square.3.layers.3d.top.filled" : "arrow.triangle.merge")
                        .font(.system(size: 11, weight: .bold))
                }
                Text(buildLabel)
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(canBuild ? Tokyo.bgDark : Tokyo.comment)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(canBuild ? Tokyo.teal : Tokyo.surface(1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(canBuild ? .clear : Tokyo.stroke()))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canBuild)
        .help(buildHelp)
    }

    private var buildLabel: String {
        if store.trainBuilding { return store.trainMode == .stack ? "Stacking…" : "Building…" }
        let n = selected.count >= 2 ? " (\(selected.count))" : ""
        return store.trainMode == .stack ? "Stack\(n)" : "Build train\(n)"
    }

    private var buildHelp: String {
        if selected.count < 2 { return "Select at least two pull requests" }
        if store.trainMode == .stack {
            return "Point each PR at the one below it, highest confidence at the bottom. Nothing merges — this only changes base branches, and Flatten undoes it."
        }
        return conflicts.isEmpty
            ? "Cut a branch, merge every selected PR into it, and open one combined pull request"
            : "Resolve the file overlaps first"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tram.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Tokyo.comment)
                .frame(width: 48, height: 48)
                .background(Tokyo.surface(0), in: Circle())
                .overlay(Circle().strokeBorder(Tokyo.stroke()))
            Text("No train to run")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokyo.fgDim)
            Text("Needs two or more mergeable PRs on the same repo and base branch.")
                .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func groupBlock(_ group: TrainGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokyo.teal)
                Text(group.repo.split(separator: "/").last.map(String.init) ?? group.repo)
                    .font(.system(size: 12, weight: .bold))
                Text("→ \(group.base)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Tokyo.comment)
                Spacer(minLength: 4)
                Text("\(group.prs.count) candidates")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokyo.comment)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Tokyo.surface(1), in: Capsule())
            }
            VStack(spacing: 6) {
                ForEach(group.prs) { pr in
                    TrainRow(pr: pr,
                             selected: store.trainSelection.contains(pr.id),
                             clash: clashLabel(for: pr),
                             toggle: { store.toggleTrainSelection(pr) })
                }
            }
        }
        .padding(11)
        .background(Tokyo.surface(0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Tokyo.stroke()))
    }

    /// If this (unselected) PR would collide with the current selection, say so
    /// up front rather than letting the build discover it.
    private func clashLabel(for pr: PR) -> String? {
        guard !store.trainSelection.contains(pr.id) else { return nil }
        var files = 0
        var with: Int?
        for other in selected {
            let shared = store.overlap(pr, other)
            if !shared.isEmpty {
                files += shared.count
                if with == nil { with = other.number }
            }
        }
        guard let with else { return nil }
        return "shares \(files) file\(files == 1 ? "" : "s") with #\(with)"
    }

    private var conflictCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .bold))
                Text(store.trainMode == .stack
                     ? "Overlapping files — these layers may conflict"
                     : "These can’t ride together")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Tokyo.orange)
            ForEach(conflicts) { c in
                Text("\(shortID(c.a)) ↔ \(shortID(c.b)) — \(c.reason): \(c.paths.prefix(3).joined(separator: ", "))\(c.paths.count > 3 ? "…" : "")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokyo.fgDim)
                    .lineLimit(1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokyo.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Tokyo.orange.opacity(0.3)))
    }

    /// A stack that already exists on GitHub, drawn bottom-up the way the merge
    /// box shows it.
    private func stackCard(_ stack: PRStack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "square.3.layers.3d.top.filled")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokyo.teal)
                Text("Stack of \(stack.prs.count)").font(.system(size: 12, weight: .bold))
                Text("→ \(stack.trunk)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Tokyo.comment)
                Spacer(minLength: 4)
                if let top = stack.top {
                    pillButton("Top PR", icon: "arrow.up.forward", tone: Tokyo.teal,
                               help: "Open #\(top.number) — merge from here to land the stack bottom-up") {
                        openWebURL(top.url)
                    }
                }
                pillButton("Flatten", icon: "arrow.down.right.and.arrow.up.left", tone: Tokyo.comment,
                           help: "Point every PR back at \(stack.trunk)") {
                    Task { await store.flatten(stack) }
                }
                .disabled(store.trainBuilding)
            }
            // Top of the stack first, mirroring GitHub's stack map.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stack.prs.enumerated().reversed()), id: \.element.id) { idx, pr in
                    HStack(spacing: 8) {
                        Text("\(idx + 1)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Tokyo.comment)
                            .frame(width: 14)
                        Rectangle().fill(Tokyo.teal.opacity(0.5)).frame(width: 2, height: 20)
                        Text("#\(pr.number)")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(Tokyo.teal)
                        Text(pr.title)
                            .font(.system(size: 11)).foregroundStyle(Tokyo.fgDim).lineLimit(1)
                        if let why = pr.mergeBlockReason {
                            Text(why)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Tokyo.orange)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Tokyo.orange.opacity(0.13), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { openWebURL(pr.url) }
                }
                HStack(spacing: 8) {
                    Text("").frame(width: 14)
                    Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Tokyo.comment).frame(width: 2)
                    Text(stack.trunk)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Tokyo.comment)
                }
                .padding(.top, 2)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokyo.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Tokyo.teal.opacity(0.28)))
    }

    /// Preview of the order the current selection would be stacked in.
    private var stackOrderCard: some View {
        let order = store.stackOrder
        return VStack(alignment: .leading, spacing: 5) {
            Text("Stack order — bottom lands first")
                .font(.system(size: 10, weight: .bold)).textCase(.uppercase)
                .foregroundStyle(Tokyo.comment).kerning(1.1)
            Text(order.map { "#\($0.number)" }.joined(separator: "  →  "))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Tokyo.teal)
                .lineLimit(2)
            Text("Highest Greptile score sits at the bottom. Nothing merges — stacking only re-points base branches, and Flatten undoes it.")
                .font(.system(size: 10)).foregroundStyle(Tokyo.comment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokyo.surface(0), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Tokyo.stroke()))
    }

    private func noticeCard(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 11, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Tokyo.teal)
        .padding(11)
        .background(Tokyo.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Tokyo.teal.opacity(0.3)))
    }

    private func shortID(_ id: String) -> String {
        "#" + (id.split(separator: "#").last.map(String.init) ?? id)
    }

    private func resultCard(_ r: TrainResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: r.state == .landed ? "checkmark.seal.fill" : "tram.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(r.state == .landed
                     ? "Train landed — \(r.mergedPRs.count) PR\(r.mergedPRs.count == 1 ? "" : "s"), one pipeline"
                     : "Train assembled — \(r.mergedPRs.count) PR\(r.mergedPRs.count == 1 ? "" : "s"), one pipeline")
                    .font(.system(size: 12, weight: .bold))
                Spacer(minLength: 4)
                if let train = store.activeTrain(for: r) {
                    Button {
                        Task { await store.mergeTrain(train) }
                    } label: {
                        HStack(spacing: 5) {
                            if r.state == .merging { Spinner(size: 11, color: Tokyo.bgDark) }
                            else {
                                Image(systemName: "arrow.triangle.merge")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            Text(r.state == .merging ? "Merging…" : "Merge train")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(Tokyo.bgDark)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Tokyo.green, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.trainBuilding || r.state != .assembled)
                    .help("Merge the combined PR now — source PRs close automatically when it lands")
                }
                if let url = r.url, !url.isEmpty {
                    Button { openWebURL(url) } label: {
                        Text(r.state == .landed ? "Open PR" : "Open")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Tokyo.green)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Tokyo.green.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Tokyo.green.opacity(0.35)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(Tokyo.green)
            Text(r.branch)
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Tokyo.comment)
            if !r.skipped.isEmpty {
                Text("Left behind: " + r.skipped.map { "#\($0.0) (\($0.1))" }.joined(separator: ", "))
                    .font(.system(size: 10)).foregroundStyle(Tokyo.orange)
            }
            if r.state == .landed {
                Text(r.closedPRs.isEmpty
                     ? "Source PRs are done — GitHub marked them merged along with the train."
                     : "Closed " + r.closedPRs.map { "#\($0)" }.joined(separator: ", ") + ".")
                    .font(.system(size: 10)).foregroundStyle(Tokyo.fgDim)
            } else if store.activeTrain(for: r) != nil {
                Text("One click merges the combined PR and closes every source PR — no trip to the browser.")
                    .font(.system(size: 10)).foregroundStyle(Tokyo.comment)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokyo.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Tokyo.green.opacity(0.3)))
    }

    /// A train built earlier whose combined PR is still open — kept across
    /// launches, still landable in one click.
    private func activeTrainCard(_ t: ActiveTrain) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "tram.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokyo.teal)
                Text("Open train #\(t.number)")
                    .font(.system(size: 12, weight: .bold))
                Text("\(t.prs.count) PR\(t.prs.count == 1 ? "" : "s") riding")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokyo.comment)
                Spacer(minLength: 4)
                if !t.url.isEmpty {
                    pillButton("Merge", icon: "arrow.triangle.merge", tone: Tokyo.green,
                               help: "Merge the combined PR now — source PRs close automatically when it lands") {
                        Task { await store.mergeTrain(t) }
                    }
                    .disabled(store.trainBuilding)
                    pillButton("Open", icon: "arrow.up.forward", tone: Tokyo.teal,
                               help: "Open #\(t.number)") { openWebURL(t.url) }
                }
            }
            Text(t.prs.map { "#\($0)" }.joined(separator: " + "))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokyo.teal)
            Text("\(t.repo) · \(t.branch) → \(t.base)")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(Tokyo.comment)
            if !t.skipped.isEmpty {
                Text("Left behind: " + t.skipped.joined(separator: ", "))
                    .font(.system(size: 10)).foregroundStyle(Tokyo.orange)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokyo.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Tokyo.teal.opacity(0.28)))
    }

    private func errorCard(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "xmark.octagon.fill").font(.system(size: 11, weight: .bold))
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(3)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Tokyo.red)
        .padding(11)
        .background(Tokyo.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Tokyo.red.opacity(0.3)))
    }
}

/// One selectable PR inside a train group.
struct TrainRow: View {
    let pr: PR
    let selected: Bool
    let clash: String?
    let toggle: () -> Void
    @State private var hovered = false

    private var scoreColor: Color {
        guard let n = pr.scoreNum, let d = pr.scoreDen, d > 0 else { return Tokyo.comment }
        let r = Double(n) / Double(d)
        if r >= 1.0 { return Tokyo.green }
        if r >= 0.8 { return Tokyo.teal }
        if r >= 0.6 { return Tokyo.yellow }
        return Tokyo.orange
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? Tokyo.teal : Tokyo.comment)
                Text(pr.hasScore ? "\(pr.scoreNum ?? 0)/\(pr.scoreDen ?? 5)" : "—/5")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreColor)
                    .frame(width: 32)
                    .padding(.vertical, 3)
                    .background(scoreColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("#\(pr.number)")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokyo.comment)
                        Text("\(pr.changedFiles.count) file\(pr.changedFiles.count == 1 ? "" : "s")")
                            .font(.system(size: 10)).foregroundStyle(Tokyo.comment)
                        if let clash {
                            Text(clash)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Tokyo.orange)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 6)
                Button { openWebURL(pr.url) } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokyo.comment)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open #\(pr.number) on GitHub")
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(selected ? Tokyo.teal.opacity(0.12) : Tokyo.surface(hovered ? 1 : 0),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Tokyo.teal.opacity(0.45)
                                       : (clash != nil ? Tokyo.orange.opacity(0.28) : Tokyo.stroke())))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(clash ?? "Add #\(pr.number) to the train")
    }
}

// MARK: - GitHub Actions column (CI you triggered, e.g. via merges)

struct RunsColumn: View {
    @ObservedObject var store: PRStore

    private var runningCount: Int { store.runs.filter { $0.isRunning }.count }
    private var othersRunning: Int { store.runs.filter { $0.isRunning && !$0.isMine }.count }

    private var stacks: [RunStack] { RunStack.stacks(from: store.runs) }

    /// Mine ↔ Everyone. Watching the whole queue is the point when you're stuck
    /// behind someone else's deploy.
    private var actorToggle: some View {
        HStack(spacing: 3) {
            toggleHalf("Mine", on: !store.showAllActors) { store.showAllActors = false }
            toggleHalf(othersRunning > 0 && store.showAllActors ? "Queue · \(othersRunning)" : "Everyone",
                       on: store.showAllActors) { store.showAllActors = true }
        }
        .padding(3)
        .background(Tokyo.bgDark.opacity(0.8), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Tokyo.stroke()))
    }

    private func toggleHalf(_ label: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 5) {
                // The switch triggers a fetch, so the side you picked says so.
                if on && store.runsRefreshing { Spinner(size: 9, color: Tokyo.cyan) }
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
                .foregroundStyle(on ? Tokyo.cyan : Tokyo.comment)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(on ? Tokyo.cyan.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Showing \(label.lowercased())" : "Show \(label.lowercased())")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokyo.yellow)
                    .frame(width: 28, height: 28)
                    .background(Tokyo.yellow.opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.showAllActors ? "Actions" : "Your Actions")
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1).fixedSize()
                    Text(store.showAllActors ? "Everyone’s workflows" : "Recent workflows")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(Tokyo.comment)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if runningCount > 0 {
                    HStack(spacing: 5) {
                        Spinner(size: 9, color: Tokyo.blue)
                        Text("\(runningCount)").font(.system(size: 11, weight: .bold)).foregroundStyle(Tokyo.blue)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Tokyo.blue.opacity(0.16), in: Capsule())
                    .fixedSize()
                }
            }
            .padding(.horizontal, 13).padding(.top, 13).padding(.bottom, 9)
            actorToggle
                .padding(.horizontal, 13).padding(.bottom, 11)
            ZStack(alignment: .top) {
                Rectangle().fill(Tokyo.line).frame(height: 1)
                if store.runsRefreshing { IndeterminateBar() }
            }
            .frame(height: 1)
            ScrollView {
                VStack(spacing: 8) {
                    if store.runsRefreshing && store.runs.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in RunRowSkeleton() }
                    } else {
                        ForEach(stacks) { st in
                            RunRow(run: st.lead, stackCount: st.count, showActor: store.showAllActors)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)),
                                                        removal: .opacity))
                        }
                    }
                }
                .padding(12)
                .animation(.easeInOut(duration: 0.22), value: store.runs.map(\.id))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Tokyo.bgDark.opacity(0.5))
    }
}

struct RunRow: View {
    let run: WorkflowRun
    /// How many runs of this workflow are stacked into this row (1 = just one).
    var stackCount: Int = 1
    /// Show who owns the run — on in "Everyone" mode, where authorship is the point.
    var showActor: Bool = false
    @State private var hovered = false

    private var showsChip: Bool { (showActor || !run.isMine) && run.actor != nil }

    var body: some View {
        HStack(spacing: 9) {
            Capsule().fill(color).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(run.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if stackCount > 1 {
                        Text("×\(stackCount)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Tokyo.fgDim)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Tokyo.surface(2), in: Capsule())
                            .fixedSize()
                            .help("\(stackCount) runs of “\(run.name)” — showing the oldest")
                    }
                }
                if showsChip, let who = run.actor {
                    Text("@\(who)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(run.isMine ? Tokyo.blue : Tokyo.yellow)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((run.isMine ? Tokyo.blue : Tokyo.yellow).opacity(0.13), in: Capsule())
                }
                if !run.title.isEmpty {
                    Text(run.title).font(.system(size: 10)).foregroundStyle(Tokyo.comment).lineLimit(1)
                }
                if let step = run.stepLine { stepLine(step) }
                HStack(spacing: 6) {
                    stateBadge
                    Spacer(minLength: 4)
                    timer
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokyo.surface(hovered ? 1 : 0),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Tokyo.stroke(), lineWidth: 1))
        // Literal stack: the extra runs peek out from behind the lead card.
        .background(alignment: .top) {
            if stackCount > 1 {
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Tokyo.surface(0))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Tokyo.stroke()))
                        .padding(.horizontal, 5)
                        .frame(height: 22)
                    Spacer(minLength: 0)
                }
                .offset(y: 5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture { openWebURL(run.url) }
        .onHover { hovered = $0 }
        .help(stackCount > 1
              ? "\(stackCount) runs of “\(run.name)” — showing the oldest · \(run.branch) · \(run.event)"
              : "\(run.branch) · \(run.event)")
    }

    /// Which step the run is chewing on (or died on), with a slim progress bar.
    private func stepLine(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: run.isRunning ? "arrow.turn.down.right" : "xmark.circle")
                    .font(.system(size: 8, weight: .bold))
                Text(text)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(run.isRunning ? Tokyo.cyan : Tokyo.red)
            if let i = run.stepIndex, let t = run.stepTotal, t > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokyo.border.opacity(0.5))
                        Capsule()
                            .fill(run.isRunning ? Tokyo.cyan : Tokyo.red)
                            .frame(width: geo.size.width * min(1, Double(i) / Double(t)))
                    }
                }
                .frame(height: 3)
            }
        }
        .help(run.currentJob.map { "\($0) — \(text)" } ?? text)
    }

    private var color: Color {
        if run.isRunning { return Tokyo.blue }
        switch run.conclusion {
        case "success": return Tokyo.green
        case "failure", "timed_out", "startup_failure": return Tokyo.red
        case "cancelled", "skipped": return Tokyo.comment
        default: return Tokyo.yellow
        }
    }

    private var label: String {
        if run.status == "queued" { return "queued" }
        if run.isRunning { return "running" }
        return run.conclusion ?? "completed"
    }

    private var iconName: String {
        if run.isRunning { return "" }
        switch run.conclusion {
        case "success": return "checkmark"
        case "failure", "timed_out", "startup_failure": return "xmark"
        case "cancelled", "skipped": return "minus"
        default: return "questionmark"
        }
    }

    private var stateBadge: some View {
        HStack(spacing: 4) {
            if run.isRunning { Spinner(size: 9, color: color) }
            else { Image(systemName: iconName).font(.system(size: 9, weight: .bold)) }
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
    }

    @ViewBuilder private var timer: some View {
        if run.isRunning, let start = run.startedAt {
            TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                Text(hudDuration(start, ctx.date))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(Tokyo.fgDim)
            }
        } else if let start = run.startedAt, let end = run.updatedAt {
            Text(hudDuration(start, end))
                .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(Tokyo.comment)
        }
    }
}

// MARK: - One leaderboard row (Crew tab)

struct CrewRow: View {
    let entry: VCLeaderboardEntry
    var onSelect: () -> Void = {}
    @State private var hovered = false

    private var rankColor: Color {
        switch entry.rank {
        case 1: return Tokyo.yellow                                // gold
        case 2: return Color(.sRGB, red: 0.75, green: 0.78, blue: 0.84, opacity: 1)   // silver
        case 3: return Tokyo.orange                                // bronze
        default: return Tokyo.comment
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text("\(entry.rank)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(rankColor)
                    .frame(width: 22)
                Text(String(entry.login.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Tokyo.magenta)
                    .frame(width: 24, height: 24)
                    .background(Tokyo.magenta.opacity(0.15), in: Circle())
                Text(vcDisplayName(entry.name) ?? entry.login)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if entry.online {
                    Circle().fill(Tokyo.green).frame(width: 7, height: 7)
                        .shadow(color: Tokyo.green, radius: 3)
                        .help("Online now")
                }
                Spacer(minLength: 6)
                Text(vcDuration(entry.value))
                    .font(.system(size: 13, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Tokyo.magenta)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Tokyo.surface(hovered ? 1 : 0),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("View @\(entry.login)'s profile")
    }
}

// MARK: - One merged-PR row (Merged tab)

struct MergedRow: View {
    let pr: MergedPR
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Capsule().fill(Tokyo.magenta).frame(width: 4, height: 38)
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokyo.magenta)
                .frame(width: 36, height: 36)
                .background(Tokyo.magenta.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(pr.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 7) {
                    Text(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Tokyo.fgDim).lineLimit(1)
                    Text("#\(pr.number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokyo.comment)
                    if let m = pr.mergedAt {
                        Text("Merged \(hudAgo(m)) ago")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Tokyo.comment)
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(Tokyo.surface(hovered ? 1 : 0),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Tokyo.stroke(), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { openWebURL(pr.url) }
        .onHover { hovered = $0 }
        .help(pr.url)
    }
}
