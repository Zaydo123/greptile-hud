import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

// MARK: - Native chrome (macOS-style building blocks, Tokyo-tinted)

/// System Settings–style grouped list: one rounded well, rows separated by
/// inset hairlines. Rows draw their own hover highlight; the well clips it.
struct InsetGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(spacing: 0) { content }
            .background(Tokyo.surface(0), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Tokyo.stroke(), lineWidth: 0.5))
    }
}

/// Inset hairline between rows of an `InsetGroup`.
struct RowDivider: View {
    var inset: CGFloat = 12
    var body: some View {
        Rectangle().fill(Tokyo.line.opacity(0.8)).frame(height: 0.5)
            .padding(.leading, inset)
    }
}

/// `InsetGroup` over a collection, with dividers between rows.
struct InsetList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    var dividerInset: CGFloat = 12
    @ViewBuilder var row: (Item) -> Row
    var body: some View {
        InsetGroup {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { RowDivider(inset: dividerInset) }
                row(item)
            }
        }
    }
}

/// Borderless toolbar button: just a glyph until hovered, like a macOS toolbar.
struct ToolbarIconButton: View {
    let symbol: String?          // nil = busy spinner
    let help: String
    var tint: Color = Tokyo.fgDim
    var lit: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol) }
                else { Spinner(size: 12, color: Tokyo.comment) }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(lit ? tint : (hovered ? Tokyo.fg : tint))
            .frame(width: 30, height: 30)
            .background((lit ? tint.opacity(0.16) : (hovered ? Tokyo.surface(2) : .clear)),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// macOS segmented control with a sliding raised thumb.
struct SegmentedControl<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let label: String
        var icon: String? = nil
        var count: Int? = nil
        var busy: Bool = false
        var id: Value { value }
    }
    let segments: [Segment]
    let selection: Value
    var height: CGFloat = 30
    var accent: (Value) -> Color = { _ in Tokyo.blue }
    let onSelect: (Value) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { seg in
                let on = seg.value == selection
                Button { onSelect(seg.value) } label: {
                    HStack(spacing: 6) {
                        if seg.busy { Spinner(size: 9, color: accent(seg.value)) }
                        else if let icon = seg.icon {
                            Image(systemName: icon)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(on ? accent(seg.value) : Tokyo.comment)
                        }
                        Text(seg.label)
                            .font(.system(size: 12, weight: on ? .semibold : .medium))
                            .lineLimit(1)
                        if let c = seg.count {
                            Text("\(c)")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Tokyo.comment)
                        }
                    }
                    .foregroundStyle(on ? Tokyo.fg : Tokyo.fgDim)
                    .frame(maxWidth: .infinity, minHeight: height - 4)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Tokyo.bgHighlight)
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Tokyo.fg.opacity(0.08), lineWidth: 0.5))
                                .shadow(color: Tokyo.bgDark.opacity(0.6), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(height: height)
        .background(Tokyo.bgDark.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Tokyo.stroke(), lineWidth: 0.5))
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: selection)
    }
}

/// Native-style section header that sits above an `InsetGroup`.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokyo.fgDim)
            trailing
        }
        .padding(.horizontal, 4)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.title = title; self.trailing = EmptyView() }
}

/// Activity-ring score gauge: the ring fills to the Greptile score.
struct ScoreRing: View {
    var fraction: Double          // 0…1; ignored when `dashed`
    var color: Color
    var dashed = false
    var size: CGFloat = 40
    var body: some View {
        let w: CGFloat = 3.5
        ZStack {
            if dashed {
                Circle().strokeBorder(color.opacity(0.55),
                                      style: StrokeStyle(lineWidth: 1.25, dash: [2.5, 3]))
            } else {
                Circle().stroke(color.opacity(0.18), lineWidth: w).padding(w / 2)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: w, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(w / 2)
            }
        }
        .frame(width: size, height: size)
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

/// Placeholder in the shape of a `PRCard` row (sits inside an `InsetGroup`).
struct PRCardSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Tokyo.surface(1)).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(width: 240, height: 11)
                SkeletonBar(width: 150, height: 9)
                SkeletonBar(width: 190, height: 8)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }
}

/// Placeholder in the shape of a `RunRow` (sits inside an `InsetGroup`).
struct RunRowSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(Tokyo.surface(1)).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBar(width: 120, height: 10)
                SkeletonBar(width: 150, height: 8)
                SkeletonBar(width: 80, height: 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Text field (typing in a nonactivating overlay)

/// An `NSTextField` that force-activates the app and keys the panel when
/// clicked, so the HUD overlay — a nonactivating panel that never takes focus
/// on its own — can actually receive keyboard input.
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
struct HUDTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var fontSize: CGFloat = 13
    var alignment: NSTextAlignment = .left
    var maximumCharacters: Int? = nil
    var onEditing: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusableTextField {
        let field = FocusableTextField()
        field.placeholderString = placeholder
        field.isBezeled = false
        field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        field.textColor = NSColor(Tokyo.fg)
        field.alignment = alignment
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
        context.coordinator.parent = self
        nsView.placeholderString = placeholder
        nsView.font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        nsView.alignment = alignment
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HUDTextField
        init(_ parent: HUDTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let value: String
            if let limit = parent.maximumCharacters, field.stringValue.count > limit {
                value = String(field.stringValue.prefix(limit))
                field.stringValue = value
            } else {
                value = field.stringValue
            }
            parent.text = value
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
    @ObservedObject var statuses: StatusStore
    @ObservedObject var hud: HUDState = HUDState()
    var onClose: () -> Void = {}
    /// Fired when an editable text field gains/loses focus: the overlay is a
    /// nonactivating panel, so the app must activate itself to take typing,
    /// and the overlay must stay up while typing even if Right Shift releases.
    var onTextEditing: (Bool) -> Void = { _ in }
    /// Refreshes menu-bar chrome after starting or stopping a local status.
    var onStatusChanged: () -> Void = {}
    /// Corner-drag resize, forwarded to the panel.
    var onResize: (CGSize) -> Void = { _ in }
    var onResizeEnded: () -> Void = {}

    @State private var tab: Tab = .open
    @State private var navigationRevision = 0
    @State private var showStale: Bool = false
    @State private var staleHovered: Bool = false
    @State private var usernameDraft = ""
    private enum Tab { case open, merged, crew }

    private static let staleThreshold: TimeInterval = 14 * 86400

    private func isStale(_ pr: PR) -> Bool {
        let last = pr.updatedAt ?? pr.lastCommitAt ?? .distantPast
        return Date().timeIntervalSince(last) > Self.staleThreshold
    }

    private var freshPRs: [PR] { store.prs.filter { !isStale($0) } }
    private var stalePRs: [PR] { store.prs.filter { isStale($0) } }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                tabBar
                if let err = store.errorText {
                    banner(err, color: Tokyo.orange, icon: "exclamationmark.triangle.fill")
                }
                Rectangle().fill(Tokyo.line).frame(height: 0.5)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(navigationRevision)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.16), value: tab)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // CI is noise next to Crew — the column only rides along with PR tabs.
            if !store.runs.isEmpty && tab != .crew {
                Rectangle().fill(Tokyo.line).frame(width: 0.5)
                RunsColumn(store: store, onTextEditing: onTextEditing).frame(width: 248)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Frosted, like a real HUD window — the Tokyo tint keeps it on-theme.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [Tokyo.bg.opacity(0.88), Tokyo.bgDark.opacity(0.92)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Tokyo.fg.opacity(0.12), lineWidth: 0.5))
        .shadow(color: Tokyo.bgDark.opacity(0.7), radius: 28, y: 12)
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
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(color.opacity(0.28), lineWidth: 0.5))
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var reviewingCount: Int { store.prs.filter { $0.reviewing }.count }

    private var header: some View {
        HStack(spacing: 10) {
            // App-icon tile.
            Image(systemName: "eyes")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokyo.bgDark)
                .frame(width: 32, height: 32)
                .background(LinearGradient(colors: [Tokyo.blue, Tokyo.magenta],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Tokyo.fg.opacity(0.18), lineWidth: 0.5))
                .shadow(color: Tokyo.bgDark.opacity(0.5), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Greptile Reviews")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if !store.prs.isEmpty {
                        Text("\(store.prs.count)")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Tokyo.comment)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                if vibecoders.hasUsername {
                    HStack(spacing: 4) {
                        Text("@\(vibecoders.username)")
                        Text("·").foregroundStyle(Tokyo.comment)
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9)).foregroundStyle(Tokyo.magenta)
                        Text("\(vcDuration(vibecoders.devtimeToday)) today")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Tokyo.fgDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(vibecoders.todayPeriodDescription)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if reviewingCount > 0 {
                HStack(spacing: 5) {
                    Spinner(size: 9, color: Tokyo.blue)
                    Text("\(reviewingCount) reviewing")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Tokyo.blue)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Tokyo.blue.opacity(0.14), in: Capsule())
                .fixedSize()
            }
            clock
            HStack(spacing: 2) {
                latchIndicator
                ToolbarIconButton(symbol: store.refreshing ? nil : "arrow.clockwise", help: "Refresh now") {
                    Task { await store.refresh(force: true) }
                }
                .disabled(store.refreshing)
                ToolbarIconButton(symbol: "xmark", help: "Close", action: onClose)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    /// Wall clock + last-sync age. The seconds tick live so the HUD reads as
    /// something running, not a screenshot.
    private var clock: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { ctx in
            VStack(alignment: .trailing, spacing: 0) {
                Text(HUDClock.time.string(from: ctx.date))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokyo.fg)
                    .monospacedDigit()
                Text(syncLine(ctx.date))
                    .font(.system(size: 10))
                    .foregroundStyle(Tokyo.comment)
            }
            .padding(.trailing, 4)
            .help("Local time · \(HUDClock.date.string(from: ctx.date))")
        }
        .fixedSize()
    }

    /// Shows the hold-to-latch progress while Right Shift is down, then stays as
    /// a lit pin once the overlay is latched open. Hidden the rest of the time.
    @ViewBuilder private var latchIndicator: some View {
        if hud.pinned {
            // One click drops the latch — unpinning is never a hold.
            ToolbarIconButton(symbol: "pin.fill",
                              help: "Latched open — click or press Esc to close",
                              tint: Tokyo.magenta, lit: true, action: onClose)
        } else if let start = hud.holdStartedAt {
            TimelineView(.animation) { ctx in
                let p = min(1, max(0, ctx.date.timeIntervalSince(start) / HUDState.latchDelay))
                ZStack {
                    Circle().stroke(Tokyo.border.opacity(0.5), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: p)
                        .stroke(Tokyo.magenta, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "pin")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(p >= 1 ? Tokyo.magenta : Tokyo.comment)
                }
                .frame(width: 20, height: 20)
                .frame(width: 30, height: 30)
            }
            .help("Keep holding Right ⇧ to latch the HUD open")
        }
    }

    private func syncLine(_ now: Date) -> String {
        guard let d = store.lastRefresh else { return "Not synced yet" }
        let s = Int(now.timeIntervalSince(d))
        if s < 5 { return "Synced just now" }
        if s < 60 { return "Synced \(s)s ago" }
        return "Synced \(s / 60)m ago"
    }

    /// Quiet status bar: Bebop send-off, running status, session clock.
    private var footer: some View {
        HStack(spacing: 8) {
            Text(Bebop.signoff)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Tokyo.comment)
                .fixedSize()
            Spacer(minLength: 6)
            if let status = statuses.active {
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    HStack(spacing: 5) {
                        Text(status.emoji.isEmpty ? "●" : status.emoji)
                        Text(status.displayLabel)
                            .lineLimit(1)
                        Text(hudDuration(status.startedAt, ctx.date))
                            .monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokyo.yellow)
                }
                .help("Local status running")
            } else {
                Text(Bebop.sessionTitle)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(Tokyo.comment.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                Text("Up \(hudDuration(HUDClock.launchedAt, ctx.date))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Tokyo.comment)
                    .monospacedDigit()
            }
            ResizeGrip(onChanged: onResize, onEnded: onResizeEnded)
        }
        .padding(.leading, 16).padding(.trailing, 4)
        .frame(height: 24)
        .background(Tokyo.bgDark.opacity(0.35))
        .overlay(Rectangle().fill(Tokyo.line).frame(height: 0.5), alignment: .top)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .open:   openContent
        case .merged: mergedContent
        case .crew:   crewContent
        }
    }

    // Segmented Open / Merged / Crew switcher for the main list.
    private var tabBar: some View {
        SegmentedControl<Tab>(
            segments: [
                .init(value: .open, label: "Open", icon: "arrow.triangle.branch", count: store.prs.count),
                .init(value: .merged, label: "Merged", icon: "arrow.triangle.merge", count: store.merged.count),
                .init(value: .crew, label: "Crew", icon: "person.2.fill", count: vibecoders.online.count),
            ],
            selection: tab,
            height: 32,
            accent: { $0 == .crew ? Tokyo.magenta : Tokyo.blue },
            onSelect: showOverview
        )
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    /// Top-level tabs are also home buttons. Re-selecting one rebuilds its root
    /// view, and Crew additionally leaves any member profile being viewed.
    private func showOverview(_ destination: Tab) {
        if destination == .crew {
            vibecoders.dismissProfile()
        }
        tab = destination
        navigationRevision += 1
    }

    @ViewBuilder private var openContent: some View {
        if store.prs.isEmpty && store.refreshing {
            ScrollView {
                InsetGroup {
                    ForEach(0..<4, id: \.self) { i in
                        if i > 0 { RowDivider(inset: 64) }
                        PRCardSkeleton()
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.prs.isEmpty {
            emptyState(icon: "checkmark.seal", text: "No open PRs", sub: "The gate is clear, cowboy.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !freshPRs.isEmpty {
                        InsetList(items: freshPRs, dividerInset: 64) { pr in
                            PRCard(pr: pr, store: store)
                                .transition(.opacity)
                        }
                    }
                    if !stalePRs.isEmpty {
                        staleDisclosure
                        if showStale {
                            InsetList(items: stalePRs, dividerInset: 64) { pr in
                                PRCard(pr: pr, store: store)
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .padding(14)
                .animation(.easeInOut(duration: 0.22), value: store.prs.map(\.id))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Finder-sidebar–style section toggle.
    private var staleDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showStale.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(showStale ? 90 : 0))
                    .frame(width: 14)
                Text("Stale")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(staleHovered ? Tokyo.fg : Tokyo.fgDim)
                Text("\(stalePRs.count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                Spacer()
                Text("No activity in 14 days")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Tokyo.comment)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { staleHovered = $0 }
        .help(showStale ? "Hide stale pull requests" : "Show stale pull requests")
    }

    @ViewBuilder private var mergedContent: some View {
        if store.merged.isEmpty && store.refreshing {
            ScrollView {
                InsetGroup {
                    ForEach(0..<3, id: \.self) { i in
                        if i > 0 { RowDivider(inset: 64) }
                        PRCardSkeleton()
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.merged.isEmpty {
            emptyState(icon: "tray", text: "No recent merges", sub: nil)
        } else {
            ScrollView {
                InsetList(items: store.merged, dividerInset: 56) { m in MergedRow(pr: m) }
                    .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyState(icon: String, text: String, sub: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Tokyo.comment)
                .padding(.bottom, 4)
            Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Tokyo.fgDim)
            if let sub {
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokyo.comment)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Crew tab (vibecoders)

    @ViewBuilder private var crewContent: some View {
        if vibecoders.hasUsername && vibecoders.selectedProfileLogin != nil {
            crewProfileContent
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StatusesView(store: statuses, vibecoders: vibecoders,
                                 onChanged: onStatusChanged)
                    if vibecoders.hasUsername {
                        if !vibecoders.crewStatuses.isEmpty { crewStatusStrip }
                        onlineStrip
                        devtimeSection
                        usageSection
                    } else {
                        crewJoinContent
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var crewJoinContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Tokyo.magenta)
                .padding(.bottom, 2)
            Text("Join the vibecoders leaderboard")
                .font(.system(size: 15, weight: .semibold))
            Text("Pick a username and your devtime starts counting the moment\nan editor is open. No GitHub sign-in, no tokens — we trust you.")
                .font(.system(size: 12))
                .foregroundStyle(Tokyo.fgDim)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                HUDTextField(text: $usernameDraft,
                             placeholder: "username",
                             onEditing: onTextEditing,
                             onSubmit: joinCrew)
                    .frame(width: 200, height: 30)
                    .padding(.horizontal, 8)
                    .background(Tokyo.bgDark.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Tokyo.stroke(true), lineWidth: 0.5))
                Button(action: joinCrew) {
                    Text("Join")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokyo.bgDark)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background(Tokyo.magenta, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
            if let err = vibecoders.errorText {
                Text(err).font(.system(size: 11)).foregroundStyle(Tokyo.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var crewStatusStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Crew statuses") {
                Text("\(vibecoders.crewStatuses.count)")
                    .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                Spacer()
                Text("Active until stopped")
                    .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(vibecoders.crewStatuses) { status in
                        Button { vibecoders.showProfile(login: status.login) } label: {
                            CrewStatusCard(status: status)
                        }
                        .buttonStyle(.plain)
                        .help("View @\(status.login)")
                    }
                }
            }
        }
    }

    /// AirDrop-style row of avatars for whoever is online right now.
    private var onlineStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Online now") {
                if !vibecoders.online.isEmpty {
                    Text("\(vibecoders.online.count)")
                        .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                }
            }
            InsetGroup {
                if vibecoders.online.isEmpty {
                    Text("Nobody vibing right now — first heartbeat within 5 minutes of launching an editor counts.")
                        .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(vibecoders.online, id: \.login) { u in
                                OnlineAvatarButton(user: u, status: crewStatus(for: u.login),
                                                   isMe: isMe(u.login)) {
                                    vibecoders.showProfile(login: u.login)
                                }
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 10)
                    }
                }
            }
        }
    }

    /// Your avatar: click to pick a photo, right-click to remove it.
    private var ownAvatarButton: some View {
        Button(action: pickAvatarPhoto) {
            CrewAvatar(login: vibecoders.username, avatarPath: vibecoders.user?.avatarUrl, size: 44)
                .overlay {
                    if vibecoders.avatarBusy {
                        Circle().fill(Tokyo.bgDark.opacity(0.6))
                        Spinner(size: 14, color: Tokyo.fg)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Tokyo.fg)
                        .frame(width: 18, height: 18)
                        .background(Tokyo.bgHighlight, in: Circle())
                        .overlay(Circle().strokeBorder(Tokyo.bg, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(vibecoders.avatarBusy)
        .contextMenu {
            Button("Choose Photo…", action: pickAvatarPhoto)
            if vibecoders.user?.avatarUrl != nil {
                Button("Remove Photo") { vibecoders.removeAvatar() }
            }
        }
        .help(vibecoders.user?.avatarUrl == nil
              ? "Add a profile photo"
              : "Change your profile photo (right-click to remove)")
    }

    /// The overlay sits at screen-saver level, so the picker has to sit above it.
    private func pickAvatarPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a profile photo. It’s cropped to a square and shrunk to 256 px before upload."
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in vibecoders.uploadAvatar(from: url) }
        }
    }

    /// Crew-wide app & site time for the selected period, and your sharing switch.
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Where the time goes") {
                Spacer()
                Text(vibecoders.leaderboardPeriod.profileLabel)
                    .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
            }
            InsetGroup {
                if let report = vibecoders.crewUsage, !report.items.isEmpty {
                    UsageBreakdown(report: report, maxItems: 10, showPeople: true)
                } else {
                    Text("No app or site time yet. It shows up here a minute or two after people start using the Mac.")
                        .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                RowDivider(inset: 12)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share my app & site time")
                            .font(.system(size: 12)).foregroundStyle(Tokyo.fg)
                        Text("Only ~120 major apps and sites are named; everything else counts as Other. URLs and window titles never leave this Mac.")
                            .font(.system(size: 10)).foregroundStyle(Tokyo.comment)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("Share my app & site time", isOn: $vibecoders.usageSharing)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(Tokyo.magenta)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
    }

    private func isMe(_ login: String) -> Bool {
        login.caseInsensitiveCompare(vibecoders.username) == .orderedSame
    }

    /// One period control drives both your stats and the leaderboard.
    private var devtimeSection: some View {
        let entry = vibecoders.board.first { isMe($0.login) }
        let seconds = entry?.value ?? (vibecoders.leaderboardPeriod == .today ? vibecoders.devtimeToday : 0)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionHeader("Devtime")
                Spacer(minLength: 8)
                crewPeriodPicker
            }
            if let range = vibecoders.leaderboardPeriodRange {
                periodRangeLabel(range, help: vibecoders.leaderboardPeriodDescription)
                    .padding(.horizontal, 4).padding(.bottom, 2)
            }

            // You: period total and rank.
            InsetGroup {
                HStack(spacing: 14) {
                    ownAvatarButton
                    VStack(alignment: .leading, spacing: 1) {
                        Text(vibecoders.leaderboardPeriod.profileLabel)
                            .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                        Text(vcDuration(seconds))
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(Tokyo.magenta).monospacedDigit()
                    }
                    Rectangle().fill(Tokyo.line).frame(width: 0.5, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Crew rank")
                            .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                        Text(entry.map { "#\($0.rank)" } ?? "—")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(Tokyo.cyan)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            if let avatarError = vibecoders.avatarError {
                Text(avatarError)
                    .font(.system(size: 11)).foregroundStyle(Tokyo.orange)
                    .padding(.horizontal, 4)
            }

            ZStack {
                if vibecoders.boardRefreshing { IndeterminateBar(color: Tokyo.magenta) }
            }
            .frame(height: 2)
            .padding(.horizontal, 6)

            // Nobody with zero devtime: an empty row is noise, not a ranking.
            let ranked = vibecoders.board.filter { $0.value > 0 }
            if ranked.isEmpty {
                InsetGroup {
                    Text("No devtime yet — open an editor and the minutes start stacking.")
                        .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 18)
                }
            } else {
                InsetGroup {
                    ForEach(Array(ranked.prefix(10).enumerated()), id: \.element.login) { i, e in
                        if i > 0 { RowDivider(inset: 76) }
                        CrewRow(entry: e, isMe: isMe(e.login)) { vibecoders.showProfile(login: e.login) }
                    }
                }
            }
            if let err = vibecoders.errorText {
                Text(err).font(.system(size: 11)).foregroundStyle(Tokyo.orange)
                    .padding(.horizontal, 4)
            }
        }
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
        VStack(alignment: .leading, spacing: 20) {
            // Navigation-style back + identity.
            VStack(alignment: .leading, spacing: 14) {
                Button { vibecoders.dismissProfile() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Crew").font(.system(size: 13))
                    }
                    .foregroundStyle(Tokyo.magenta)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to Crew")

                HStack(spacing: 14) {
                    CrewAvatar(login: profile.user.login, avatarPath: profile.user.avatarUrl, size: 56,
                               online: profile.online)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vcDisplayName(profile.user.name) ?? profile.user.login)
                            .font(.system(size: 20, weight: .semibold))
                        HStack(spacing: 6) {
                            Text("@\(profile.user.login)")
                            Text("·")
                            Text(profile.online ? "Online now" : "Offline")
                                .foregroundStyle(profile.online ? Tokyo.green : Tokyo.comment)
                        }
                        .font(.system(size: 12)).foregroundStyle(Tokyo.comment)
                    }
                    Spacer()
                }
            }

            InsetGroup {
                HStack(spacing: 0) {
                    profileMetric(profile.period.profileLabel, vcDuration(profile.devtimePeriod),
                                  tone: Tokyo.magenta)
                    Rectangle().fill(Tokyo.line).frame(width: 0.5).padding(.vertical, 10)
                    profileMetric("All time", vcDuration(profile.devtimeAll), tone: Tokyo.cyan)
                    Rectangle().fill(Tokyo.line).frame(width: 0.5).padding(.vertical, 10)
                    profileMetric("Sprints", "\(profile.sprints.count)", tone: Tokyo.yellow)
                }
            }

            InsetGroup {
                if let status = crewStatus(for: profile.user.login) {
                    crewProfileStatus(status)
                    RowDivider(inset: 40)
                }
                profileDetail("Presence", profile.online ? "Online now" : "Offline",
                              icon: profile.online ? "circle.fill" : "moon.fill",
                              tone: profile.online ? Tokyo.green : Tokyo.comment)
                if let lastSeen = profile.user.lastSeen {
                    RowDivider(inset: 40)
                    profileDetail("Last online", lastSeen.formatted(date: .abbreviated, time: .shortened),
                                  icon: "clock.arrow.circlepath", tone: Tokyo.cyan)
                }
                if let joined = profile.user.createdAt {
                    RowDivider(inset: 40)
                    profileDetail("Joined", joined.formatted(date: .long, time: .omitted),
                                  icon: "calendar", tone: Tokyo.magenta)
                }
            }

            if profile.period != .today, !profile.daily.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Devtime by day")
                    InsetGroup { DailyBars(days: profile.daily) }
                }
            }

            if let usage = profile.usage, !usage.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Apps & sites") {
                        Spacer()
                        Text("\(vcDuration(usage.totalSeconds)) tracked")
                            .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                    }
                    InsetGroup { UsageBreakdown(report: usage) }
                }
            }

            if !profile.activities.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Activities")
                    InsetGroup { ActivityBreakdown(totals: profile.activities) }
                }
            }

            if !profile.recentStatuses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Recent statuses")
                    InsetGroup {
                        ForEach(Array(profile.recentStatuses.enumerated()), id: \.element.id) { i, e in
                            if i > 0 { RowDivider(inset: 40) }
                            HStack(spacing: 10) {
                                Text(e.emoji.isEmpty ? "●" : e.emoji).font(.system(size: 15)).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.displayLabel).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(e.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 10)).foregroundStyle(Tokyo.comment)
                                }
                                Spacer()
                                Text(hudDuration(e.startedAt, e.endedAt))
                                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(Tokyo.activity(e.emoji))
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 42)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    SectionHeader("Sprints")
                    if vibecoders.profileLoading { Spinner(size: 10, color: Tokyo.magenta) }
                    Spacer(minLength: 8)
                    crewPeriodPicker
                }
                if let range = vcPeriodRange(start: profile.periodStart, end: profile.periodEnd) {
                    periodRangeLabel(range,
                                     help: vcExactPeriodDescription(profile.period.profileLabel,
                                                                    start: profile.periodStart,
                                                                    end: profile.periodEnd))
                        .padding(.horizontal, 4).padding(.bottom, 2)
                }
                ZStack {
                    if vibecoders.profileLoading { IndeterminateBar(color: Tokyo.magenta) }
                }
                .frame(height: 2).padding(.horizontal, 6)
                InsetGroup {
                    SprintMap(period: profile.period,
                              sprints: profile.sprints,
                              periodStart: profile.periodStart,
                              periodEnd: profile.periodEnd)
                        .padding(12)
                }
                if profile.sprints.isEmpty {
                    Text("No sprint history for this period yet. Sessions begin appearing after the first activity heartbeat.")
                        .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    InsetGroup {
                        ForEach(Array(profile.sprints.enumerated()), id: \.element.id) { i, sprint in
                            if i > 0 { RowDivider(inset: 32) }
                            sprintRow(sprint)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func profileMetric(_ label: String, _ value: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(Tokyo.comment)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(tone).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var crewPeriodPicker: some View {
        SegmentedControl<VCLeaderboardPeriod>(
            segments: VCLeaderboardPeriod.allCases.map { .init(value: $0, label: $0.label) },
            selection: vibecoders.leaderboardPeriod,
            height: 26,
            accent: { _ in Tokyo.magenta },
            onSelect: { vibecoders.selectLeaderboardPeriod($0) }
        )
        .frame(width: 210)
        .help(vibecoders.leaderboardPeriodDescription)
    }

    private func periodRangeLabel(_ text: String, help: String) -> some View {
        Label(text, systemImage: "calendar")
            .font(.system(size: 11))
            .foregroundStyle(Tokyo.comment)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(help)
    }

    private func profileDetail(_ label: String, _ value: String, icon: String, tone: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tone).frame(width: 18)
            Text(label).font(.system(size: 12)).foregroundStyle(Tokyo.fgDim)
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(Tokyo.fg).monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
    }

    private func crewProfileStatus(_ status: VCCrewStatus) -> some View {
        HStack(spacing: 10) {
            Text(status.emoji.isEmpty ? "●" : status.emoji).font(.system(size: 14)).frame(width: 18)
            Text("Status").font(.system(size: 12)).foregroundStyle(Tokyo.fgDim)
            Spacer(minLength: 8)
            Text(status.displayLabel)
                .font(.system(size: 12)).lineLimit(1)
            TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                Text(hudDuration(status.startedAt, ctx.date))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokyo.activity(status.emoji)).monospacedDigit()
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
    }

    private func crewStatus(for login: String) -> VCCrewStatus? {
        vibecoders.crewStatuses.first { $0.login.caseInsensitiveCompare(login) == .orderedSame }
    }

    private func joinCrew() {
        vibecoders.setUsername(usernameDraft)
        vibecoders.publishStatus(statuses.active)
        vibecoders.syncStatusHistory(statuses)
    }

    private func sprintRow(_ sprint: VCSprint) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(sprint.active ? Tokyo.green : Tokyo.magenta)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(sprintDateLabel(sprint.startedAt))
                    .font(.system(size: 10)).foregroundStyle(Tokyo.comment)
                Text("\(sprintTimeLabel(sprint.startedAt)) – \(sprintEndLabel(sprint))")
                    .font(.system(size: 12)).monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(vcDuration(sprint.durationSeconds))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Tokyo.magenta)
                if sprint.active {
                    Text("Active")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Tokyo.green)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 46)
    }

    private func sprintEndLabel(_ sprint: VCSprint) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        if calendar.isDate(sprint.startedAt, inSameDayAs: sprint.endedAt) {
            return sprintTimeLabel(sprint.endedAt)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy, h:mm a"
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: sprint.endedAt)
    }

    private func sprintDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        return formatter.string(from: date)
    }

    private func sprintTimeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        return formatter.string(from: date)
    }
}

// MARK: - Sprint activity map (Central Time, matching Crew period boundaries)

struct SprintMap: View {
    let period: VCLeaderboardPeriod
    let sprints: [VCSprint]
    let periodStart: Date?
    let periodEnd: Date?

    @State private var hoveredBlockID: String?

    private static let centralTimezone = TimeZone(identifier: "America/Chicago")!

    private static var centralCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = centralTimezone
        return calendar
    }()

    private var bounds: (start: Date, end: Date) {
        let calendar = Self.centralCalendar
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
            day = Self.centralCalendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(period == .month ? "Daily activity" : "Hourly activity")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Tokyo.comment)
                Spacer()
                Text("Central Time")
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
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Tokyo.stroke(), lineWidth: 0.5))
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
                        let start = Self.centralCalendar.date(byAdding: .hour, value: hour, to: day)!
                        let next = Self.centralCalendar.date(byAdding: .hour, value: 1, to: start)!
                        let seconds = activeSeconds(from: start, to: next)
                        let tooltip = activityHelp(from: start, to: next)
                        let blockID = "hour-\(start.timeIntervalSince1970)"
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(activityColor(seconds: seconds, maximum: 3600))
                            .frame(maxWidth: .infinity, minHeight: 10, maxHeight: 10)
                            .contentShape(Rectangle())
                            .overlay(alignment: hour >= 12 ? .bottomTrailing : .bottomLeading) {
                                if hoveredBlockID == blockID {
                                    offsetHoverCard(tooltip)
                                }
                            }
                            .onHover { hovering in
                                updateHover(id: blockID, hovering: hovering)
                            }
                            .accessibilityLabel(Text(tooltip))
                            .zIndex(hoveredBlockID == blockID ? 20 : 0)
                    }
                }
            }
        }
    }

    private var monthGrid: some View {
        let leading = max(0, Self.centralCalendar.component(.weekday, from: bounds.start) - 1)
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
                ForEach(Array(cells.enumerated()), id: \.offset) { index, day in
                    if let day {
                        let next = Self.centralCalendar.date(byAdding: .day, value: 1, to: day)!
                        let seconds = activeSeconds(from: day, to: next)
                        let tooltip = activityHelp(from: day, to: next)
                        let blockID = "day-\(day.timeIntervalSince1970)"
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(activityColor(seconds: seconds, maximum: 8 * 3600))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                            .overlay(alignment: index % 7 >= 4 ? .bottomTrailing : .bottomLeading) {
                                if hoveredBlockID == blockID {
                                    offsetHoverCard(tooltip)
                                }
                            }
                            .onHover { hovering in
                                updateHover(id: blockID, hovering: hovering)
                            }
                            .accessibilityLabel(Text(tooltip))
                            .zIndex(hoveredBlockID == blockID ? 20 : 0)
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

    private func updateHover(id: String, hovering: Bool) {
        if hovering {
            hoveredBlockID = id
        } else if hoveredBlockID == id {
            hoveredBlockID = nil
        }
    }

    private func offsetHoverCard(_ help: String) -> some View {
        VStack(spacing: 0) {
            Text(help)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Tokyo.fg)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 230, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Tokyo.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Tokyo.magenta.opacity(0.55)))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            Color.clear.frame(width: 1, height: 18)
        }
        .fixedSize()
        .allowsHitTesting(false)
    }

    private func activityColor(seconds: TimeInterval, maximum: TimeInterval) -> Color {
        guard seconds > 0 else { return Tokyo.surface(1) }
        let intensity = min(1, seconds / maximum)
        return Tokyo.magenta.opacity(0.22 + intensity * 0.70)
    }

    private func activityHelp(from start: Date, to end: Date) -> String {
        let previewLimit = 3
        let matching = sprints
            .filter { $0.startedAt < end && $0.endedAt > start }
            .sorted { $0.startedAt < $1.startedAt }
        let block = end.timeIntervalSince(start) <= 3600
            ? "\(hourLabel(start)) hour"
            : fullDayLabel(start)
        let total = vcDuration(Int64(activeSeconds(from: start, to: end)))
        guard !matching.isEmpty else {
            return "\(block)\nNo sprint activity"
        }
        let sprintLines = matching.prefix(previewLimit).map { sprint in
            let active = sprint.active ? " · active" : ""
            return "\(sprintRangeLabel(sprint)) · \(vcDuration(sprint.durationSeconds))\(active)"
        }
        let countLabel = matching.count == 1 ? "1 sprint" : "\(matching.count) sprints"
        let remaining = matching.count - sprintLines.count
        let overflow = remaining > 0 ? ["+\(remaining) more · see full sprint list below"] : []
        return (["\(block)\n\(total) active · \(countLabel)"] + sprintLines + overflow)
            .joined(separator: "\n")
    }

    private func sprintRangeLabel(_ sprint: VCSprint) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        formatter.timeZone = Self.centralTimezone
        if Self.centralCalendar.isDate(sprint.startedAt, inSameDayAs: sprint.endedAt) {
            let endFormatter = DateFormatter()
            endFormatter.dateFormat = "HH:mm z"
            endFormatter.timeZone = Self.centralTimezone
            return "\(formatter.string(from: sprint.startedAt))–\(endFormatter.string(from: sprint.endedAt))"
        }
        return "\(formatter.string(from: sprint.startedAt))–\(formatter.string(from: sprint.endedAt)) Central Time"
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = period == .today ? "MMM d" : "EEE"
        formatter.timeZone = Self.centralTimezone
        return formatter.string(from: date)
    }

    private func fullDayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = Self.centralTimezone
        return formatter.string(from: date)
    }

    private func hourLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm z"
        formatter.timeZone = Self.centralTimezone
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

struct CrewStatusCard: View {
    let status: VCCrewStatus
    @State private var hovered = false

    private var accent: Color { Tokyo.activity(status.emoji) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 12) {
            Text(status.emoji.isEmpty ? "●" : status.emoji)
                .font(.system(size: 24)).frame(width: 46, height: 46)
                .background(accent.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    CrewAvatar(login: status.login, avatarPath: status.avatarUrl, size: 16,
                               online: status.online)
                    Text(vcDisplayName(status.name) ?? status.login)
                        .lineLimit(1)
                    Text(status.online ? "· Online" : "· Away")
                        .foregroundStyle(Tokyo.comment)
                        .fixedSize()
                }
                .font(.system(size: 11)).foregroundStyle(Tokyo.fgDim)
                Text(status.displayLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokyo.fg).lineLimit(1)
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    Text(hudDuration(status.startedAt, ctx.date))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(accent).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokyo.comment.opacity(hovered ? 1 : 0.5))
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .background(Tokyo.surface(hovered ? 1 : 0), in: shape)
        .overlay(shape.strokeBorder(accent.opacity(hovered ? 0.5 : 0.28), lineWidth: 0.5))
        .contentShape(shape)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Local status stopwatch

struct StatusesView: View {
    @ObservedObject var store: StatusStore
    @ObservedObject var vibecoders: VibecodersStore
    var onChanged: () -> Void = {}

    @State private var showHistory = false
    @State private var editingRename = ""
    @State private var renameTarget: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Status") {
                Spacer()
                Text("Pick to start · pick again to stop")
                    .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
            }
            if let active = store.active {
                activeCard(active).padding(.bottom, 4)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                ForEach(ActivityPreset.allCases) { activity in
                    presetButton(activity)
                }
            }

            InsetGroup {
                sharingState
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                RowDivider(inset: 40)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showHistory.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12)).foregroundStyle(Tokyo.yellow)
                            .frame(width: 18)
                        Text("History").foregroundStyle(Tokyo.fg)
                        Text("\(store.history.count)").foregroundStyle(Tokyo.comment).monospacedDigit()
                        Spacer()
                        Text("Stored on this Mac").foregroundStyle(Tokyo.comment)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Tokyo.comment)
                            .rotationEffect(.degrees(showHistory ? 90 : 0))
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 12).frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Activity history, \(store.history.count) completed")
                .accessibilityValue(showHistory ? "Expanded" : "Collapsed")

                if showHistory {
                    if store.history.isEmpty {
                        RowDivider(inset: 40)
                        Text("Stopped activities appear here. Completed history stays on this Mac.")
                            .font(.system(size: 11)).foregroundStyle(Tokyo.comment)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        ForEach(store.history) { session in
                            RowDivider(inset: 40)
                            if renameTarget == session.id {
                                editRenameField(session)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                            } else {
                                StatusHistoryRow(session: session) {
                                    editingRename = session.message
                                    renameTarget = session.id
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func presetButton(_ activity: ActivityPreset) -> some View {
        let selected = store.active?.emoji == activity.rawValue
        return PresetTile(activity: activity, selected: selected) {
            if store.active?.emoji == activity.rawValue { store.stop() }
            else { store.start(activity: activity) }
            vibecoders.publishStatus(store.active)
            onChanged()
        }
    }

    private func activeCard(_ session: StatusSession) -> some View {
        let accent = Tokyo.activity(session.emoji)
        return InsetGroup {
            HStack(spacing: 12) {
                Text(session.emoji.isEmpty ? "●" : session.emoji)
                    .font(.system(size: 24))
                    .frame(width: 46, height: 46)
                    .background(accent.opacity(0.16), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    if renameTarget == session.id {
                        editRenameField(session)
                    } else {
                        HStack(spacing: 6) {
                            Text(session.displayLabel)
                                .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Button {
                                editingRename = session.message
                                renameTarget = session.id
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Tokyo.comment)
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Edit activity label")
                            .accessibilityLabel("Edit activity label")
                        }
                    }
                    HStack(spacing: 5) {
                        Circle().fill(Tokyo.green).frame(width: 6, height: 6)
                        Text("Running since \(session.startedAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(Tokyo.comment)
                        if session.requiresPresence {
                            Text("· stops when you’re idle").foregroundStyle(Tokyo.orange)
                        }
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    Text(hudDuration(session.startedAt, ctx.date))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(accent)
                }
                .fixedSize()

                Button {
                    store.stop()
                    vibecoders.publishStatus(nil)
                    onChanged()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokyo.red)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Tokyo.red.opacity(0.16), in: Capsule())
                        .frame(height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop the timer and add this period to history")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(accent.opacity(0.35), lineWidth: 0.5))
    }

    @ViewBuilder private func editRenameField(_ session: StatusSession) -> some View {
        HStack(spacing: 6) {
            HUDTextField(text: $editingRename,
                         placeholder: session.message.isEmpty ? "Activity label" : session.message,
                         fontSize: 13,
                         onSubmit: { commitRename(session) })
                .frame(width: 170, height: 20)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Tokyo.bgDark.opacity(0.7),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Tokyo.stroke(true), lineWidth: 0.5))
            Button("Save") { commitRename(session) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokyo.magenta)
            Button {
                renameTarget = nil
                editingRename = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Tokyo.comment)
            }.buttonStyle(.plain)
        }
    }

    private func commitRename(_ session: StatusSession) {
        let wasActive = store.active?.id == session.id
        store.setMessage(session.id, to: editingRename)
        // Only re-share when the RUNNING status's label changed; editing a
        // completed history row is local-only and must not touch the server.
        if wasActive { vibecoders.publishStatus(store.active) }
        onChanged()
        renameTarget = nil
        editingRename = ""
    }

    @ViewBuilder private var sharingState: some View {
        if vibecoders.statusSyncing {
            HStack(spacing: 10) {
                Spinner(size: 11, color: Tokyo.yellow).frame(width: 18)
                Text("Sharing active status with Crew…").foregroundStyle(Tokyo.fgDim)
            }
            .font(.system(size: 12))
        } else if let error = vibecoders.statusError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tokyo.orange).frame(width: 18)
                Text(error).foregroundStyle(Tokyo.orange).lineLimit(2)
                Spacer(minLength: 4)
                Button("Retry") { vibecoders.publishStatus(store.active) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokyo.magenta)
            }
            .font(.system(size: 12))
        } else if vibecoders.hasUsername {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11)).foregroundStyle(Tokyo.magenta).frame(width: 18)
                Text(store.active == nil
                     ? "Your next status is shared with Crew as @\(vibecoders.username)"
                     : "Shared with Crew as @\(vibecoders.username)")
                    .foregroundStyle(Tokyo.fgDim)
            }
            .font(.system(size: 12))
        } else {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11)).foregroundStyle(Tokyo.comment).frame(width: 18)
                Text("Local only until you join Crew").foregroundStyle(Tokyo.fgDim)
            }
            .font(.system(size: 12))
        }
    }
}

/// Control Center–style preset tile: emoji over label, tinted while running.
struct PresetTile: View {
    let activity: ActivityPreset
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let accent = Tokyo.activity(activity.rawValue)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(spacing: 4) {
                Text(activity.rawValue).font(.system(size: 22))
                HStack(spacing: 3) {
                    if selected { Image(systemName: "stop.fill").font(.system(size: 8)) }
                    Text(activity.label)
                }
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? accent : Tokyo.fgDim)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(selected ? accent.opacity(0.16) : Tokyo.surface(hovered ? 1 : 0), in: shape)
            .overlay(shape.strokeBorder(selected ? accent.opacity(0.55) : Tokyo.stroke(), lineWidth: selected ? 1 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(selected ? "Stop" : "Start") \(activity.label)")
        .accessibilityValue(selected ? "Running" : "Inactive")
        .help(selected ? "Stop and save \(activity.label)" : "Start \(activity.label); saves any running activity")
    }
}

struct StatusHistoryRow: View {
    let session: StatusSession
    var onEdit: () -> Void = {}
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Text(session.emoji.isEmpty ? "●" : session.emoji)
                .font(.system(size: 16)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayLabel)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let endedAt = session.endedAt {
                    Text(timeRange(to: endedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(Tokyo.comment).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokyo.comment)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0.0001)
            .help("Edit activity label")
            .accessibilityLabel("Edit activity label")
            if let endedAt = session.endedAt {
                Text(hudDuration(session.startedAt, endedAt))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit().foregroundStyle(Tokyo.activity(session.emoji))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 46)
        .background(hovered ? Tokyo.surface(1) : Color.clear)
        .onHover { hovered = $0 }
    }

    private func timeRange(to endedAt: Date) -> String {
        let start = session.startedAt.formatted(date: .abbreviated, time: .shortened)
        let endStyle: Date.FormatStyle.DateStyle = Calendar.current.isDate(session.startedAt, inSameDayAs: endedAt)
            ? .omitted : .abbreviated
        let end = endedAt.formatted(date: endStyle, time: .shortened)
        return "\(start) – \(end)"
    }
}

/// One person in the "Online now" strip: avatar, name, today's devtime.
struct OnlineAvatarButton: View {
    let user: VCOnlineUser
    let status: VCCrewStatus?
    let isMe: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                CrewAvatar(login: user.login, avatarPath: user.avatarUrl, size: 40, online: true)
                    .overlay(alignment: .topTrailing) {
                        if let status {
                            Text(status.emoji.isEmpty ? "●" : status.emoji)
                                .font(.system(size: 11))
                                .frame(width: 20, height: 20)
                                .background(Tokyo.bgHighlight, in: Circle())
                                .overlay(Circle().strokeBorder(Tokyo.bg, lineWidth: 1.5))
                                .offset(x: 5, y: -4)
                                .help(status.displayLabel)
                        }
                    }
                    .padding(.top, 4)
                Text(isMe ? "You" : (vcDisplayName(user.name) ?? user.login))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tokyo.fg)
                    .lineLimit(1).truncationMode(.tail)
                Text(vcDuration(user.devtimeToday))
                    .font(.system(size: 10))
                    .foregroundStyle(Tokyo.comment).monospacedDigit()
            }
            .frame(width: 76)
            .padding(.vertical, 4)
            .background(hovered ? Tokyo.surface(1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("View @\(user.login)'s profile")
    }
}

// MARK: - One PR row

struct PRCard: View {
    let pr: PR
    @ObservedObject var store: PRStore
    @State private var hovered = false
    @State private var scoreHovered = false
    /// Merging is irreversible, so the button arms on the first click and only
    /// fires on the second (auto-disarming after a few seconds).
    @State private var mergeArmed = false
    @State private var disarmTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            scoreBlock
            VStack(alignment: .leading, spacing: 4) {
                Text(pr.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)
                        .foregroundStyle(Tokyo.fgDim).lineLimit(1)
                    Text("#\(pr.number)").foregroundStyle(Tokyo.comment)
                    if let rc = pr.reviewCount {
                        Text("·").foregroundStyle(Tokyo.comment)
                        Text("\(rc) review\(rc == 1 ? "" : "s")")
                            .foregroundStyle(Tokyo.comment)
                            .help("\(rc) Greptile review\(rc == 1 ? "" : "s")")
                    }
                    if pr.reviewing { reviewingPill }
                    if let why = pr.mergeBlockReason, !pr.reviewing { blockPill(why) }
                }
                .font(.system(size: 11))
                HStack(spacing: 10) {
                    branchLine
                    freshnessLine
                }
            }
            Spacer(minLength: 8)
            if pr.canQuickMerge { mergeButton }
            rereviewButton
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(hovered ? Tokyo.surface(1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { openWebURL(pr.url) }
        .onHover { hovered = $0 }
        .help(pr.url)
        .onDisappear { disarmTask?.cancel() }
    }

    // Activity-style ring: the score at a glance, the fill shows how close to perfect.
    @ViewBuilder private var scoreBlock: some View {
        if let n = pr.scoreNum, let d = pr.scoreDen, d > 0 {
            ZStack {
                ScoreRing(fraction: Double(n) / Double(d), color: scoreColor)
                Text("\(n)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreColor)
            }
            .help("Greptile confidence \(n)/\(d)")
        } else if pr.reviewing || pr.triggering {
            ZStack {
                ScoreRing(fraction: 0, color: Tokyo.blue, dashed: true)
                Spinner(size: 16, color: Tokyo.blue)
            }
            .help("Greptile is reviewing")
        } else if pr.isDraft {
            ZStack {
                ScoreRing(fraction: 0, color: Tokyo.comment, dashed: true)
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tokyo.comment)
            }
            .help("Draft — Greptile usually waits until it’s ready for review")
        } else {
            // Not reviewed yet: a ghost ring that doubles as "Ask Greptile".
            Button {
                Task { await store.triggerReview(pr) }
            } label: {
                ZStack {
                    if scoreHovered {
                        Circle().fill(Tokyo.magenta.opacity(0.16))
                        Circle().strokeBorder(Tokyo.magenta.opacity(0.6), lineWidth: 1)
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Tokyo.magenta)
                    } else {
                        ScoreRing(fraction: 0, color: Tokyo.fgDim, dashed: true)
                        Text("?")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Tokyo.fgDim)
                    }
                }
                .frame(width: 40, height: 40)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { scoreHovered = $0 }
            .help("Not reviewed yet — click to ask Greptile (posts “@greptile”)")
        }
    }

    private var reviewingPill: some View {
        HStack(spacing: 5) {
            Spinner(size: 9, color: Tokyo.blue)
            if let since = pr.reviewingSince {
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    Text(hudDuration(since, ctx.date))
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokyo.blue)
                        .monospacedDigit()
                }
            } else {
                Text("Reviewing").font(.system(size: 10, weight: .medium)).foregroundStyle(Tokyo.blue)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 1)
        .background(Tokyo.blue.opacity(0.14), in: Capsule())
    }

    private func blockPill(_ text: String) -> some View {
        Text(text.capitalized)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Tokyo.orange)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(Tokyo.orange.opacity(0.13), in: Capsule())
            .help("GitHub won’t merge this right now: \(text)")
    }

    /// `head → base`: which branch lands where. A base that is another open PR's
    /// branch is a stack, so it's tinted magenta and names the PR underneath.
    @ViewBuilder private var branchLine: some View {
        if let head = pr.headRef, let base = pr.baseRef {
            let parent = store.parentPR(of: pr)
            let baseColor = parent == nil ? Tokyo.teal : Tokyo.magenta
            HStack(spacing: 5) {
                branchChip(head, icon: "arrow.triangle.branch", color: Tokyo.fgDim,
                           fill: Tokyo.surface(1), stroke: Tokyo.stroke())
                    .layoutPriority(0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(baseColor.opacity(0.85))
                branchChip(base, icon: parent == nil ? "arrow.triangle.merge" : "square.stack.3d.up",
                           color: baseColor, fill: baseColor.opacity(0.12),
                           stroke: baseColor.opacity(0.30))
                    .layoutPriority(1)
                if let parent {
                    Text("stacked on #\(parent.number)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokyo.magenta)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .help(parent.map { "Merges \(head) into \(base) — the branch of #\($0.number) “\($0.title)”" }
                  ?? "Merges \(head) into \(base)")
        }
    }

    private func branchChip(_ name: String, icon: String, color: Color,
                            fill: Color, stroke: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(stroke, lineWidth: 0.5))
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
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Tokyo.bgDark)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(mergeArmed ? Tokyo.orange : Tokyo.green, in: Capsule())
            .shadow(color: Tokyo.bgDark.opacity(0.4), radius: 1.5, y: 1)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pr.merging)
        .help(mergeArmed
              ? "Click again to squash-merge #\(pr.number)"
              : "Perfect \(pr.scoreNum ?? 5)/\(pr.scoreDen ?? 5) — squash-merge #\(pr.number)")
    }

    private var rereviewButton: some View {
        ToolbarIconButton(symbol: pr.triggering ? nil : "arrow.clockwise",
                          help: "Re-trigger Greptile (posts “@greptile”)") {
            Task { await store.triggerReview(pr) }
        }
        .disabled(pr.triggering)
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

// MARK: - GitHub Actions column (CI you triggered, e.g. via merges)

struct RunsColumn: View {
    @ObservedObject var store: PRStore
    /// The overlay is nonactivating; typing in search needs the app to take focus.
    var onTextEditing: (Bool) -> Void = { _ in }

    @State private var query = ""
    @State private var expanded: Set<String> = []
    @AppStorage("hud.actions.sort") private var sortRaw = RunSort.status.rawValue

    private var sort: RunSort { RunSort(rawValue: sortRaw) ?? .status }
    private var runningCount: Int { store.runs.filter { $0.isRunning }.count }
    private var othersRunning: Int { store.runs.filter { $0.isRunning && !$0.isMine }.count }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var stacks: [RunStack] {
        RunStack.stacks(from: store.runs.filter { RunStack.matches($0, query: trimmedQuery) }, sort: sort)
    }

    /// Search box + sort menu, Finder-toolbar style.
    private var filterBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tokyo.comment)
                HUDTextField(text: $query, placeholder: "Search workflows, jobs…",
                             fontSize: 12, onEditing: onTextEditing)
                    .frame(height: 18)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Tokyo.comment)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Tokyo.bgDark.opacity(0.65), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Tokyo.stroke(), lineWidth: 0.5))

            Menu {
                Picker("Sort by", selection: $sortRaw) {
                    ForEach(RunSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(sort == .status ? Tokyo.fgDim : Tokyo.cyan)
            .frame(width: 28, height: 28)
            .background(sort == .status ? Color.clear : Tokyo.cyan.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .fixedSize()
            .help("Sort: \(sort.label)")
        }
    }

    /// Mine ↔ Everyone. Watching the whole queue is the point when you're stuck
    /// behind someone else's deploy.
    private var actorToggle: some View {
        SegmentedControl<Bool>(
            segments: [
                .init(value: false, label: "Mine", busy: !store.showAllActors && store.runsRefreshing),
                .init(value: true,
                      label: othersRunning > 0 && store.showAllActors ? "Queue · \(othersRunning)" : "Everyone",
                      busy: store.showAllActors && store.runsRefreshing),
            ],
            selection: store.showAllActors,
            height: 28,
            accent: { _ in Tokyo.cyan },
            onSelect: { store.showAllActors = $0 }
        )
        .help(store.showAllActors ? "Showing everyone’s runs" : "Showing your runs")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokyo.yellow)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.showAllActors ? "Actions" : "Your Actions")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).fixedSize()
                    Text(store.showAllActors ? "Everyone’s workflows" : "Recent workflows")
                        .font(.system(size: 10)).foregroundStyle(Tokyo.comment)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if runningCount > 0 {
                    HStack(spacing: 5) {
                        Spinner(size: 9, color: Tokyo.blue)
                        Text("\(runningCount)").font(.system(size: 11, weight: .medium)).foregroundStyle(Tokyo.blue)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Tokyo.blue.opacity(0.16), in: Capsule())
                    .fixedSize()
                }
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)
            actorToggle
                .padding(.horizontal, 12).padding(.bottom, 8)
            filterBar
                .padding(.horizontal, 12).padding(.bottom, 12)
            ZStack(alignment: .top) {
                Rectangle().fill(Tokyo.line).frame(height: 0.5)
                if store.runsRefreshing { IndeterminateBar() }
            }
            .frame(height: 1)
            ScrollView {
                Group {
                    if store.runsRefreshing && store.runs.isEmpty {
                        InsetGroup {
                            ForEach(0..<3, id: \.self) { i in
                                if i > 0 { RowDivider(inset: 33) }
                                RunRowSkeleton()
                            }
                        }
                    } else if stacks.isEmpty && !trimmedQuery.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 22, weight: .light))
                            Text("No runs match “\(trimmedQuery)”")
                                .font(.system(size: 12, weight: .medium))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Tokyo.comment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    } else {
                        InsetList(items: stacks, dividerInset: 33) { st in
                            RunRow(run: st.lead, stack: st, showActor: store.showAllActors,
                                   expanded: expanded.contains(st.key)) {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    if expanded.contains(st.key) { expanded.remove(st.key) }
                                    else { expanded.insert(st.key) }
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .padding(12)
                .animation(.easeInOut(duration: 0.22), value: stacks.map(\.id))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Tokyo.bgDark.opacity(0.35))
    }
}

struct RunRow: View {
    let run: WorkflowRun
    /// The stack this row leads, when runs of one workflow file were collapsed.
    var stack: RunStack? = nil
    /// Show who owns the run — on in "Everyone" mode, where authorship is the point.
    var showActor: Bool = false
    var expanded: Bool = false
    var onToggleExpand: () -> Void = {}
    @State private var hovered = false

    private var stackCount: Int { stack?.count ?? 1 }

    /// The YAML file, when it adds something: hidden when it's already the row
    /// title or just restates the workflow name ("CI" ↔ ci.yml).
    private var shownFile: String? {
        guard let file = run.workflowFile, !mixedNames else { return nil }
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let stem = squash(file.replacingOccurrences(of: ".yaml", with: "").replacingOccurrences(of: ".yml", with: ""))
        let name = squash(run.name)
        if stem.isEmpty || name.contains(stem) || stem.contains(name) { return nil }
        return file
    }
    private var mixedNames: Bool { stack?.hasMixedNames ?? false }

    private var showsChip: Bool { (showActor || !run.isMine) && run.actor != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            statusGlyph.frame(width: 14, height: 15)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(stack?.title ?? run.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if stackCount > 1 { stackBadge }
                }
                if showsChip, let who = run.actor {
                    Text("@\(who)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(run.isMine ? Tokyo.blue : Tokyo.yellow)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((run.isMine ? Tokyo.blue : Tokyo.yellow).opacity(0.13), in: Capsule())
                }
                // Collapsed by YAML file with differing run-names: the lead's own
                // name is the useful subtitle; otherwise the commit/PR title.
                let subtitle = mixedNames ? run.name : run.title
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Tokyo.comment).lineLimit(1)
                }
                if let file = shownFile {
                    Label(file, systemImage: "doc.text")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokyo.comment)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let step = run.stepLine { stepLine(step) }
                HStack(spacing: 4) {
                    stateBadge
                    Spacer(minLength: 4)
                    timer
                }
                if expanded, let stack { stackMembers(stack) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? Tokyo.surface(1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { openWebURL(run.url) }
        .onHover { hovered = $0 }
        .help(stackCount > 1
              ? "\(stackCount) runs of \(run.workflowFile ?? "“\(run.name)”") — showing the oldest · \(run.branch) · \(run.event)"
              : [run.workflowFile, run.branch, run.event].compactMap { $0 }.joined(separator: " · "))
    }

    /// "⌄ 6" — how many runs of this workflow file are folded in; click to list them.
    private var stackBadge: some View {
        Button(action: onToggleExpand) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("\(stackCount)").monospacedDigit()
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(expanded ? Tokyo.cyan : Tokyo.fgDim)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(expanded ? Tokyo.cyan.opacity(0.15) : Tokyo.surface(2), in: Capsule())
            .contentShape(Rectangle().inset(by: -7))   // bigger hit target than it looks
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(expanded ? "Hide the stacked runs"
                       : "\(stackCount) runs of \(run.workflowFile ?? "this workflow") — click to list them")
    }

    /// The other runs folded into this stack, newest last, each opening on click.
    private func stackMembers(_ stack: RunStack) -> some View {
        let rest = Array(stack.runs.dropFirst())
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rest.prefix(8)) { r in
                StackMemberRow(run: r)
            }
            if rest.count > 8 {
                Text("and \(rest.count - 8) more")
                    .font(.system(size: 10)).foregroundStyle(Tokyo.comment)
                    .padding(.top, 3)
            }
        }
        .padding(.top, 2)
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


    /// Leading status symbol, like a Mail/Xcode issue row.
    @ViewBuilder private var statusGlyph: some View {
        if run.isRunning {
            Spinner(size: 12, color: color)
        } else {
            Image(systemName: iconName + ".circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(color)
        }
    }

    private var stateBadge: some View {
        Text(label.capitalized)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
    }

    @ViewBuilder private var timer: some View {
        if run.isRunning, let start = run.startedAt {
            TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                Text(hudDuration(start, ctx.date))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Tokyo.fgDim)
            }
        } else if let start = run.startedAt, let end = run.updatedAt {
            Text(hudDuration(start, end))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Tokyo.comment)
        }
    }
}

/// One folded-in run under an expanded stack: name, branch, elapsed. Opens on click.
struct StackMemberRow: View {
    let run: WorkflowRun
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Tokyo.line).frame(width: 1, height: 16)
            Text(run.name == run.title || run.title.isEmpty ? run.name : "\(run.name) — \(run.title)")
                .font(.system(size: 10))
                .foregroundStyle(hovered ? Tokyo.fg : Tokyo.fgDim)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let start = run.startedAt {
                if run.isRunning {
                    TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                        Text(hudDuration(start, ctx.date))
                    }
                } else {
                    Text("\(hudAgo(start)) ago")
                }
            }
        }
        .font(.system(size: 10)).monospacedDigit()
        .foregroundStyle(Tokyo.comment)
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { openWebURL(run.url) }
        .help([run.branch, run.actor.map { "@\($0)" }].compactMap { $0 }.joined(separator: " · "))
    }
}

// MARK: - One leaderboard row (Crew tab)

struct CrewRow: View {
    let entry: VCLeaderboardEntry
    var isMe: Bool = false
    var onSelect: () -> Void = {}
    @State private var hovered = false

    private var rankColor: Color {
        switch entry.rank {
        case 1: return Tokyo.yellow     // gold
        case 2: return Tokyo.fg         // silver
        case 3: return Tokyo.orange     // bronze
        default: return Tokyo.comment
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text("\(entry.rank)")
                    .font(.system(size: 13, weight: entry.rank <= 3 ? .bold : .medium, design: .rounded))
                    .foregroundStyle(rankColor)
                    .monospacedDigit()
                    .frame(width: 22)
                CrewAvatar(login: entry.login, avatarPath: entry.avatarUrl, size: 28, online: entry.online)
                Text(vcDisplayName(entry.name) ?? entry.login)
                    .font(.system(size: 13, weight: isMe ? .semibold : .regular))
                    .lineLimit(1)
                if isMe {
                    Text("You")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Tokyo.magenta)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Tokyo.magenta.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 6)
                Text(vcDuration(entry.value))
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(isMe ? Tokyo.magenta : Tokyo.fgDim)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(hovered ? Tokyo.surface(1) : (isMe ? Tokyo.magenta.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(entry.online ? "View @\(entry.login)'s profile · online now" : "View @\(entry.login)'s profile")
    }
}

// MARK: - One merged-PR row (Merged tab)

struct MergedRow: View {
    let pr: MergedPR
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokyo.magenta)
                .frame(width: 32, height: 32)
                .background(Tokyo.magenta.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(pr.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)
                        .foregroundStyle(Tokyo.fgDim).lineLimit(1)
                    Text("#\(pr.number)").foregroundStyle(Tokyo.comment)
                    if let m = pr.mergedAt {
                        Text("·").foregroundStyle(Tokyo.comment)
                        Text("Merged \(hudAgo(m)) ago").foregroundStyle(Tokyo.comment)
                    }
                }
                .font(.system(size: 11))
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokyo.comment.opacity(hovered ? 1 : 0))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minHeight: 50)
        .background(hovered ? Tokyo.surface(1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { openWebURL(pr.url) }
        .onHover { hovered = $0 }
        .help(pr.url)
    }
}
