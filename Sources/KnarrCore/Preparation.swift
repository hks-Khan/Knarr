import Foundation

/// Preparation is durable project content, independent of Hird approval and execution.
public struct PreparationItem: Identifiable, Codable, Sendable, Hashable {
    public enum Submission: String, Codable, Sendable, CaseIterable {
        case unconfirmed, notSubmitted, submitted
        public var label: String {
            switch self { case .unconfirmed: "제출 여부 미확인"; case .notSubmitted: "미제출"; case .submitted: "제출 완료" }
        }
    }
    public struct Fields: Codable, Sendable, Hashable {
        public var organization: String
        public var title: String
        public var deadline: Date?
        public var priority: Bool
        public var memo: String
        public var posting: String
        public var submission: Submission
        public var documentPaths: [String]
        public func deadlineLabel(timeZone: TimeZone = .current) -> String {
            guard let deadline else { return "미정" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "MM/dd HH:mm"
            return formatter.string(from: deadline)
        }
        public init(organization: String = "", title: String = "", deadline: Date? = nil,
                    priority: Bool = false, memo: String = "", posting: String = "",
                    submission: Submission = .unconfirmed, documentPaths: [String] = []) {
            self.organization = organization; self.title = title; self.deadline = deadline
            self.priority = priority; self.memo = memo; self.posting = posting
            self.submission = submission; self.documentPaths = documentPaths
        }
    }
    public struct Draft: Identifiable, Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable, CaseIterable {
            case draft, submitted
            public var label: String { self == .draft ? "작성본" : "제출본" }
        }
        public let id: String
        public let documentID: String
        public let version: Int
        public let title: String
        public let text: String
        public let kind: Kind
        public let savedAt: Date
    }
    public struct Record: Identifiable, Codable, Sendable, Hashable {
        public let id: String
        public let text: String
        public let submission: Submission?
        public let recordedAt: Date
    }
    public let id: String
    public let projectID: String
    public internal(set) var revision: Int
    public internal(set) var fields: Fields
    /// A retained copy for provenance; the original issue and its linked history are never rewritten.
    public let sourceIssue: Issue?
    public let createdAt: Date
    public internal(set) var updatedAt: Date
    public internal(set) var drafts: [Draft]
    public internal(set) var records: [Record]
    public var sourceIssueID: Issue.ID? { sourceIssue?.id }
    public var heading: String { fields.organization.isEmpty ? fields.title : fields.organization + " · " + fields.title }

    public static func ordered(_ items: [Self]) -> [Self] {
        items.sorted {
            if $0.fields.priority != $1.fields.priority { return $0.fields.priority }
            if $0.fields.deadline != $1.fields.deadline { return ($0.fields.deadline ?? .distantFuture) < ($1.fields.deadline ?? .distantFuture) }
            return ($0.createdAt, $0.id) < ($1.createdAt, $1.id)
        }
    }
    public var latestDrafts: [Draft] {
        var seen: Set<String> = []
        return drafts.reversed().filter { seen.insert($0.documentID).inserted }
    }
}
