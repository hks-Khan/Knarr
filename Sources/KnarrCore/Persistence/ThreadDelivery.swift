import Foundation

/// Transactional outbox for issue notifications and their main-origin recipient.
struct ThreadDelivery: Codable, Sendable, Hashable {
    enum Kind: Codable, Sendable, Hashable {
        case question(String)
        case stopped(String)
        case completion(notificationID: String, summary: String)
        case proposalRevision(version: Int, note: String)
        case handoff(String)
    }
    let id: String
    let threadID: String
    let issueID: Issue.ID
    let runID: HirdRun.ID?
    let createdAt: Date
    let kind: Kind
    var deliveredAt: Date?
}
