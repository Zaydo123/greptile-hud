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
    var triggering: Bool = false   // optimistic local state while posting @greptile

    var hasScore: Bool { scoreNum != nil && scoreDen != nil }
}
