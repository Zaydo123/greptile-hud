import Foundation

/// A single open pull request plus its latest Greptile state.
struct PR: Identifiable, Equatable {
    let id: String          // "owner/repo#123"
    let number: Int
    let title: String
    let repo: String        // "owner/name"
    let url: String

    var scoreNum: Int?      // e.g. 4  (Confidence Score: 4/5)
    var scoreDen: Int?      // e.g. 5
    var reviewCount: Int?   // "Reviews (N)" from the latest summary footer
    var reviewing: Bool = false
    var reviewingSince: Date?
    var updatedAt: Date?
    var lastCommitAt: Date?        // head-commit time on the PR
    var lastReviewAt: Date?        // when Greptile last revised its review (comment updated_at)
    var triggering: Bool = false   // optimistic local state while posting @greptile

    // Merge metadata (GraphQL head query) — powers the merge button and trains.
    var baseRef: String?           // branch this PR targets, e.g. "main"
    var headRef: String?           // this PR's own branch
    var isDraft: Bool = false
    var mergeable: String?         // MERGEABLE | CONFLICTING | UNKNOWN
    var mergeStateStatus: String?  // CLEAN | BLOCKED | BEHIND | DIRTY | UNSTABLE | HAS_HOOKS | DRAFT | UNKNOWN
    var changedFiles: [String] = []
    var merging: Bool = false      // optimistic local state while the merge call is in flight

    var hasScore: Bool { scoreNum != nil && scoreDen != nil }

    /// A clean sweep from Greptile — 5/5, or whatever the denominator is.
    var isPerfectScore: Bool {
        guard let n = scoreNum, let d = scoreDen, d > 0 else { return false }
        return n == d
    }

    /// GitHub says this can merge right now: no conflicts, not a draft, and the
    /// state isn't one that would have GitHub reject the merge outright.
    var isMergeable: Bool {
        guard !isDraft else { return false }
        guard mergeable == nil || mergeable == "MERGEABLE" else { return false }
        switch mergeStateStatus {
        case "DIRTY", "DRAFT", "BLOCKED": return false
        default: return true
        }
    }

    /// The merge button only appears on a perfect review that GitHub will accept.
    var canQuickMerge: Bool { isPerfectScore && isMergeable && !reviewing }

    /// Human explanation for why a PR is out of the running for a train.
    var mergeBlockReason: String? {
        if isDraft { return "draft" }
        if mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" { return "conflicts" }
        if mergeStateStatus == "BLOCKED" { return "blocked" }
        if reviewing { return "reviewing" }
        return nil
    }
}

/// A GitHub Actions workflow run triggered by you (e.g. CI kicked off by a merge/push),
/// shown in its own column with live state + how long it's been running.
struct WorkflowRun: Identifiable, Equatable {
    let id: Int             // run databaseId
    let repo: String        // "owner/name"
    let name: String        // workflow name
    let title: String       // display_title (commit / PR title)
    let branch: String
    let event: String       // push, pull_request, merge_group, …
    let url: String
    let status: String      // queued | in_progress | completed
    let conclusion: String? // success | failure | cancelled | … (nil while running)
    let startedAt: Date?
    let updatedAt: Date?

    // Who set it off, and where it currently is. Both are optional: the actor is
    // whatever GitHub reports, and step detail is only fetched for runs that are
    // in flight or failed (see `GH.fetchRunProgress`).
    var actor: String? = nil
    var isMine: Bool = true
    var currentJob: String? = nil
    var currentStep: String? = nil
    var stepIndex: Int? = nil
    var stepTotal: Int? = nil

    var isRunning: Bool { status != "completed" }

    /// "Install deps · 8/14" — what the run is chewing on right now.
    var stepLine: String? {
        guard let step = currentStep else { return nil }
        if let i = stepIndex, let t = stepTotal, t > 0 { return "\(step) · \(i)/\(t)" }
        return step
    }
}

/// Several runs of the same workflow, collapsed into one row. Busy repos fire
/// the same workflow over and over (one per push); the useful one is the oldest
/// still in that state — it's furthest along and at the front of the queue.
struct RunStack: Identifiable {
    let lead: WorkflowRun     // oldest run in the stack
    let count: Int
    var id: Int { lead.id }

    /// Collapse repeat runs of the same workflow in the same state into one row.
    /// Each row shows the **oldest** of its bunch — the one furthest along, at
    /// the front of the queue — and counts the rest. Failures never merge into
    /// the running pile, so a red run can't hide inside a blue one.
    ///
    /// Ordering: in-flight first (oldest first, since that's the one about to
    /// clear), then yours before other people's, then finished runs newest first.
    static func stacks(from runs: [WorkflowRun]) -> [RunStack] {
        var buckets: [String: [WorkflowRun]] = [:]
        for r in runs {
            let state = r.isRunning ? "running" : (r.conclusion ?? "done")
            buckets["\(r.repo)|\(r.name)|\(state)", default: []].append(r)
        }
        return buckets.values.compactMap { group -> RunStack? in
            guard let lead = group.min(by: {
                ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture)
            }) else { return nil }
            return RunStack(lead: lead, count: group.count)
        }
        .sorted { a, b in
            let x = a.lead, y = b.lead
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            if x.isMine != y.isMine { return x.isMine }
            if x.isRunning {
                return (x.startedAt ?? .distantFuture) < (y.startedAt ?? .distantFuture)
            }
            return (x.startedAt ?? .distantPast) > (y.startedAt ?? .distantPast)
        }
    }

    /// In flight first, then anything that broke, then the quiet successes.
    private static func rank(_ r: WorkflowRun) -> Int {
        if r.isRunning { return 0 }
        switch r.conclusion {
        case "failure", "timed_out", "startup_failure": return 1
        default: return 2
        }
    }
}

/// A recently merged pull request, for the "Merged" tab.
struct MergedPR: Identifiable, Equatable {
    let id: String          // "owner/repo#123"
    let number: Int
    let title: String
    let repo: String        // "owner/name"
    let url: String
    let mergedAt: Date?
}

// MARK: - Local statuses

/// A user-authored status interval. A missing end date means its stopwatch is
/// still running; stopped sessions become the local status history.
struct StatusSession: Identifiable, Codable, Equatable {
    let id: UUID
    let emoji: String
    let message: String
    let startedAt: Date
    var endedAt: Date?

    var isActive: Bool { endedAt == nil }
}

/// Local-only status stopwatch and history. The whole value is small and is
/// persisted in UserDefaults so a running status survives an app relaunch.
@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var sessions: [StatusSession] = []

    private let defaults: UserDefaults
    private let storageKey = "status.sessions.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([StatusSession].self, from: data) else { return }
        sessions = saved.sorted { $0.startedAt > $1.startedAt }
    }

    var active: StatusSession? { sessions.first(where: \.isActive) }
    var history: [StatusSession] { sessions.filter { !$0.isActive } }

    func start(emoji rawEmoji: String, message rawMessage: String, at date: Date = Date()) {
        let trimmedEmoji = rawEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = trimmedEmoji.first.map(String.init) ?? ""
        let message = String(rawMessage.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !emoji.isEmpty || !message.isEmpty else { return }

        stop(at: date)
        sessions.insert(StatusSession(id: UUID(), emoji: emoji, message: message,
                                      startedAt: date, endedAt: nil), at: 0)
        save()
    }

    func stop(at date: Date = Date()) {
        guard let index = sessions.firstIndex(where: \.isActive) else { return }
        sessions[index].endedAt = max(date, sessions[index].startedAt)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

// MARK: - Merge trains

/// A group of open PRs that share a repo and base branch — the candidate pool a
/// train is assembled from. One deploy pipeline, one CI run, N pull requests.
struct TrainGroup: Identifiable {
    let repo: String
    let base: String
    var prs: [PR]

    var id: String { "\(repo)@\(base)" }
}

/// A chain of PRs where each targets the branch of the one below it — GitHub's
/// stacked pull requests. Ordered bottom (lands first, targets the trunk) to top.
///
/// The HUD builds these by re-pointing base branches through the REST API, which
/// is exactly how GitHub defines a stack; no preview API is involved. It does
/// *not* rebase the branches — it has no clone — so a HUD-built stack is a
/// logical chain, not a rebased one. See `README.md` for what that means for
/// GitHub's own one-shot stack merge.
struct PRStack: Identifiable {
    let repo: String
    let trunk: String       // what the bottom PR targets, e.g. "main"
    var prs: [PR]           // bottom → top

    var id: String { "\(repo)@\(trunk)#\(prs.first?.number ?? 0)" }
    var top: PR? { prs.last }
    var bottom: PR? { prs.first }
}

/// Why two PRs can't ride the same train.
struct TrainConflict: Identifiable, Equatable {
    let a: String           // PR id
    let b: String           // PR id
    let paths: [String]     // overlapping files (empty when the reason isn't file overlap)
    let reason: String

    var id: String { "\(a)|\(b)" }
}

/// Lifecycle of a combine-mode train's combined pull request.
enum TrainState: Equatable {
    case assembled      // open on GitHub, ready to merge
    case merging        // the merge call is in flight
    case landed         // merged — source PRs closed or marked merged
}

/// Outcome of assembling a train: the combined PR plus everyone who boarded.
struct TrainResult: Equatable {
    var repo: String
    var base: String            // branch the train targets
    var branch: String          // the scratch train branch
    var number: Int?            // the combined PR (nil only if GitHub never said)
    var url: String?
    var mergedPRs: [Int]        // PR numbers that landed on the train branch
    var skipped: [(Int, String)] = []   // PR number → why it was left behind
    var state: TrainState = .assembled
    var closedPRs: [Int] = []   // source PRs this HUD closed once the train landed

    static func == (l: TrainResult, r: TrainResult) -> Bool {
        l.repo == r.repo && l.branch == r.branch && l.number == r.number
            && l.url == r.url && l.mergedPRs == r.mergedPRs && l.state == r.state
            && l.closedPRs == r.closedPRs && l.skipped.map(\.0) == r.skipped.map(\.0)
    }
}

/// A combine-mode train whose combined PR is still open. Remembered in
/// UserDefaults so it survives restarts and stays one click away until it
/// lands — wherever that merge happens (here or on the web), the source PRs
/// get closed and the scratch branch dropped.
struct ActiveTrain: Codable, Identifiable, Equatable {
    let repo: String
    let base: String
    let branch: String
    let number: Int             // the combined PR
    let url: String
    let prs: [Int]              // source PR numbers riding the train
    let skipped: [String]       // "#12 — conflicts with the train"
    let createdAt: Date

    var id: String { "\(repo)#\(number)" }
}
