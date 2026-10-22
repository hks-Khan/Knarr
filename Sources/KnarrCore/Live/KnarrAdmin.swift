import Foundation

/// The narrow surface a local MCP adapter may use. It names project/issue operations only:
/// no file access, no shell, no approval, no worker launch and no settings.
/// Every call is answered by the app's own store, so ownership, version and active-run
/// rules are the ones the screens already use.
public protocol KnarrAdminServing: AnyObject, Sendable {
    @MainActor func adminCall(_ operation: String, arguments: OMPJSON) async throws -> OMPJSON
}

public enum KnarrAdminOperation: String, CaseIterable, Sendable {
    case listProjects = "list_projects"
    case listIssues = "list_issues"
    case getIssue = "get_issue"
    case createIssue = "create_issue"
    case updateIssueProposal = "update_issue_proposal"
    case closeIssue = "close_issue"
}

/// Structured refusals. `code` is stable on the wire; `message` is what the person reads.
public enum KnarrAdminError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case notFound(String)
    case conflict(String)
    case rejected(String)
    case unavailable(String)

    public var code: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .notFound: "not_found"
        case .conflict: "conflict"
        case .rejected: "rejected"
        case .unavailable: "unavailable"
        }
    }
    public var message: String {
        switch self {
        case .invalidRequest(let value), .notFound(let value), .conflict(let value),
             .rejected(let value), .unavailable(let value): value
        }
    }
}

extension KnarrAdminError: LocalizedError {
    public var errorDescription: String? { message }
}
