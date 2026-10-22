import Foundation

/// OMP's owned extension supplies the model-facing tool; the app owns persistence and scope.
enum ProjectTransferProtocol {
    static let bridgeTool = "knarr_project_transfer_bridge_v1"
    static let dialogTitle = "knarr.project-transfer.bridge.v1"
    static let admissionCommand = "knarr-project-transfer-admit"
    static let messageType = "knarr.project-transfer.v1"

    static func isBridgeFrame(_ frame: OMPJSON) -> Bool {
        frame["type"]?.string == "extension_ui_request" && frame["method"]?.string == "input" &&
            frame["title"]?.string == dialogTitle
    }
    static func payload(_ transfer: ProjectTransfer, policy: ProjectSessionPolicy) throws -> OMPJSON {
        let details: OMPJSON = .object([
            "protocolVersion": .number(1), "transferID": .string(transfer.id),
            "originProjectID": .string(transfer.originProjectID), "originThreadID": .string(transfer.originThreadID),
            "projectName": .string(transfer.projectName), "requestMessageID": .string(transfer.requestMessageID.uuidString),
            "requestText": .string(transfer.requestText), "summary": .string(transfer.summary),
            "messageIDs": .array(transfer.messageIDs.map { .string($0.uuidString) }),
            "attachments": try JSONDecoder().decode(OMPJSON.self, from: JSONEncoder().encode(transfer.attachments))
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(decoding: try encoder.encode(details), as: UTF8.self)
        return .object(["transferID": .string(transfer.id), "details": details,
            "content": .string((policy.transferInstructions ?? ProjectSessionPolicy.current.transferInstructions ?? "") + "\n" + encoded)])
    }
    static func hasReceipt(_ response: OMPJSON, payload: OMPJSON) throws -> Bool {
        guard let entries = response["data"]?["entries"]?.array else {
            throw StallariError.rejectedEvidence("메인의 영속 전달 기록을 확인하지 못했어요.")
        }
        for entry in entries where entry["type"]?.string == "custom_message" && entry["customType"]?.string == messageType {
            guard entry["details"]?["transferID"] == payload["transferID"] else { continue }
            guard entry["details"] == payload["details"] else { throw StallariError.conflictingID }
            return true
        }
        return false
    }
}
