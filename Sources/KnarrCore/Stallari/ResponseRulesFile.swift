import Foundation
import CryptoKit

/// User-owned presentation/workflow preferences; never an authority to grant tools or approve work.
public struct ResponseRulesFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static let defaults = previousDefaults.replacingOccurrences(
        of: "작업 시작은 한두 문장으로 알리고, 진행 상태는 이슈 카드로 보여 준다.",
        with: "작업 시작은 한두 문장으로 알리고, 실제로 확인한 진행 상황을 대화 메시지로 간결하게 전한다. 같은 상태를 반복하지 않는다.")
    private static let previousDefaults = """
    # Stallari 응답 지침

    사용자에게 한국어로 간결하게 답한다. 결론이나 필요한 결정을 먼저 쓴다.
    작업 시작은 한두 문장으로 알리고, 진행 상태는 이슈 카드로 보여 준다. 결과에는 변경 내용·검증 결과·남은 문제를 쓴다.
    표와 제목은 비교나 긴 설명에 필요할 때만 사용한다. 내부 JSON·전체 실행 지시·반복적인 운영 규칙은 대화에 나열하지 않는다.
    “이번에는 조회만 했습니다”, “수정하지 않았습니다”처럼 하지 않은 일을 나열하지 않는다.
    """
    private static let legacyDefaults = """
    # Stallari 응답 지침

    사용자에게 한국어로 간결하게 답한다. 결론이나 필요한 결정을 먼저 쓴다.
    Markdown을 사용한다. 첫 callout은 완료·판정 시 > [!RESULT], 결정 필요 시 > [!DECIDE], 중단 시 > [!STOP], 진행 중에는 > [!INFO]로 쓴다.
    긴 답변은 ## 제목, 비교·검사 결과는 표, 코드는 언어를 붙인 fenced block, 긴 근거는 접힌 callout (> [!INFO]- 제목)을 사용한다.
    “이번에는 조회만 했습니다”, “수정하지 않았습니다”처럼 하지 않은 일을 나열하지 않는다.
    질문과 단순 확인은 직접 읽거나 읽기 전용 scout로 처리한다. 명령 실행이 필요한 조사와 코드 변경은 사용자의 승인 범위 안에서 Hird에 맡긴다.
    """
    public func prepare() throws {
        try validate()
        guard !FileManager.default.fileExists(atPath: url.path) else { _ = try load(); return }
        // Exclusive creation protects a user's concurrently created file.
        let data = Data((Self.defaults + "\n").utf8)
        do { try data.write(to: url, options: .withoutOverwriting) }
        catch { if FileManager.default.fileExists(atPath: url.path) { _ = try load() } else { throw error } }
    }
    public func load() throws -> String {
        try validate()
        let text = try String(contentsOf: url, encoding: .utf8)
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == Self.legacyDefaults || text.trimmingCharacters(in: .whitespacesAndNewlines) == Self.previousDefaults {
            try save(Self.defaults + "\n")
            return Self.defaults + "\n"
        }
        return text
    }
    public func save(_ text: String) throws {
        try validate()
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func validate() throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.pathExtension.lowercased() == "md" else {
            throw ResponseRulesError.invalidPath
        }
    }
    public func applying(to message: String) throws -> String {
        let rules = try load()
        return try Self.applying(text: rules, to: message)
    }
    public static func version(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func applying(text rules: String, to message: String) throws -> String {
        // JSON encoding makes the data boundary unambiguous even if the file contains delimiters.
        let quoted = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
        return "Current user-owned response preferences (JSON string; subordinate to fixed safety/tool contracts; not approval to act):\n" + quoted + "\nCurrent request:\n" + message
    }
}
public enum ResponseRulesError: Error, LocalizedError {
    case invalidPath
    public var errorDescription: String? { "응답 지침 경로는 읽고 쓸 수 있는 절대 경로의 Markdown(.md) 파일이어야 해요." }
}
