import SwiftUI
import AppKit

enum HUDMetrics {
    static let contentWidth: CGFloat = 780
    static let contentHeight: CGFloat = 560
    static let padding: CGFloat = 24
    static let panelWidth = contentWidth + padding * 2
    static let panelHeight = contentHeight + padding * 2
}

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
    @ObservedObject var vibecoders: VibecodersStore
    var onClose: () -> Void = {}

    @State private var tab: Tab = .open
    @State private var showStale: Bool = false
    @State private var staleHovered: Bool = false
    private enum Tab { case open, merged, crew }

    private static let staleThreshold: TimeInterval = 14 * 86400

    private func isStale(_ pr: PR) -> Bool {
        let last = pr.updatedAt ?? pr.lastCommitAt ?? .distantPast
        return Date().timeIntervalSince(last) > Self.staleThreshold
    }

    private var freshPRs: [PR] { store.prs.filter { !isStale($0) } }
    private var stalePRs: [PR] { store.prs.filter { isStale($0) } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                tabBar
                if let err = store.errorText {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(err).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(Color.orange.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 16).padding(.bottom, 10)
                }
                Divider().opacity(0.10)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !store.runs.isEmpty {
                Divider().opacity(0.10)
                RunsColumn(store: store).frame(width: 240)
            }
        }
        .frame(width: HUDMetrics.contentWidth, height: HUDMetrics.contentHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.13)))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.48), radius: 28, y: 12)
        .padding(HUDMetrics.padding)
        .preferredColorScheme(.dark)
    }

    private var reviewingCount: Int { store.prs.filter { $0.reviewing }.count }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "eyes")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(Color.blue.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.blue.opacity(0.20)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Greptile Reviews").font(.system(size: 15, weight: .bold))
                Text("Pull request overview")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if !store.prs.isEmpty {
                Text("\(store.prs.count)")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.white.opacity(0.10), in: Capsule())
            }
            Spacer(minLength: 8)
            if reviewingCount > 0 {
                HStack(spacing: 5) {
                    Spinner(size: 10, color: .blue)
                    Text("\(reviewingCount) active")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.blue.opacity(0.13), in: Capsule())
            }
            if let d = store.lastRefresh {
                Text(relative(d))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Button { Task { await store.refresh(force: true) } } label: {
                Group {
                    if store.refreshing { Spinner(size: 12, color: .secondary) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(store.refreshing)
            .help("Refresh now")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
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
        HStack(spacing: 4) {
            tabButton("Open", icon: "arrow.triangle.branch", count: store.prs.count, on: tab == .open) {
                tab = .open
            }
            tabButton("Merged", icon: "arrow.triangle.merge", count: store.merged.count, on: tab == .merged) {
                tab = .merged
            }
            tabButton("Crew", icon: "person.3", count: vibecoders.online.count, on: tab == .crew) {
                tab = .crew
            }
        }
        .padding(4)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(.white.opacity(0.06)))
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func tabButton(_ label: String, icon: String, count: Int, on: Bool,
                           _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(on ? Color.primary : .secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(on ? 0.12 : 0.06), in: Capsule())
            }
            .foregroundStyle(on ? Color.primary : .secondary)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(on ? Color.white.opacity(0.11) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(on ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(label.lowercased())")
    }

    @ViewBuilder private var openContent: some View {
        if store.prs.isEmpty {
            emptyState(icon: store.refreshing ? "hourglass" : "checkmark.seal",
                       text: store.refreshing ? "Loading your PRs…" : "No open PRs")
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(freshPRs) { pr in PRCard(pr: pr, store: store) }
                    if !stalePRs.isEmpty {
                        staleDisclosure
                        if showStale {
                            ForEach(stalePRs) { pr in PRCard(pr: pr, store: store) }
                        }
                    }
                }
                .padding(12)
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
                    .background(.white.opacity(0.08), in: Capsule())
                Spacer()
                Text(showStale ? "Hide" : "Show")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(showStale ? 90 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(.white.opacity(staleHovered ? 0.09 : 0.045),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(staleHovered ? 0.13 : 0.065)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { staleHovered = $0 }
        .help(showStale ? "Hide stale pull requests" : "Show stale pull requests")
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.055), in: Circle())
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Crew tab (vibecoders)

    @ViewBuilder private var crewContent: some View {
        if !vibecoders.isSignedIn {
            VStack(spacing: 14) {
                Image(systemName: "person.3")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.purple)
                    .frame(width: 56, height: 56)
                    .background(Color.purple.opacity(0.12), in: Circle())
                Text("Join the vibecoders leaderboard")
                    .font(.system(size: 14, weight: .semibold))
                Text("Sign in with GitHub to see who's online, who vibes hardest,\nand exactly how much devtime you've banked today.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    vibecoders.signIn()
                } label: {
                    Text("Sign in with GitHub")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Color.purple.opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.purple.opacity(0.5)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let err = vibecoders.errorText {
                    Text(err).font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                crewHeader
                Divider().opacity(0.10)
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

    private var crewHeader: some View {
        HStack(spacing: 10) {
            if let url = vibecoders.user?.avatarUrl, let u = URL(string: url) {
                AsyncImage(url: u) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(vibecoders.login.isEmpty ? "" : "@\(vibecoders.login)")
                    .font(.system(size: 13, weight: .bold))
                if let name = vcDisplayName(vibecoders.user?.name) {
                    Text(name)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.purple)
                Text("\(vcDuration(vibecoders.devtimeToday)) today")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.purple.opacity(0.13), in: Capsule())
            Button {
                vibecoders.syncNow()
            } label: {
                Group {
                    if vibecoders.syncing { Spinner(size: 11, color: .secondary) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(vibecoders.syncing)
            .help("Sync GitHub stats now")
            Button {
                vibecoders.signOut()
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Sign out")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var onlineStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Online now")
                    .font(.system(size: 10, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .kerning(1.2)
                if !vibecoders.online.isEmpty {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                }
                Spacer()
            }
            if vibecoders.online.isEmpty {
                Text("Nobody vibing right now — first heartbeat within 5 minutes of launching an editor counts.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vibecoders.online, id: \.login) { u in
                            HStack(spacing: 7) {
                                Circle().fill(Color.green).frame(width: 7, height: 7)
                                if let url = u.avatarUrl, let uu = URL(string: url) {
                                    AsyncImage(url: uu) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: {
                                        Image(systemName: "person.crop.circle.fill")
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                    .frame(width: 20, height: 20).clipShape(Circle())
                                } else {
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Text(vcDisplayName(u.name) ?? u.login)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1).truncationMode(.tail)
                                Text(vcDuration(u.devtimeToday))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(minHeight: 32)
                            .background(.white.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(11)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.06)))
    }

    private var leaderboardBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Leaderboard")
                    .font(.system(size: 10, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .kerning(1.2)
                Spacer(minLength: 4)
                ForEach(VCMetric.allCases, id: \.self) { m in
                    metricButton(m, on: vibecoders.selectedMetric == m) {
                        vibecoders.selectedMetric = m
                    }
                }
            }
            let entries = vibecoders.leaderboard(for: vibecoders.selectedMetric)
            if entries.isEmpty {
                Text("No stats yet — stats sync after sign-in and every few hours.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 18)
            } else {
                VStack(spacing: 6) {
                    ForEach(entries.prefix(10), id: \.login) { e in
                        CrewRow(entry: e, metric: vibecoders.selectedMetric)
                    }
                }
            }
            if let err = vibecoders.errorText {
                Text(err).font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .padding(11)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.06)))
    }

    private func metricButton(_ m: VCMetric, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(m.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Color.primary : .secondary)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(on ? Color.purple.opacity(0.22) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(on ? 0.10 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(m.label.lowercased()) leaderboard")
    }

    private func relative(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 5 { return "Just synced" }
        if s < 60 { return "Synced \(s)s ago" }
        return "Synced \(s / 60)m ago"
    }
}

// MARK: - One PR row

struct PRCard: View {
    let pr: PR
    @ObservedObject var store: PRStore
    @State private var hovered = false

    /// The one color that tells the whole story at a glance.
    private var statusColor: Color { pr.reviewing ? .blue : scoreColor }

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
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Text("#\(pr.number)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    if let rc = pr.reviewCount {
                        Text("\(rc) review\(rc == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.75))
                            .help("\(rc) Greptile review\(rc == 1 ? "" : "s")")
                    }
                    if pr.reviewing { reviewingPill }
                }
                freshnessLine
            }
            Spacer(minLength: 8)
            rereviewButton
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(.white.opacity(hovered ? 0.085 : 0.05),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(pr.reviewing ? Color.blue.opacity(0.32) : Color.white.opacity(0.075), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { openWebURL(pr.url) }
        .onHover { hovered = $0 }
        .help(pr.url)
    }

    // Big, bold score — the primary thing your eye lands on.
    private var scoreBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(scoreColor.opacity(0.12))
            if pr.hasScore {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(pr.scoreNum ?? 0)")
                        .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(scoreColor)
                    Text("/\(pr.scoreDen ?? 5)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(scoreColor.opacity(0.72))
                }
            } else if pr.reviewing {
                Spinner(size: 20, color: .blue)
            } else {
                Text("—").font(.system(size: 22, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 48)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(scoreColor.opacity(0.24)))
    }

    private var reviewingPill: some View {
        HStack(spacing: 5) {
            Spinner(size: 10, color: .blue)
            if let since = pr.reviewingSince {
                TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                    Text(elapsed(since, ctx.date))
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.blue)
                        .monospacedDigit()
                }
            } else {
                Text("reviewing").font(.system(size: 10, weight: .semibold)).foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Color.blue.opacity(0.13), in: Capsule())
    }

    // Push/review recency — when the PR last got a commit and when Greptile last reviewed.
    @ViewBuilder private var freshnessLine: some View {
        if pr.lastCommitAt != nil || pr.lastReviewAt != nil {
            HStack(spacing: 8) {
                if let c = pr.lastCommitAt {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 9))
                        Text("Pushed \(ago(c)) ago").font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                }
                if let r = pr.lastReviewAt {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 9))
                        Text("Reviewed \(ago(r)) ago").font(.system(size: 10))
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
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(0.07)).frame(width: 34, height: 34)
                if pr.triggering {
                    Spinner(size: 16, color: .primary)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
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
            HStack(spacing: 9) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 28, height: 28)
                    .background(Color.blue.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your Actions").font(.system(size: 13, weight: .bold))
                    Text("Recent workflows").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
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
            .padding(.horizontal, 13).padding(.vertical, 15)
            Divider().opacity(0.10)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.runs) { run in RunRow(run: run) }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct RunRow: View {
    let run: WorkflowRun
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 9) {
            Capsule().fill(color).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(run.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !run.title.isEmpty {
                    Text(run.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    stateBadge
                    Spacer(minLength: 4)
                    timer
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(hovered ? 0.085 : 0.045),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.white.opacity(0.07), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture { openWebURL(run.url) }
        .onHover { hovered = $0 }
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

// MARK: - One leaderboard row (Crew tab)

struct CrewRow: View {
    let entry: VCLeaderboardEntry
    let metric: VCMetric
    @State private var hovered = false

    private var rankColor: Color {
        switch entry.rank {
        case 1: return Color(red: 0.98, green: 0.75, blue: 0.14)   // gold
        case 2: return Color(red: 0.75, green: 0.78, blue: 0.84)   // silver
        case 3: return Color(red: 0.75, green: 0.47, blue: 0.23)   // bronze
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(entry.rank)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(rankColor)
                .frame(width: 22)
            if let url = entry.avatarUrl, let u = URL(string: url) {
                AsyncImage(url: u) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary)
                }
                .frame(width: 24, height: 24).clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 24)).foregroundStyle(.secondary)
            }
            Text(vcDisplayName(entry.name) ?? entry.login)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if entry.online {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                    .shadow(color: .green, radius: 3)
                    .help("Online now")
            }
            Spacer(minLength: 6)
            Text(metric.format(entry.value))
                .font(.system(size: 13, weight: .bold)).monospacedDigit()
                .foregroundStyle(metric == .devtime ? Color.purple : Color.primary)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(.white.opacity(hovered ? 0.08 : 0.045),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help("@\(entry.login) · \(metric.label): \(metric.format(entry.value))")
    }
}

// MARK: - One merged-PR row (Merged tab)

struct MergedRow: View {
    let pr: MergedPR
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Capsule().fill(Color.purple).frame(width: 4, height: 38)
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.purple)
                .frame(width: 36, height: 36)
                .background(Color.purple.opacity(0.11),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(pr.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 7) {
                    Text(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Text("#\(pr.number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    if let m = pr.mergedAt {
                        Text("Merged \(ago(m)) ago")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary.opacity(0.8))
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(.white.opacity(hovered ? 0.085 : 0.05),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.075), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { openWebURL(pr.url) }
        .onHover { hovered = $0 }
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
