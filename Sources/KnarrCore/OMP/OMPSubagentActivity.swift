import Foundation

/// Event-only reducer shared by Hird and Stallari. OMP already coalesces child progress.
struct OMPSubagentActivity: Sendable {
    private(set) var active: [SubagentWork] = []

    @discardableResult mutating func receive(_ frame: OMPJSON, at now: Date) -> String? {
        switch frame["type"]?.string {
        case "subagent_lifecycle":
            guard let payload = frame["payload"], let id = payload["id"]?.string,
                  let status = payload["status"]?.string else { return nil }
            switch status {
            case "started":
                guard !active.contains(where: { $0.id == id }) else { return nil }
                active.append(.init(id: id, name: payload["name"]?.string ?? id,
                    currentCommand: nil, startedAt: now, lastActivityAt: now))
            case "completed", "failed", "aborted":
                guard let index = active.firstIndex(where: { $0.id == id }) else { return nil }
                active.remove(at: index)
            default: return nil
            }
            return "하위 작업 \(status)"
        case "subagent_progress":
            guard let progress = frame["payload"]?["progress"], let id = progress["id"]?.string,
                  let index = active.firstIndex(where: { $0.id == id }) else { return nil }
            switch progress["status"]?.string {
            case "completed", "failed", "aborted": active.remove(at: index)
            case "running":
                active[index].currentCommand = progress["currentTool"]?.string
                active[index].lastActivityAt = now
            default: return nil
            }
            return "하위 작업 활동"
        default: return nil
        }
    }
}

/// A parent tool is not child activity; its command must never overwrite a child's row.
struct OMPToolActivity {
    let name: String
    let command: String
    let callID: String?
    init(_ frame: OMPJSON) {
        name = frame["toolName"]?.string ?? "tool"
        command = frame["args"]?["command"]?.string ?? name
        callID = frame["toolCallId"]?.string
    }
}
