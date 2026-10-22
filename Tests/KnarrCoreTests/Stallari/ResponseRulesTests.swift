import Foundation
import Testing
@testable import KnarrCore

@Suite struct ResponseRulesTests {
    @Test func firstLaunchNeverOverwritesUserEditsAndReloadUsesLatestBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rules = ResponseRulesFile(url: root.appendingPathComponent("rules.md"))
        try rules.prepare()
        let original = try rules.load()
        #expect(original.contains("“이번에는 조회만 했습니다”, “수정하지 않았습니다”처럼 하지 않은 일을 나열하지 않는다."))
        try rules.save("새 말투\n여러 줄\n\"경계\"")
        try rules.prepare()
        #expect(try rules.load() == "새 말투\n여러 줄\n\"경계\"")
        #expect(ResponseRulesFile.version(of: original) != ResponseRulesFile.version(of: try rules.load()))
        let prompt = try rules.applying(to: "첫째\n둘째")
        #expect(prompt.hasSuffix("Current request:\n첫째\n둘째"))
        #expect(prompt.contains("새 말투\\n여러 줄"))
        try FileManager.default.removeItem(at: rules.url)
        #expect(throws: (any Error).self) { try rules.load() }
    }
    @Test func defaultProgressGuidanceAppearsInChatAndCustomRulesArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rules = ResponseRulesFile(url: root.appendingPathComponent("rules.md"))
        let previous = """
        # Stallari 응답 지침

        사용자에게 한국어로 간결하게 답한다. 결론이나 필요한 결정을 먼저 쓴다.
        작업 시작은 한두 문장으로 알리고, 진행 상태는 이슈 카드로 보여 준다. 결과에는 변경 내용·검증 결과·남은 문제를 쓴다.
        표와 제목은 비교나 긴 설명에 필요할 때만 사용한다. 내부 JSON·전체 실행 지시·반복적인 운영 규칙은 대화에 나열하지 않는다.
        “이번에는 조회만 했습니다”, “수정하지 않았습니다”처럼 하지 않은 일을 나열하지 않는다.
        """
        try rules.save(previous)
        #expect(try rules.load().contains("진행 상황을 대화 메시지로"))
        #expect(ResponseRulesFile.defaults.contains("진행 상황을 대화 메시지로"))
        let customized = previous + "\n사용자가 추가한 규칙"
        try rules.save(customized)
        #expect(try rules.load() == customized)
    }
    @Test func invalidPathAndUnreadableFileFailInsteadOfFallingBack() throws {
        #expect(throws: ResponseRulesError.self) { try ResponseRulesFile(url: URL(string: "https://example.com/rules.md")!).prepare() }
        #expect(throws: ResponseRulesError.self) { try ResponseRulesFile(url: URL(fileURLWithPath: "/tmp/rules.txt")).load() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data([0xff, 0xfe, 0xff]).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try ResponseRulesFile(url: root).prepare() }
    }
    @Test func nextRequestReloadsWithoutReconnectingAndMissingFileBlocksAdmission() async throws {
        let fixture = try await StallariFixture.make()
        let rules = ResponseRulesFile(url: fixture.directory.appendingPathComponent("rules.md"))
        try rules.prepare()
        let session = StallariSession(repository: fixture.repository, rpc: fixture.rpc, hird: fixture.hird, responseRules: rules)
        do {
            try rules.save("버전 하나")
            _ = try await session.send("첫 요청", about: nil)
            try rules.save("버전 둘")
            _ = try await session.send("둘째\n요청", about: nil)
            let prompts = await fixture.rpc.prompts.compactMap { $0["message"]?.string }
            #expect(prompts.count == 2)
            #expect(prompts[0].contains("버전 하나"))
            #expect(prompts[1].contains("버전 둘"))
            #expect(!prompts[1].contains("버전 하나"))
            #expect(prompts[1].hasSuffix("둘째\n요청"))
            try FileManager.default.removeItem(at: rules.url)
            await #expect(throws: (any Error).self) { try await session.send("실패해야 하는 요청", about: nil) }
            #expect(await fixture.rpc.prompts.count == 2)
            _ = await session.shutdown()
            try await fixture.cleanup()
        } catch {
            _ = await session.shutdown()
            try await fixture.cleanup()
            throw error
        }
    }
}
