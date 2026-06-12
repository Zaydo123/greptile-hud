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

// MARK: - Overlay

struct HUDView: View {
    @ObservedObject var store: PRStore
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
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
        if store.prs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: store.refreshing ? "hourglass" : "checkmark.seal")
                    .font(.system(size: 26)).foregroundStyle(.secondary)
                Text(store.refreshing ? "Loading your PRs…" : "No open PRs")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 36)
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
        .onTapGesture { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
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
