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
    let actor: String?
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
.workflow_runs[] | {id: .id, name: .name, title: .display_title, branch: .head_branch, event: .event, url: .html_url, status: .status, conclusion: .conclusion, started: .run_started_at, updated: .updated_at, actor: (.triggering_actor.login // .actor.login)}
"""#

    /// Recent Actions runs in `repo`. Pass `actor` to see only that person's runs,
    /// or nil for everyone's — the whole queue, including whoever is ahead of you.
    static func fetchRuns(repo: String, actor: String?) async -> [WorkflowRun] {
        var query = "per_page=\(actor == nil ? 30 : 20)"
        if let actor { query = "actor=\(actor)&" + query }
        guard let data = try? await run([
            "api", "repos/\(repo)/actions/runs?\(query)", "--jq", runsJQ
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
                startedAt: parseISO(r.started), updatedAt: parseISO(r.updated),
                actor: r.actor))
        }
        return out
    }

    private static let pushedReposJQ = #"""
.[] | select(.type=="PushEvent") | .repo.name
"""#

    /// Repos you pushed to recently, newest first, from your own event feed.
    /// The last resort for finding your CI when you have no open PRs and no
    /// recent merges to name a repo — e.g. you pushed straight to `main`.
    static func recentlyPushedRepos(login: String) async -> [String] {
        guard let data = try? await run([
            "api", "users/\(login)/events?per_page=30", "--jq", pushedReposJQ
        ]), let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let repo = String(line).trimmingCharacters(in: .whitespaces)
            if !repo.isEmpty, !out.contains(repo) { out.append(repo) }
        }
        return Array(out.prefix(5))
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
        pr.lastReviewAt = bestEdited

        // Last-commit time + whether Greptile is actively reviewing, in one GraphQL call.
        // The check-run is the authoritative "reviewing now" signal; the 👀 reaction below
        // is a fallback because Greptile often clears it the moment the review finishes.
        let head = await headState(repo: pr.repo, number: pr.number)
        pr.lastCommitAt = head.committedDate
        pr.baseRef = head.baseRef
        pr.headRef = head.headRef
        pr.isDraft = head.isDraft
        pr.mergeable = head.mergeable
        pr.mergeStateStatus = head.mergeStateStatus
        pr.changedFiles = head.changedFiles
        if head.reviewing {
            pr.reviewing = true
            pr.reviewingSince = head.reviewingSince
        }

        if !pr.reviewing, let ec = eyesComment {
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

    /// Head commit's timestamp, whether Greptile is mid-review, and everything the
    /// merge button / merge trains need (base + head branch, mergeability, touched
    /// files) — one GraphQL call.
    /// The "Greptile Review" check-run is the authoritative review state (queued/in_progress
    /// while it works, with a startedAt for the clock); the 👀 reaction the HUD used before
    /// is transient.
    private struct HeadState {
        var committedDate: Date?
        var reviewing = false
        var reviewingSince: Date?
        var baseRef: String?
        var headRef: String?
        var isDraft = false
        var mergeable: String?
        var mergeStateStatus: String?
        var changedFiles: [String] = []
    }

    /// `mergeStateStatus` sits behind the long-lived merge-info preview; if a host
    /// (GHES, or a token without the preview) rejects it the whole query would fail
    /// and we'd lose the commit date too — so we retry without that one field.
    private static func headQuery(withMergeState: Bool) -> String {
        let mergeState = withMergeState ? " mergeStateStatus" : ""
        return "query($owner:String!,$name:String!,$num:Int!){repository(owner:$owner,name:$name){pullRequest(number:$num){baseRefName headRefName isDraft mergeable\(mergeState) files(first:100){nodes{path}} commits(last:1){nodes{commit{committedDate statusCheckRollup{contexts(last:30){nodes{__typename ... on CheckRun{name status startedAt conclusion}}}}}}}}}}"
    }

    private static let headJQ = #"""
.data.repository.pullRequest as $p | ($p.commits.nodes[0].commit // {}) as $c | {committed: $c.committedDate, greptile: ((($c.statusCheckRollup.contexts.nodes) // []) | map(select(.__typename=="CheckRun" and (.name|ascii_downcase|contains("greptile")))) | last), base: $p.baseRefName, head: $p.headRefName, draft: $p.isDraft, mergeable: $p.mergeable, mergeState: $p.mergeStateStatus, files: ((($p.files.nodes) // []) | map(.path))}
"""#

    private static func headState(repo: String, number: Int) async -> HeadState {
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else { return HeadState() }

        func fetch(_ withMergeState: Bool) async -> HeadJSON? {
            var args = ["api", "graphql", "-f", "query=\(headQuery(withMergeState: withMergeState))"]
            if withMergeState {
                args += ["-H", "Accept: application/vnd.github.merge-info-preview+json"]
            }
            args += ["-f", "owner=\(parts[0])", "-f", "name=\(parts[1])", "-F", "num=\(number)",
                     "--jq", headJQ]
            guard let data = try? await run(args) else { return nil }
            return try? JSONDecoder().decode(HeadJSON.self, from: data)
        }

        var head = await fetch(true)
        if head == nil { head = await fetch(false) }
        guard let decoded = head else { return HeadState() }

        var st = HeadState()
        st.committedDate = parseISO(decoded.committed)
        st.baseRef = decoded.base
        st.headRef = decoded.head
        st.isDraft = decoded.draft ?? false
        st.mergeable = decoded.mergeable
        st.mergeStateStatus = decoded.mergeState
        st.changedFiles = decoded.files ?? []
        if let g = decoded.greptile, let status = g.status {
            switch status.uppercased() {
            case "QUEUED", "IN_PROGRESS":
                st.reviewing = true
                st.reviewingSince = parseISO(g.startedAt)
            default:
                break
            }
        }
        return st
    }

    private struct HeadJSON: Decodable {
        let committed: String?
        let greptile: GrepCheck?
        let base: String?
        let head: String?
        let draft: Bool?
        let mergeable: String?
        let mergeState: String?
        let files: [String]?
        struct GrepCheck: Decodable { let status: String?; let startedAt: String? }
    }

    private struct SearchMergedPR: Decodable {
        let number: Int
        let title: String
        let url: String
        let closedAt: String?
        let repository: Repo
        struct Repo: Decodable { let nameWithOwner: String }
    }

    /// Your most recently merged PRs, newest merge first.
    static func fetchMergedPRs() async throws -> [MergedPR] {
        let data = try await run([
            "search", "prs", "--author=@me", "--merged",
            "--sort", "updated", "--limit", "20",
            "--json", "number,title,url,repository,closedAt"
        ])
        let items = try JSONDecoder().decode([SearchMergedPR].self, from: data)
        return items
            .map { i in MergedPR(id: "\(i.repository.nameWithOwner)#\(i.number)",
                                 number: i.number, title: i.title,
                                 repo: i.repository.nameWithOwner, url: i.url,
                                 mergedAt: parseISO(i.closedAt)) }
            .sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }
    }

    /// Post an `@greptile` comment to kick off a fresh review.
    static func triggerReview(repo: String, number: Int) async throws {
        _ = try await run([
            "api", "repos/\(repo)/issues/\(number)/comments", "-f", "body=@greptile"
        ])
    }

    /// Where a run currently is: the active (or failed) job, and the step inside it.
    /// One extra API call, so only ever asked for runs that are in flight or failed.
    private static let jobsJQ = #"""
[.jobs[] | {name: .name, status: .status, conclusion: .conclusion, steps: [.steps[]? | {name: .name, status: .status, conclusion: .conclusion}]}] as $jobs
| (($jobs | map(select(.status != "completed")) | first) // ($jobs | map(select(.conclusion == "failure")) | first)) as $j
| if $j == null then {job: null, step: null, index: null, total: null} else
  ($j.steps | to_entries) as $es
  | (($es | map(select(.value.status == "in_progress")) | last)
     // ($es | map(select(.value.conclusion == "failure")) | last)
     // ($es | map(select(.value.status == "completed")) | last)) as $s
  | {job: $j.name, step: ($s.value.name // null), index: (if $s == null then null else $s.key + 1 end), total: ($es | length)}
  end
"""#

    private struct RunProgress: Decodable {
        let job: String?
        let step: String?
        let index: Int?
        let total: Int?
    }

    /// GitHub names action steps `Run owner/action@<sha>` — trim to `owner/action`
    /// so the step line stays readable in a 240pt column. A step the author
    /// actually named "Run smoke tests" is left alone.
    private static func prettyStep(_ raw: String) -> String {
        var t = raw
        var prefix = ""
        if t.hasPrefix("Post Run ") { prefix = "Post "; t = String(t.dropFirst(9)) }
        else if t.hasPrefix("Run ") { t = String(t.dropFirst(4)) }
        else { return raw }
        // Only an action reference (owner/action@sha) gets shortened.
        guard let at = t.firstIndex(of: "@"), t[t.startIndex..<at].contains("/") else { return raw }
        return prefix + String(t[t.startIndex..<at])
    }

    /// Fill in `currentJob`/`currentStep` for one run. Returns the run unchanged
    /// if GitHub can't say where it is.
    static func fetchRunProgress(_ input: WorkflowRun) async -> WorkflowRun {
        var run = input
        guard let data = try? await self.run([
            "api", "repos/\(run.repo)/actions/runs/\(run.id)/jobs", "--jq", jobsJQ
        ]), let p = try? JSONDecoder().decode(RunProgress.self, from: data) else { return run }
        run.currentJob = p.job
        run.currentStep = p.step.map(prettyStep)
        run.stepIndex = p.index
        run.stepTotal = p.total
        return run
    }

    // MARK: - Merging

    /// Squash-merge a single pull request.
    static func mergePR(repo: String, number: Int, title: String) async throws {
        _ = try await run([
            "api", "-X", "PUT", "repos/\(repo)/pulls/\(number)/merge",
            "-f", "merge_method=squash",
            "-f", "commit_title=\(title) (#\(number))"
        ])
    }

    // MARK: - Stacked pull requests

    /// Re-point a PR at a new base branch. This is the whole mechanic behind
    /// GitHub's stacked PRs: a stack *is* a chain of base branches.
    static func setBase(repo: String, number: Int, base: String) async throws {
        _ = try await run([
            "api", "-X", "PATCH", "repos/\(repo)/pulls/\(number)", "-f", "base=\(base)"
        ])
    }

    /// Chain the given PRs into a stack, bottom first. The bottom PR keeps
    /// targeting `trunk`; every other PR is re-pointed at the branch below it.
    ///
    /// Nothing is merged and no branch is rewritten, so this is fully reversible
    /// with `unstack` — the only change is which branch each PR targets.
    static func buildStack(repo: String, trunk: String, prs: [PR]) async throws {
        guard prs.count >= 2 else { throw GHError.failed("A stack needs at least two pull requests") }
        for (i, pr) in prs.enumerated() {
            let base = i == 0 ? trunk : (prs[i - 1].headRef ?? trunk)
            guard pr.baseRef != base else { continue }
            do {
                try await setBase(repo: repo, number: pr.number, base: base)
            } catch {
                throw GHError.failed("#\(pr.number) → \(base): \(friendly(error))")
            }
        }
    }

    /// Flatten a stack: point every PR back at the trunk. Undoes `buildStack`.
    static func unstack(repo: String, trunk: String, prs: [PR]) async throws {
        for pr in prs where pr.baseRef != trunk {
            try await setBase(repo: repo, number: pr.number, base: trunk)
        }
    }

    // MARK: - Merge trains

    /// Head SHA of `branch` in `repo`.
    private static func branchSHA(repo: String, branch: String) async throws -> String {
        let data = try await run([
            "api", "repos/\(repo)/git/ref/heads/\(branch)", "--jq", ".object.sha"
        ])
        guard let sha = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty else {
            throw GHError.failed("Couldn’t resolve \(branch)")
        }
        return sha
    }

    private static func createBranch(repo: String, branch: String, sha: String) async throws {
        _ = try await run([
            "api", "-X", "POST", "repos/\(repo)/git/refs",
            "-f", "ref=refs/heads/\(branch)", "-f", "sha=\(sha)"
        ])
    }

    static func deleteBranch(repo: String, branch: String) async {
        _ = try? await run(["api", "-X", "DELETE", "repos/\(repo)/git/refs/heads/\(branch)"])
    }

    /// Server-side merge of `head` into `base`. Returns false on a merge conflict
    /// (409) rather than throwing, so the caller can leave that PR off the train
    /// and keep going. Throws for anything else (missing branch, permissions, …).
    private static func mergeBranch(repo: String, base: String, head: String,
                                    message: String) async throws -> Bool {
        do {
            _ = try await run([
                "api", "-X", "POST", "repos/\(repo)/merges",
                "-f", "base=\(base)", "-f", "head=\(head)", "-f", "commit_message=\(message)"
            ])
            return true
        } catch let GHError.failed(msg) {
            let m = msg.lowercased()
            if m.contains("conflict") || m.contains("409") { return false }
            throw GHError.failed(msg)
        }
    }

    /// Open the combined pull request. Returns its html_url.
    private static func openPR(repo: String, title: String, head: String,
                               base: String, body: String) async throws -> String {
        let data = try await run([
            "api", "-X", "POST", "repos/\(repo)/pulls",
            "-f", "title=\(title)", "-f", "head=\(head)", "-f", "base=\(base)",
            "-f", "body=\(body)", "--jq", ".html_url"
        ])
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Assemble a merge train: cut a fresh branch off `base`, merge each PR's head
    /// into it server-side, then open one combined PR. One CI run, one deploy —
    /// instead of N pipelines stepping on each other.
    ///
    /// A PR whose branch conflicts with the train so far is dropped (recorded in
    /// `skipped`) rather than failing the whole assembly. If nothing lands, the
    /// scratch branch is deleted so no debris is left behind.
    static func buildTrain(repo: String, base: String, prs: [PR],
                           branchName: String) async throws -> TrainResult {
        guard !prs.isEmpty else { throw GHError.failed("No pull requests selected") }

        let baseSHA = try await branchSHA(repo: repo, branch: base)
        try await createBranch(repo: repo, branch: branchName, sha: baseSHA)

        var result = TrainResult(branch: branchName, url: nil, mergedPRs: [])
        do {
            for pr in prs {
                guard let head = pr.headRef, !head.isEmpty else {
                    result.skipped.append((pr.number, "no head branch"))
                    continue
                }
                let ok = try await mergeBranch(repo: repo, base: branchName, head: head,
                                               message: "Merge #\(pr.number) — \(pr.title)")
                if ok { result.mergedPRs.append(pr.number) }
                else { result.skipped.append((pr.number, "conflicts with the train")) }
            }
        } catch {
            await deleteBranch(repo: repo, branch: branchName)
            throw error
        }

        guard !result.mergedPRs.isEmpty else {
            await deleteBranch(repo: repo, branch: branchName)
            throw GHError.failed("Every selected PR conflicted — nothing to merge")
        }

        let included = prs.filter { result.mergedPRs.contains($0.number) }
        var body = "Merge train assembled by Greptile HUD — one CI run instead of \(included.count).\n\n"
        for pr in included { body += "- #\(pr.number) \(pr.title)\n" }
        if !result.skipped.isEmpty {
            body += "\nLeft behind (conflicting):\n"
            for (n, why) in result.skipped { body += "- #\(n) — \(why)\n" }
        }
        body += "\nMerging this closes nothing automatically; the source PRs land as their commits arrive on `\(base)`."

        do {
            result.url = try await openPR(
                repo: repo,
                title: "Merge train: \(included.map { "#\($0.number)" }.joined(separator: " + "))",
                head: branchName, base: base, body: body)
        } catch {
            await deleteBranch(repo: repo, branch: branchName)
            throw error
        }

        // Best-effort breadcrumb so the source PRs point at the train.
        if let url = result.url, !url.isEmpty {
            for pr in included {
                _ = try? await run(["api", "repos/\(repo)/issues/\(pr.number)/comments",
                                    "-f", "body=🚄 Riding the merge train: \(url)"])
            }
        }
        return result
    }
}

// MARK: - Observable store

@MainActor
final class PRStore: ObservableObject {
    @Published var prs: [PR] = []
    @Published var runs: [WorkflowRun] = []   // your Actions runs (CI from merges/pushes)
    @Published var merged: [MergedPR] = []    // your most recently merged PRs ("Merged" tab)
    @Published var lastRefresh: Date?
    @Published var refreshing = false
    @Published var runsRefreshing = false   // Actions column alone is re-fetching
    @Published var errorText: String?

    /// Show everyone's runs in the Actions column, not just yours — so you can
    /// see who's ahead of you in the deploy queue. Sticky across launches.
    @Published var showAllActors: Bool = UserDefaults.standard.bool(forKey: PRStore.allActorsKey) {
        didSet {
            guard oldValue != showAllActors else { return }
            UserDefaults.standard.set(showAllActors, forKey: PRStore.allActorsKey)
            Task { await refreshRuns(for: prs) }
        }
    }
    private static let allActorsKey = "hud.actions.showAllActors"

    // Merge-train state (Train tab)
    @Published var trainSelection: Set<String> = []   // PR ids riding the next train
    @Published var trainBuilding = false
    @Published var trainResult: TrainResult?
    @Published var trainError: String?
    @Published var trainMode: TrainMode = .stack
    @Published var stackNotice: String?               // "Stacked 3 PRs" / "Flattened"

    /// How the Train tab lands a selection.
    enum TrainMode: String, CaseIterable {
        /// Chain the PRs with GitHub's stacked pull requests — each keeps its own
        /// review, and the stack lands from the bottom up.
        case stack
        /// Merge them onto one throwaway branch and open a single combined PR.
        /// Always exactly one pipeline, at the cost of one opaque PR.
        case combine

        var label: String { self == .stack ? "Stack" : "Combine" }
    }

    private var inFlight = false
    private var runsInFlight = false

    func refresh(force: Bool = false) async {
        if inFlight { return }
        // Cooldown so rapid overlay shows don't trip the GitHub search API rate limit.
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < 30 { return }
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
            // Drop train picks whose PR closed or merged out from under us.
            let live = Set(enriched.map(\.id))
            self.trainSelection = self.trainSelection.intersection(live)
            self.lastRefresh = Date()
            self.merged = (try? await GH.fetchMergedPRs()) ?? self.merged
            await refreshRuns(for: enriched)
        } catch {
            self.errorText = friendly(error)
        }
    }

    /// Fetch your Actions runs, keeping ones that are in-flight or finished within
    /// the last 30 minutes. Running first, then newest.
    ///
    /// Repos come from your open PRs *and* your recent merges: CI from a merge is
    /// exactly the run you want to watch, and by then the PR that would have named
    /// the repo is closed. Capped so a long merge history can't fan out to dozens
    /// of API calls.
    private func refreshRuns(for prs: [PR]) async {
        guard let login = await GH.currentLogin() else { return }
        var repos: [String] = []
        for pr in prs where !repos.contains(pr.repo) { repos.append(pr.repo) }
        for m in merged where !repos.contains(m.repo) { repos.append(m.repo) }   // newest merge first
        if repos.isEmpty {
            // Nothing open and nothing merged — you probably pushed straight to a
            // branch. Ask your event feed where that was.
            repos = await GH.recentlyPushedRepos(login: login)
        }
        repos = Array(repos.prefix(8))
        guard !repos.isEmpty else { runs = []; return }

        let actorFilter = showAllActors ? nil : login
        var all: [WorkflowRun] = []
        await withTaskGroup(of: [WorkflowRun].self) { group in
            for repo in repos { group.addTask { await GH.fetchRuns(repo: repo, actor: actorFilter) } }
            for await rs in group { all.append(contentsOf: rs) }
        }

        // Keep human-triggered runs — merges/pushes/PRs/manual — not cron or bot dispatches.
        let userEvents: Set<String> = ["push", "merge_group", "pull_request",
                                       "pull_request_target", "workflow_dispatch"]
        let cutoff = Date().addingTimeInterval(-1800)   // 30 min
        var kept = all
            .filter { userEvents.contains($0.event) }
            .filter { $0.isRunning || ($0.updatedAt ?? .distantPast) > cutoff }
            .map { r -> WorkflowRun in
                var r = r
                r.isMine = r.actor == nil || r.actor == login
                return r
            }
            .sorted { a, b in
                if a.isRunning != b.isRunning { return a.isRunning && !b.isRunning }
                if a.isMine != b.isMine { return a.isMine && !b.isMine }
                return (a.startedAt ?? .distantPast) > (b.startedAt ?? .distantPast)
            }

        // Show the list immediately, then fill in "what step is it on" for the runs
        // where that's meaningful — in flight, or failed and worth explaining.
        runs = kept
        let detailIdx = kept.indices
            .filter { kept[$0].isRunning || kept[$0].conclusion == "failure" }
            .prefix(10)
        guard !detailIdx.isEmpty else { return }
        await withTaskGroup(of: (Int, WorkflowRun).self) { group in
            for i in detailIdx { group.addTask { (i, await GH.fetchRunProgress(kept[i])) } }
            for await (i, r) in group { kept[i] = r }
        }
        runs = kept
    }

    /// Poll used while the overlay is on screen. Actions runs (and the step each
    /// one is on) move constantly, so they refresh every tick; the far more
    /// expensive PR sweep — a search plus two calls per PR — only re-runs once
    /// it's actually gone stale, which keeps this well inside the API rate limit.
    func refreshLive() async {
        if lastRefresh == nil || Date().timeIntervalSince(lastRefresh!) > 45 {
            await refresh(force: true)
            return
        }
        await refreshRunsNow()
    }

    /// Re-fetch just the Actions column, skipping if a fuller refresh is already
    /// doing it.
    func refreshRunsNow() async {
        if inFlight || runsInFlight { return }
        runsInFlight = true
        runsRefreshing = true
        defer { runsInFlight = false; runsRefreshing = false }
        await refreshRuns(for: prs)
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

    // MARK: - Merging

    /// Squash-merge one PR (the 5/5 fast path).
    func merge(_ pr: PR) async {
        guard let idx = prs.firstIndex(where: { $0.id == pr.id }) else { return }
        prs[idx].merging = true
        do {
            try await GH.mergePR(repo: pr.repo, number: pr.number, title: pr.title)
            prs.removeAll { $0.id == pr.id }
            trainSelection.remove(pr.id)
        } catch {
            if let i = prs.firstIndex(where: { $0.id == pr.id }) { prs[i].merging = false }
            errorText = "Couldn’t merge #\(pr.number): \(friendly(error))"
        }
        await refresh(force: true)
    }

    // MARK: - Merge trains

    /// PRs eligible to ride a train, bucketed by the pipeline they'd trigger
    /// (repo + base branch). Two PRs in different buckets can never combine.
    var trainGroups: [TrainGroup] {
        var buckets: [String: TrainGroup] = [:]
        for pr in prs where pr.isMergeable && pr.headRef != nil {
            guard let base = pr.baseRef else { continue }
            let key = "\(pr.repo)@\(base)"
            buckets[key, default: TrainGroup(repo: pr.repo, base: base, prs: [])].prs.append(pr)
        }
        return buckets.values
            .filter { $0.prs.count >= 2 }
            .map { g in
                var g = g
                g.prs.sort { trainRank($0) > trainRank($1) }
                return g
            }
            .sorted { $0.prs.count > $1.prs.count }
    }

    /// Confidence-first ordering: a clean 5/5 boards before a 3/5, and a scored
    /// PR before an unreviewed one.
    private func trainRank(_ pr: PR) -> Double {
        guard let n = pr.scoreNum, let d = pr.scoreDen, d > 0 else { return -1 }
        return Double(n) / Double(d)
    }

    /// Do these two PRs touch the same files? That's the one thing that reliably
    /// turns a combined branch into a conflict, so it's the compatibility test.
    func overlap(_ a: PR, _ b: PR) -> [String] {
        guard a.repo == b.repo, a.baseRef == b.baseRef else { return [] }
        let setB = Set(b.changedFiles)
        return a.changedFiles.filter { setB.contains($0) }.sorted()
    }

    /// Every reason the current selection can't ride together.
    var selectionConflicts: [TrainConflict] {
        let picked = selectedPRs
        var out: [TrainConflict] = []
        for i in picked.indices {
            for j in picked.indices where j > i {
                let shared = overlap(picked[i], picked[j])
                if !shared.isEmpty {
                    out.append(TrainConflict(a: picked[i].id, b: picked[j].id, paths: shared,
                                             reason: "\(shared.count) shared file\(shared.count == 1 ? "" : "s")"))
                }
            }
        }
        return out
    }

    var selectedPRs: [PR] {
        prs.filter { trainSelection.contains($0.id) }
    }

    /// The repo/base the current selection belongs to, if any.
    var selectedGroup: TrainGroup? {
        guard let first = selectedPRs.first, let base = first.baseRef else { return nil }
        return TrainGroup(repo: first.repo, base: base, prs: selectedPRs)
    }

    func toggleTrainSelection(_ pr: PR) {
        if trainSelection.contains(pr.id) {
            trainSelection.remove(pr.id)
            return
        }
        // A train is one branch on one repo — picking across pipelines clears the
        // incompatible half rather than silently building something that can't ship.
        if let g = selectedGroup, g.repo != pr.repo || g.base != pr.baseRef {
            trainSelection.removeAll()
        }
        trainSelection.insert(pr.id)
        trainResult = nil
    }

    func clearTrainSelection() {
        trainSelection.removeAll()
        trainResult = nil
        trainError = nil
    }

    /// Greedy best-train: take the largest pipeline bucket, then walk it
    /// confidence-first, adding every PR that doesn't touch a file already claimed.
    func smartSelectTrain() {
        trainResult = nil
        trainError = nil
        guard let group = trainGroups.first else {
            trainSelection.removeAll()
            return
        }
        var picked: [PR] = []
        var claimed = Set<String>()
        for pr in group.prs {
            // A PR whose review is still running has no settled score yet — it can
            // still be added by hand, but auto-select won't put it on the train.
            if pr.reviewing { continue }
            if pr.changedFiles.contains(where: { claimed.contains($0) }) { continue }
            picked.append(pr)
            claimed.formUnion(pr.changedFiles)
        }
        trainSelection = Set(picked.map(\.id))
    }

    /// Stacks the HUD can see right now, rebuilt from the open PRs: a PR whose
    /// base branch is another open PR's head branch is stacked on it.
    var detectedStacks: [PRStack] {
        var byHead: [String: PR] = [:]
        for pr in prs { if let h = pr.headRef { byHead["\(pr.repo)|\(h)"] = pr } }

        var lowerOf: [String: PR] = [:]          // PR id → the PR it sits on
        for pr in prs {
            if let b = pr.baseRef, let lower = byHead["\(pr.repo)|\(b)"], lower.id != pr.id {
                lowerOf[pr.id] = lower
            }
        }
        let carriesSomething = Set(lowerOf.values.map(\.id))

        // Bottoms sit on the trunk but have something stacked above them.
        return prs
            .filter { lowerOf[$0.id] == nil && carriesSomething.contains($0.id) }
            .map { bottom in
                var chain = [bottom]
                var guardCount = 0
                while let next = prs.first(where: { lowerOf[$0.id]?.id == chain[chain.count - 1].id }),
                      guardCount < 20 {
                    chain.append(next)
                    guardCount += 1
                }
                return PRStack(repo: bottom.repo, trunk: bottom.baseRef ?? "main", prs: chain)
            }
            .sorted { $0.prs.count > $1.prs.count }
    }

    /// The selection in the order it should be stacked: highest confidence at the
    /// bottom, so if you only land part of the stack, the safest lands first.
    var stackOrder: [PR] {
        selectedPRs.sorted { trainRank($0) > trainRank($1) }
    }

    /// Chain the selection into a stack. Nothing merges and no branch is
    /// rewritten — only each PR's base branch changes, so `unstack` fully undoes it.
    func buildStack() async {
        guard !trainBuilding else { return }
        let picked = stackOrder
        guard picked.count >= 2, let group = selectedGroup else {
            trainError = "Pick at least two pull requests on the same base branch"
            return
        }
        trainBuilding = true
        trainError = nil
        trainResult = nil
        stackNotice = nil
        defer { trainBuilding = false }

        do {
            try await GH.buildStack(repo: group.repo, trunk: group.base, prs: picked)
            stackNotice = "Stacked \(picked.count) PRs — merge from the top to land them bottom-up"
            trainSelection.removeAll()
            await refresh(force: true)
        } catch {
            trainError = friendly(error)
        }
    }

    /// Point every PR in a stack back at the trunk.
    func flatten(_ stack: PRStack) async {
        guard !trainBuilding else { return }
        trainBuilding = true
        trainError = nil
        stackNotice = nil
        defer { trainBuilding = false }
        do {
            try await GH.unstack(repo: stack.repo, trunk: stack.trunk, prs: stack.prs)
            stackNotice = "Flattened — every PR targets \(stack.trunk) again"
            await refresh(force: true)
        } catch {
            trainError = friendly(error)
        }
    }

    /// Cut the train branch, merge every selected PR into it, open the combined PR.
    func buildTrain() async {
        guard !trainBuilding else { return }
        let picked = selectedPRs
        guard picked.count >= 2, let group = selectedGroup else {
            trainError = "Pick at least two pull requests on the same base branch"
            return
        }
        trainBuilding = true
        trainError = nil
        trainResult = nil
        defer { trainBuilding = false }

        let stamp = trainStampFormatter.string(from: Date())
        let branch = "greptile-hud/train-\(stamp)"
        do {
            let result = try await GH.buildTrain(repo: group.repo, base: group.base,
                                                 prs: picked, branchName: branch)
            trainResult = result
            trainSelection.removeAll()
            await refresh(force: true)
        } catch {
            trainError = friendly(error)
        }
    }
}

private let trainStampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()
