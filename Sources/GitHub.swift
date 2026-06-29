import Foundation

// MARK: - Shared helpers

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    return isoFormatter.date(from: s)
}

enum GHError: Error { case failed(String) }

func friendly(_ error: Error) -> String {
    if case let GHError.failed(msg) = error {
        return msg.split(separator: "\n").first.map(String.init) ?? msg
    }
    return error.localizedDescription
}

// MARK: - JSON shapes

private struct SearchPR: Decodable {
    let number: Int
    let title: String
    let url: String
    let updatedAt: String?
    let repository: Repo
    struct Repo: Decodable { let nameWithOwner: String }
}

private struct RunLine: Decodable {
    let id: Int
    let name: String?
    let title: String?
    let branch: String?
    let event: String?
    let url: String
    let status: String
    let conclusion: String?
    let started: String?
    let updated: String?
}

private struct CommentLine: Decodable {
    let login: String
    let id: Int
    let created: String
    let updated: String?
    let eyes: Int
    let score: ScoreCap?
    let reviews: ReviewCap?
    struct ScoreCap: Decodable { let n: String; let d: String }
    struct ReviewCap: Decodable { let r: String }
}

// MARK: - gh runner + fetchers

enum GH {
    private static let envFallback = "/usr/bin/env"

    /// Absolute path to the `gh` binary, resolved once.
    static let path: String = {
        for p in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return envFallback   // last resort: run "gh" off PATH
    }()

    /// Run `gh <args>` and return stdout. Throws GHError.failed(stderr) on non-zero exit.
    static func run(_ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                var argv = args
                if path == envFallback { argv = ["gh"] + args }
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = argv

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                proc.environment = env

                let outPipe = Pipe(), errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: error); return
                }

                // Drain both pipes concurrently to avoid buffer deadlock.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                proc.waitUntilExit()

                if proc.terminationStatus != 0 {
                    let msg = String(data: errData, encoding: .utf8) ?? "gh exited \(proc.terminationStatus)"
                    cont.resume(throwing: GHError.failed(msg))
                } else {
                    cont.resume(returning: outData)
                }
            }
        }
    }

    /// All open PRs authored by the authenticated user.
    static func fetchOpenPRs() async throws -> [PR] {
        let data = try await run([
            "search", "prs", "--author=@me", "--state=open",
            "--json", "number,title,url,updatedAt,repository", "--limit", "40"
        ])
        let items = try JSONDecoder().decode([SearchPR].self, from: data)
        return items.map { i in
            PR(id: "\(i.repository.nameWithOwner)#\(i.number)",
               number: i.number, title: i.title,
               repo: i.repository.nameWithOwner, url: i.url,
               updatedAt: parseISO(i.updatedAt))
        }
    }

    /// The authenticated user's login, resolved once (needed to filter Actions runs by actor).
    private static var cachedLogin: String?
    static func currentLogin() async -> String? {
        if let l = cachedLogin { return l }
        guard let data = try? await run(["api", "user", "--jq", ".login"]),
              let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        cachedLogin = s
        return s
    }

    private static let runsJQ = #"""
.workflow_runs[] | {id: .id, name: .name, title: .display_title, branch: .head_branch, event: .event, url: .html_url, status: .status, conclusion: .conclusion, started: .run_started_at, updated: .updated_at}
"""#

    /// Recent Actions runs in `repo` that were triggered by `login` (merges, pushes, …).
    static func fetchRuns(repo: String, login: String) async -> [WorkflowRun] {
        guard let data = try? await run([
            "api", "repos/\(repo)/actions/runs?actor=\(login)&per_page=20", "--jq", runsJQ
        ]), let text = String(data: data, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        var out: [WorkflowRun] = []
        for raw in text.split(separator: "\n") {
            guard let ld = raw.data(using: .utf8),
                  let r = try? dec.decode(RunLine.self, from: ld) else { continue }
            out.append(WorkflowRun(
                id: r.id, repo: repo, name: r.name ?? "workflow", title: r.title ?? "",
                branch: r.branch ?? "", event: r.event ?? "", url: r.url,
                status: r.status, conclusion: r.conclusion,
                startedAt: parseISO(r.started), updatedAt: parseISO(r.updated)))
        }
        return out
    }

    // jq extracts only what we need (tiny payload): latest Greptile score, review count, eyes.
    private static let commentsJQ = #"""
.[] | {login: .user.login, id: .id, created: .created_at, updated: .updated_at, eyes: .reactions.eyes, score: ((.body|capture("Confidence Score:[^0-9]*(?<n>[0-9]+)[^0-9]+(?<d>[0-9]+)")?)//null), reviews: ((.body|capture("Reviews \\((?<r>[0-9]+)\\)")?)//null)}
"""#

    private static let reactionJQ = #"""
.[] | select(.content=="eyes") | .created_at
"""#

    /// Enrich a PR with its latest Greptile score and live re-review status.
    static func enrich(_ input: PR) async -> PR {
        var pr = input
        guard let data = try? await run([
            "api", "repos/\(pr.repo)/issues/\(pr.number)/comments", "--paginate", "--jq", commentsJQ
        ]), let text = String(data: data, encoding: .utf8) else {
            return pr
        }

        // Re-tagging @greptile sometimes spawns a *second* review comment instead of
        // editing the first, so several Greptile comments can carry a score. The current
        // one is whichever was edited (updated_at) most recently — Greptile revises its
        // review in place as it works — not whichever was posted (created_at) last.
        var bestScore: (n: Int, d: Int)?
        var reviewCount: Int?
        var bestEdited: Date?            // updated_at of the winning Greptile review comment
        var eyesComment: (id: Int, date: Date)?
        let dec = JSONDecoder()

        for raw in text.split(separator: "\n") {
            guard let ld = raw.data(using: .utf8),
                  let c = try? dec.decode(CommentLine.self, from: ld) else { continue }
            let isGreptile = c.login.lowercased().contains("greptile")
            let created = parseISO(c.created) ?? .distantPast
            let edited = parseISO(c.updated) ?? created   // updated_at == created_at when never edited

            // Score + review count both live in the same Greptile review body, so take
            // them together from the single most-recently-edited review comment.
            if isGreptile, let s = c.score, let n = Int(s.n), let d = Int(s.d),
               bestEdited == nil || edited > bestEdited! {
                bestEdited = edited
                bestScore = (n, d)
                reviewCount = c.reviews.flatMap { Int($0.r) }
            }
            if c.eyes > 0 {
                if eyesComment == nil || created > eyesComment!.date { eyesComment = (c.id, created) }
            }
        }

        if let b = bestScore { pr.scoreNum = b.n; pr.scoreDen = b.d }
        pr.reviewCount = reviewCount

        if let ec = eyesComment {
            pr.reviewing = true
            let reactedAt = await eyesReactionDate(repo: pr.repo, commentId: ec.id)
            pr.reviewingSince = reactedAt ?? ec.date
        }
        return pr
    }

    /// When did Greptile drop the 👀 reaction (accurate "reviewing for" clock)?
    private static func eyesReactionDate(repo: String, commentId: Int) async -> Date? {
        guard let data = try? await run([
            "api", "repos/\(repo)/issues/comments/\(commentId)/reactions", "--jq", reactionJQ
        ]), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").compactMap { parseISO(String($0)) }.max()
    }

    /// Post an `@greptile` comment to kick off a fresh review.
    static func triggerReview(repo: String, number: Int) async throws {
        _ = try await run([
            "api", "repos/\(repo)/issues/\(number)/comments", "-f", "body=@greptile"
        ])
    }
}

// MARK: - Observable store

@MainActor
final class PRStore: ObservableObject {
    @Published var prs: [PR] = []
    @Published var runs: [WorkflowRun] = []   // your Actions runs (CI from merges/pushes)
    @Published var lastRefresh: Date?
    @Published var refreshing = false
    @Published var errorText: String?

    private var inFlight = false

    func refresh() async {
        if inFlight { return }
        inFlight = true; refreshing = true; errorText = nil
        defer { inFlight = false; refreshing = false }

        do {
            let base = try await GH.fetchOpenPRs()
            var enriched: [PR] = []
            // Throttle to a small window so we don't fire every PR's requests at once and
            // trip GitHub's secondary (anti-abuse) rate limit — which 403s the score fetches.
            let maxConcurrent = 6
            await withTaskGroup(of: PR.self) { group in
                var it = base.makeIterator()
                for _ in 0..<maxConcurrent { if let pr = it.next() { group.addTask { await GH.enrich(pr) } } }
                while let p = await group.next() {
                    enriched.append(p)
                    if let pr = it.next() { group.addTask { await GH.enrich(pr) } }
                }
            }
            enriched.sort { a, b in
                if a.reviewing != b.reviewing { return a.reviewing && !b.reviewing }
                return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
            }
            self.prs = enriched
            self.lastRefresh = Date()
            await refreshRuns(for: enriched)
        } catch {
            self.errorText = friendly(error)
        }
    }

    /// Fetch your Actions runs across every repo with an open PR, keeping ones that are
    /// in-flight or finished within the last 30 minutes. Running first, then newest.
    private func refreshRuns(for prs: [PR]) async {
        guard let login = await GH.currentLogin() else { return }
        let repos = Set(prs.map { $0.repo })
        guard !repos.isEmpty else { runs = []; return }

        var all: [WorkflowRun] = []
        await withTaskGroup(of: [WorkflowRun].self) { group in
            for repo in repos { group.addTask { await GH.fetchRuns(repo: repo, login: login) } }
            for await rs in group { all.append(contentsOf: rs) }
        }

        // Keep runs *you* set off — merges/pushes/PRs/manual — not cron or bot dispatches.
        let userEvents: Set<String> = ["push", "merge_group", "pull_request",
                                       "pull_request_target", "workflow_dispatch"]
        let cutoff = Date().addingTimeInterval(-1800)   // 30 min
        runs = all
            .filter { userEvents.contains($0.event) }
            .filter { $0.isRunning || ($0.updatedAt ?? .distantPast) > cutoff }
            .sorted { a, b in
                if a.isRunning != b.isRunning { return a.isRunning && !b.isRunning }
                return (a.startedAt ?? .distantPast) > (b.startedAt ?? .distantPast)
            }
    }

    func triggerReview(_ pr: PR) async {
        guard let idx = prs.firstIndex(where: { $0.id == pr.id }) else { return }
        prs[idx].triggering = true
        do {
            try await GH.triggerReview(repo: pr.repo, number: pr.number)
            prs[idx].triggering = false
            prs[idx].reviewing = true
            if prs[idx].reviewingSince == nil { prs[idx].reviewingSince = Date() }
        } catch {
            prs[idx].triggering = false
            errorText = "Couldn’t trigger review: \(friendly(error))"
        }
        // Give Greptile a moment to drop the 👀, then resync.
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        await refresh()
    }
}
