import Foundation

public struct ChatDraft: Codable, Sendable, Equatable {
    public var text: String
    public var attachments: [URL]
    public var project: String?
    public var conversationRootID: UUID?
    public var preparationID: String?
    public init(text: String = "", attachments: [URL] = [], project: String? = nil, conversationRootID: UUID? = nil, preparationID: String? = nil) {
        self.preparationID = preparationID
        self.conversationRootID = conversationRootID
        self.text = text; self.attachments = attachments; self.project = project
    }
    /// App-owned context can be attached at admission without changing what the person typed.
    func hasSameInput(as other: Self) -> Bool {
        text == other.text && attachments == other.attachments && project == other.project && conversationRootID == other.conversationRootID
    }
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }
}

/// Delivery of a main-conversation message sent while an answer is running.
/// Message-conversation replies always wait, so an answer never changes conversations mid-turn.
public enum WhileRespondingMode: String, Sendable, CaseIterable {
    /// Reaches the running answer at its next engine boundary (OMP `steer`).
    case steer
    /// Waits in the app and is sent once the answer ends.
    case queue
    static let preferenceKey = "knarr.whileResponding"
    init(preferences: UserDefaults) {
        self = preferences.string(forKey: Self.preferenceKey).flatMap(Self.init(rawValue:)) ?? .steer
    }
}

public struct ContextUsage: Sendable, Equatable {
    public let tokens: Int
    public let capacity: Int
    public var fraction: Double { min(1, max(0, Double(tokens) / Double(capacity))) }
    public init?(state: OMPJSON) {
        guard let usage = state["contextUsage"], let tokens = usage["tokens"]?.integer,
              let capacity = usage["contextWindow"]?.integer, tokens >= 0, capacity > 0 else { return nil }
        self.tokens = tokens; self.capacity = capacity
    }
}

public enum ChatAttachmentError: Error, LocalizedError {
    case unreadable(String), oversized(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "첨부 파일 ‘\(name)’을 읽을 수 없어요. 파일을 다시 선택해 주세요."
        case .oversized(let name): "‘\(name)’은 이미지 첨부 한도인 10MB를 넘어요. 크기를 줄여 주세요."
        }
    }
}
