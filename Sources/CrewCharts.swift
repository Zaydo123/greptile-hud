import AppKit
import SwiftUI

// MARK: - Profile photos

/// In-memory cache for avatar images, keyed by the versioned URL — a new
/// upload changes `v=` so stale entries are simply never asked for again.
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let running = inflight[url] { return await running.value }
        let task = Task<NSImage?, Never> {
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return NSImage(data: data)
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// Photo when the person has one, initials otherwise, plus an optional
/// presence dot.
struct CrewAvatar: View {
    let login: String
    var avatarPath: String? = nil
    var size: CGFloat = 28
    var online: Bool? = nil

    @State private var image: NSImage?

    private var url: URL? { vcAvatarURL(avatarPath) }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Text(String(login.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(Tokyo.magenta)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        LinearGradient(colors: [Tokyo.magenta.opacity(0.26), Tokyo.blue.opacity(0.14)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Tokyo.fg.opacity(0.08), lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            if online == true {
                Circle().fill(Tokyo.green)
                    .frame(width: max(7, size * 0.24), height: max(7, size * 0.24))
                    .overlay(Circle().strokeBorder(Tokyo.bg, lineWidth: max(1.5, size * 0.05)))
                    .offset(x: 1, y: 1)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = AvatarCache.shared.cached(url) { image = hit; return }
            image = await AvatarCache.shared.load(url)
        }
    }
}

// MARK: - Usage breakdown

extension Tokyo {
    /// One accent per usage category, shared by every chart and legend.
    static func category(_ name: String) -> Color {
        switch name {
        case "Dev": return blue
        case "AI": return magenta
        case "Crew": return yellow
        case "Communication": return cyan
        case "Productivity": return teal
        case "Social": return orange
        case "Video": return red
        case "Music": return green
        case "Finance": return yellow.opacity(0.75)
        case "Shopping": return orange.opacity(0.7)
        case "News": return fgDim
        case "Games": return purple.opacity(0.7)
        default: return comment
        }
    }
}

/// Apps & sites: a 100%-stacked category bar with a legend, then the top
/// items as labelled bars.
struct UsageBreakdown: View {
    let report: VCUsageReport
    var maxItems = 8
    var showPeople = false

    private struct CategoryShare: Identifiable {
        let name: String
        let seconds: Int64
        var id: String { name }
    }

    private var categories: [CategoryShare] {
        var totals: [String: Int64] = [:]
        for i in report.items { totals[i.category, default: 0] += i.seconds }
        return totals.map { CategoryShare(name: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
    }

    private var total: Int64 { max(1, report.items.reduce(0) { $0 + $1.seconds }) }

    var body: some View {
        let cats = categories
        let top = Array(report.items.filter { $0.key != "other" }.prefix(maxItems))
        let other = report.items.first { $0.key == "other" }
        let rows = top + (other.map { [$0] } ?? [])
        let maxSeconds = max(1, rows.map(\.seconds).max() ?? 1)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                // Stacked category bar.
                GeometryReader { geo in
                    HStack(spacing: 1.5) {
                        ForEach(cats) { c in
                            Rectangle()
                                .fill(Tokyo.category(c.name))
                                .frame(width: max(2, (geo.size.width - CGFloat(cats.count - 1) * 1.5)
                                                    * CGFloat(c.seconds) / CGFloat(total)))
                                .help("\(c.name) · \(vcDuration(c.seconds)) · \(percent(c.seconds))")
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())

                // Legend.
                FlowRow(spacing: 10, lineSpacing: 4) {
                    ForEach(cats.prefix(7)) { c in
                        HStack(spacing: 4) {
                            Circle().fill(Tokyo.category(c.name)).frame(width: 7, height: 7)
                            Text(c.name).foregroundStyle(Tokyo.fgDim)
                            Text(percent(c.seconds)).foregroundStyle(Tokyo.comment).monospacedDigit()
                        }
                        .font(.system(size: 11))
                    }
                }
            }
            .padding(12)

            ForEach(rows) { item in
                RowDivider(inset: 12)
                UsageItemRow(item: item, fraction: Double(item.seconds) / Double(maxSeconds),
                             share: percent(item.seconds), showPeople: showPeople)
            }
        }
    }

    private func percent(_ s: Int64) -> String {
        let p = Double(s) / Double(total) * 100
        return p < 1 ? "<1%" : "\(Int(p.rounded()))%"
    }
}

private struct UsageItemRow: View {
    let item: VCUsageItem
    let fraction: Double
    let share: String
    let showPeople: Bool
    @State private var hovered = false

    var body: some View {
        let color = Tokyo.category(item.category)
        HStack(spacing: 10) {
            Text(item.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.key == "other" ? Tokyo.comment : Tokyo.fg)
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tokyo.surface(1))
                    Capsule().fill(color.opacity(hovered ? 1 : 0.85))
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 8)
            if showPeople, let p = item.people {
                Label("\(p)", systemImage: "person.fill")
                    .font(.system(size: 10)).foregroundStyle(Tokyo.comment)
                    .labelStyle(.titleAndIcon)
                    .frame(width: 34, alignment: .trailing)
                    .help("\(p) \(p == 1 ? "person" : "people")")
            }
            Text(vcDuration(item.seconds))
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(Tokyo.fgDim)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(hovered ? Tokyo.surface(1) : Color.clear)
        .onHover { hovered = $0 }
        .help("\(item.label) · \(item.category) · \(share)")
    }
}

/// Minimal wrapping row for legends (macOS 13 has `Layout`).
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += s.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, s.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

// MARK: - Daily devtime columns

/// One column per crew day. Today is highlighted; hovering a column shows
/// its exact total.
struct DailyBars: View {
    let days: [VCDay]
    var height: CGFloat = 96

    private static let parse: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let todayKey: String = {
        parse.string(from: Date())
    }()

    var body: some View {
        let maxS = max(1, days.map(\.seconds).max() ?? 1)
        let total = days.reduce(Int64(0)) { $0 + $1.seconds }
        let active = days.filter { $0.seconds > 0 }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                metric("Total", vcDuration(total))
                metric("Daily average", vcDuration(active == 0 ? 0 : total / Int64(active)))
                metric("Active days", "\(active)/\(days.count)")
                Spacer()
            }
            HStack(alignment: .bottom, spacing: days.count > 14 ? 3 : 6) {
                ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                    DayColumn(day: d, fraction: Double(d.seconds) / Double(maxS),
                              label: label(for: d, index: i),
                              isToday: d.day == Self.todayKey,
                              height: height)
                }
            }
        }
        .padding(12)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(Tokyo.comment)
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(Tokyo.fg)
        }
    }

    /// Weekday initials for a week, day-of-month every few days for a month.
    private func label(for d: VCDay, index: Int) -> String {
        guard let date = Self.parse.date(from: d.day) else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.parse.timeZone
        if days.count <= 10 {
            let f = DateFormatter()
            f.dateFormat = "EEEEE"
            f.timeZone = Self.parse.timeZone
            return f.string(from: date)
        }
        let dom = cal.component(.day, from: date)
        return (dom == 1 || dom % 5 == 0) ? "\(dom)" : ""
    }
}

private struct DayColumn: View {
    let day: VCDay
    let fraction: Double
    let label: String
    let isToday: Bool
    let height: CGFloat
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Tokyo.surface(0))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isToday ? Tokyo.magenta : Tokyo.magenta.opacity(hovered ? 0.9 : 0.6))
                    .frame(height: day.seconds > 0 ? max(3, height * fraction) : 0)
            }
            .frame(height: height)
            Text(label)
                .font(.system(size: 9, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Tokyo.magenta : Tokyo.comment)
                .frame(height: 11)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help("\(day.day) · \(vcDuration(day.seconds))")
    }
}

// MARK: - Activities (statuses) per emoji

struct ActivityBreakdown: View {
    let totals: [VCActivityTotal]

    var body: some View {
        let maxS = max(1, totals.map(\.seconds).max() ?? 1)
        VStack(spacing: 0) {
            ForEach(Array(totals.enumerated()), id: \.element.id) { i, t in
                if i > 0 { RowDivider(inset: 40) }
                let accent = Tokyo.activity(t.emoji)
                HStack(spacing: 10) {
                    Text(t.emoji.isEmpty ? "●" : t.emoji).font(.system(size: 15)).frame(width: 18)
                    Text(ActivityPreset(rawValue: t.emoji)?.label ?? "Status")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 70, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Tokyo.surface(1))
                            Capsule().fill(accent.opacity(0.85))
                                .frame(width: max(4, geo.size.width * Double(t.seconds) / Double(maxS)))
                        }
                    }
                    .frame(height: 8)
                    Text("×\(t.count)")
                        .font(.system(size: 10)).foregroundStyle(Tokyo.comment)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                    Text(vcDuration(t.seconds))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(accent)
                        .frame(width: 62, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
            }
        }
    }
}
