import SwiftUI
import AppKit

// MARK: - Spinner (TimelineView so it animates even while our app isn't key)

struct Spinner: View {
    var size: CGFloat = 14
    var color: Color = .blue
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

// MARK: - Overlay

struct HUDView: View {
    @ObservedObject var store: PRStore
    var onClose: () -> Void = {}

    @State private var tab: Tab = .open
    private enum Tab { case open, merged }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                tabBar
                if let err = store.errorText {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }
                Divider().opacity(0.12)
                content
            }
            .frame(width: 540)

            if !store.runs.isEmpty {
                Divider().opacity(0.12)
                RunsColumn(store: store).frame(width: 240)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.10)))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 30, y: 14)
        .padding(24)
        .preferredColorScheme(.dark)
    }

    private var reviewingCount: Int { store.prs.filter { $0.reviewing }.count }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "eyes").font(.system(size: 17, weight: .semibold))
            Text("Greptile Reviews").font(.system(size: 16, weight: .bold))
            if !store.prs.isEmpty {
                Text("\(store.prs.count)")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.white.opacity(0.14), in: Capsule())
            }
            if reviewingCount > 0 {
                HStack(spacing: 5) {
                    Spinner(size: 10, color: .blue)
                    Text("\(reviewingCount) reviewing")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.blue)
                }
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Color.blue.opacity(0.16), in: Capsule())
            }
            Spacer()
            if store.refreshing { Spinner(size: 12, color: .secondary).frame(width: 14, height: 14) }
            if let d = store.lastRefresh {
                Text(relative(d)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .open:   openContent
        case .merged: mergedContent
        }
    }

    // Segmented Open / Merged switcher for the main list.
    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton("Open", count: store.prs.count, on: tab == .open) { tab = .open }
            tabButton("Merged", count: store.merged.count, on: tab == .merged) { tab = .merged }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.bottom, 11)
    }

    private func tabButton(_ label: String, count: Int, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 12, weight: .semibold))
                if count > 0 {
                    Text("\(count)").font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.white.opacity(on ? 0.18 : 0.10), in: Capsule())
                }
            }
            .foregroundStyle(on ? Color.primary : .secondary)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(on ? Color.white.opacity(0.12) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var openContent: some View {
        if store.prs.isEmpty {
            emptyState(icon: store.refreshing ? "hourglass" : "checkmark.seal",
                       text: store.refreshing ? "Loading your PRs…" : "No open PRs")
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.prs) { pr in PRCard(pr: pr, store: store) }
                }
                .padding(12)
            }
            .frame(maxHeight: 540)
        }
    }

    @ViewBuilder private var mergedContent: some View {
        if store.merged.isEmpty {
            emptyState(icon: store.refreshing ? "hourglass" : "tray",
                       text: store.refreshing ? "Loading…" : "No recent merges")
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.merged) { m in MergedRow(pr: m) }
                }
                .padding(12)
            }
            .frame(maxHeight: 540)
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36)
    }

    private func relative(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 5 { return "synced just now" }
        if s < 60 { return "synced \(s)s ago" }
        return "synced \(s / 60)m ago"
    }
}

// MARK: - One PR row

struct PRCard: View {
    let pr: PR
    @ObservedObject var store: PRStore

    /// The one color that tells the whole story at a glance.
    private var statusColor: Color { pr.reviewing ? .blue : scoreColor }

    var body: some View {
        HStack(spacing: 0) {
            // Status stripe — scan this column to read every PR's state instantly.
            Rectangle().fill(statusColor).frame(width: 5)

            HStack(spacing: 14) {
                scoreBlock
                VStack(alignment: .leading, spacing: 4) {
                    Text(pr.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 7) {
                        Text(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                        Text("#\(pr.number)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        if let rc = pr.reviewCount {
                            Text("· \(rc)×").font(.system(size: 12)).foregroundStyle(.secondary.opacity(0.7))
                                .help("\(rc) Greptile review\(rc == 1 ? "" : "s")")
                        }
                        if pr.reviewing { reviewingPill }
                    }
                    freshnessLine
                }
                Spacer(minLength: 8)
                rereviewButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(statusColor.opacity(pr.reviewing ? 0.12 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(statusColor.opacity(pr.reviewing ? 0.55 : 0.18), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture { openWebURL(pr.url) }
        .help(pr.url)
    }

    // Big, bold score — the primary thing your eye lands on.
    private var scoreBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(scoreColor.opacity(0.20))
            if pr.hasScore {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(pr.scoreNum ?? 0)")
                        .font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(scoreColor)
                    Text("/\(pr.scoreDen ?? 5)")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(scoreColor.opacity(0.75))
                }
            } else if pr.reviewing {
                Spinner(size: 20, color: .blue)
            } else {
                Text("—").font(.system(size: 22, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 52)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(scoreColor.opacity(0.4)))
    }

    private var reviewingPill: some View {
        HStack(spacing: 5) {
            Spinner(size: 10, color: .blue)
            if let since = pr.reviewingSince {
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    Text(elapsed(since, ctx.date))
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.blue)
                        .monospacedDigit()
                }
            } else {
                Text("reviewing…").font(.system(size: 12, weight: .bold)).foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Color.blue.opacity(0.18), in: Capsule())
    }

    // Push/review recency — when the PR last got a commit and when Greptile last reviewed.
    @ViewBuilder private var freshnessLine: some View {
        if pr.lastCommitAt != nil || pr.lastReviewAt != nil {
            HStack(spacing: 8) {
                if let c = pr.lastCommitAt {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 9))
                        Text("last pushed \(ago(c)) ago").font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
                if let r = pr.lastReviewAt {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 9))
                        Text("last reviewed \(ago(r)) ago").font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func ago(_ d: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(d)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    private var rereviewButton: some View {
        Button {
            Task { await store.triggerReview(pr) }
        } label: {
            ZStack {
                Circle().fill(.white.opacity(0.10)).frame(width: 38, height: 38)
                if pr.triggering {
                    Spinner(size: 16, color: .primary)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(pr.triggering)
        .help("Re-trigger Greptile (posts “@greptile”)")
    }

    private var scoreColor: Color {
        guard let n = pr.scoreNum, let d = pr.scoreDen, d > 0 else { return .gray }
        let r = Double(n) / Double(d)
        if r >= 0.8 { return .green }
        if r >= 0.6 { return .yellow }
        if r >= 0.4 { return .orange }
        return .red
    }

    private func elapsed(_ from: Date, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(from)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
}

// MARK: - GitHub Actions column (CI you triggered, e.g. via merges)

struct RunsColumn: View {
    @ObservedObject var store: PRStore

    private var runningCount: Int { store.runs.filter { $0.isRunning }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "bolt.fill").font(.system(size: 13, weight: .semibold))
                Text("Your Actions").font(.system(size: 14, weight: .bold))
                Spacer()
                if runningCount > 0 {
                    HStack(spacing: 5) {
                        Spinner(size: 9, color: .blue)
                        Text("\(runningCount)").font(.system(size: 11, weight: .bold)).foregroundStyle(.blue)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.blue.opacity(0.16), in: Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            Divider().opacity(0.12)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.runs) { run in RunRow(run: run) }
                }
                .padding(12)
            }
            .frame(maxHeight: 540)
        }
    }
}

struct RunRow: View {
    let run: WorkflowRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if !run.title.isEmpty {
                Text(run.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                stateBadge
                Spacer(minLength: 4)
                timer
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(color.opacity(0.32), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture { openWebURL(run.url) }
        .help("\(run.branch) · \(run.event)")
    }

    private var color: Color {
        if run.isRunning { return .blue }
        switch run.conclusion {
        case "success": return .green
        case "failure", "timed_out", "startup_failure": return .red
        case "cancelled", "skipped": return .gray
        default: return .yellow
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
                Text(duration(start, ctx.date))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
        } else if let start = run.startedAt, let end = run.updatedAt {
            Text(duration(start, end))
                .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func duration(_ from: Date, _ to: Date) -> String {
        let s = max(0, Int(to.timeIntervalSince(from)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
}

// MARK: - One merged-PR row (Merged tab)

struct MergedRow: View {
    let pr: MergedPR

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.purple).frame(width: 5)
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pr.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 7) {
                        Text(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                        Text("#\(pr.number)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        if let m = pr.mergedAt {
                            Text("· merged \(ago(m)) ago").font(.system(size: 12)).foregroundStyle(.secondary.opacity(0.8))
                        }
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(Color.purple.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Color.purple.opacity(0.18), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture { openWebURL(pr.url) }
        .help(pr.url)
    }

    private func ago(_ d: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(d)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
