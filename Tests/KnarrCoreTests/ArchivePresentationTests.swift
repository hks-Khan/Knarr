import Foundation
import Testing
@testable import KnarrCore

@Suite struct ArchivePresentationTests {
    @Test func archivedFailedWorkKeepsEvidenceAndLeavesActivePanelAfterReopen() async throws {
        let f = try await StallariFixture.make()
        do {
            let original = KnarrCore.Issue(id: "old", title: "이전 조사", projectName: "project", state: .failed,
                headline: "실패 기록", detail: "원래 원인", acceptance: [.init(text: "검사", state: .unmet, evidence: "이전 실패")],
                hirds: [], events: [], startedAt: .now)
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            json["archivedAt"] = Date().timeIntervalSinceReferenceDate
            json["archiveReason"] = "후속 이슈로 해결되어 사용자 요청으로 정리"
            let archived = try JSONDecoder().decode(KnarrCore.Issue.self, from: JSONSerialization.data(withJSONObject: json))
            try await f.repository.saveIssue(archived, projectID: "p")
            try await f.repository.close()
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            let snapshot = try await reopened.snapshot()
            try await reopened.close()
            let saved = try #require(snapshot.issues.first)
            #expect(Panel.sections(for: [saved]).isEmpty)
            #expect(saved.state == .failed)
            #expect(saved.acceptance[0].state == .unmet)
            #expect(saved.acceptance[0].evidence == "이전 실패")
            let stored = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
            #expect(stored["archiveReason"] as? String == "후속 이슈로 해결되어 사용자 요청으로 정리")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func legacyWorkRemainsVisible() throws {
        let old = KnarrCore.Issue(id: "legacy", title: "이전", projectName: "p", state: .failed,
            headline: "", detail: "", acceptance: [], hirds: [], events: [], startedAt: .now)
        let decoded = try JSONDecoder().decode(KnarrCore.Issue.self, from: JSONEncoder().encode(old))
        #expect(Panel.sections(for: [decoded]).first?.issues.count == 1)
    }
}
