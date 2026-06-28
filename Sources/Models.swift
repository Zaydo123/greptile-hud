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

    var hasScore: Bool { scoreNum != nil && scoreDen != nil }
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

    var isRunning: Bool { status != "completed" }
}
