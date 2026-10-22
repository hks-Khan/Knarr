import Foundation
import CryptoKit

/// An explicit project-to-main request, independent of Issue delivery and approval.
public struct ProjectTransfer: Codable, Sendable, Hashable, Identifiable {
    public struct AttachmentReference: Codable, Sendable, Hashable {
        public let messageID: UUID
        public let url: URL
        public init(messageID: UUID, url: URL) { self.messageID = messageID; self.url = url }
    }
    public enum State: String, Codable, Sendable, Hashable { case pending, delivered, failed }
    static let deliveryFailureMessage = "메인 접수를 확인하지 못했어요. 원본과 전달 요청은 보존되어 다시 시도할 수 있어요."
    static let unsupportedFailureMessage = "메인 전달 확장 또는 bridge가 없어요. 호환 앱과 확장을 설치한 뒤 다시 시도해 주세요."

    public let id: String
    public let originProjectID: String
    public let originThreadID: String
    /// The project name resolved when the request was enqueued; later renames preserve history.
    public let projectName: String
    public let requestMessageID: UUID
    public let requestText: String
    public let summary: String
    public let messageIDs: [UUID]
    public let attachments: [AttachmentReference]
    public let createdAt: Date
    public internal(set) var deliveredAt: Date? = nil
    public internal(set) var lastError: String? = nil
    public var state: State { deliveredAt != nil ? .delivered : lastError != nil ? .failed : .pending }
    public var recipientThreadID: String { ConversationThread.defaultID }
}


extension ProjectTransfer {
    /// Stable across reloads, including receipts saved before transcript navigation existed.
    public var mainMessageID: UUID {
        let bytes = Array(SHA256.hash(data: Data(("knarr-project-transfer-receipt:" + id).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public var receiptItem: ChatItem? {
        guard let deliveredAt else { return nil }
        return .init(id: mainMessageID, at: deliveredAt,
                     kind: .autoCheck(summary: projectName + "에서 전달한 요청", lines: [summary]))
    }

    /// Insert receipt displays at admission time while preserving existing transcript order.
    /// These are views of saved transfers, never new prompts or fabricated assistant replies.
    public static func transcript(_ chat: [ChatItem], transfers: [ProjectTransfer], threadID: String) -> [ChatItem] {
        guard threadID == ConversationThread.defaultID else { return chat }
        let existing = Set(chat.map(\.id))
        let receipts = transfers.compactMap(\.receiptItem).filter { !existing.contains($0.id) }
            .sorted { $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at }
        guard !receipts.isEmpty else { return chat }
        var result: [ChatItem] = [], index = 0
        for item in chat {
            while index < receipts.count && receipts[index].at <= item.at {
                result.append(receipts[index]); index += 1
            }
            result.append(item)
        }
        result.append(contentsOf: receipts[index...])
        return result
    }
}
