import Foundation

/// Only externally supplied reasoning text and observed tool lifecycle events are displayed.
public struct ChatActivity: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case reasoning, tool }
    public enum State: String, Codable, Sendable { case running, completed, failed, stopped, interrupted }
    public var kind: Kind
    public var title: String
    public var state: State
    public var updatedAt: Date
    public init(kind: Kind, title: String, state: State = .running, updatedAt: Date = .now) {
        self.kind = kind; self.title = title; self.state = state; self.updatedAt = updatedAt
    }
    public var statusLabel: String {
        switch state {
        case .running: "진행 중"
        case .completed: "완료"
        case .failed: "실패"
        case .stopped: "중지됨"
        case .interrupted: "결과 미수신"
        }
    }
    static func toolTitle(_ name: String) -> String {
        ["read": "파일 읽기", "grep": "내용 검색", "glob": "파일 검색", "bash": "명령 실행", "task": "하위 작업",
         "edit": "파일 수정", "write": "파일 작성", "todo": "작업 목록 갱신"][name] ?? name
    }
    static func toolTarget(_ frame: OMPJSON) -> String {
        let args = frame["args"]
        // Keep output bodies, credentials and arbitrary argument objects out of the transcript.
        let target = args?["path"]?.string ?? args?["file_path"]?.string ?? args?["pattern"]?.string
            ?? args?["description"]?.string ?? args?["issueID"]?.string
        if let target { return String(target.prefix(500)) }
        if let command = args?["command"]?.string {
            // Show the executable, not shell arguments which can contain secrets.
            let executable = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            return executable.contains("=") ? "셸 명령" : String(executable.prefix(100))
        }
        return toolTitle(frame["toolName"]?.string ?? "도구")
    }
}
