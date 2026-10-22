import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct PreparationToolTests {
    @Test func deadlinesUseUnambiguousTwentyFourHourTime() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Seoul"))
        let afternoon = PreparationItem.Fields(deadline: StallariSession.date("2026-11-06T17:00:00+09:00"))
        let night = PreparationItem.Fields(deadline: StallariSession.date("2026-11-20T23:59:00+09:00"))
        #expect(afternoon.deadlineLabel(timeZone: zone) == "11/06 17:00")
        #expect(night.deadlineLabel(timeZone: zone) == "11/20 23:59")
    }
    @Test func projectStyleSurvivesOldRowsAndRoundTrip() throws {
        let old = try JSONDecoder().decode(ProjectSettings.self, from: Data("{}".utf8))
        let oldJSON = try JSONDecoder().decode(OMPJSON.self, from: JSONEncoder().encode(old))
        #expect(oldJSON["workspaceStyle"]?.string == "development")
        let archive = try JSONDecoder().decode(ProjectSettings.self, from: Data("{\"workspaceStyle\":\"preparation\",\"memo\":\"기존 메모\"}".utf8))
        let saved = try JSONDecoder().decode(OMPJSON.self, from: JSONEncoder().encode(archive.cleaned))
        #expect(saved["workspaceStyle"]?.string == "preparation")
        #expect(saved["memo"]?.string == "기존 메모")
    }

    @Test func preparationImportVersionsAndScopePreserveOriginal() async throws {
        let f = try await StallariFixture.make()
        do {
            let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data("{\"workspaceStyle\":\"preparation\"}".utf8))
            try await f.repository.saveProject(.init(id: "p", name: "준비", absolutePath: f.directory.path, settings: settings))
            let issueID = try await f.legacyIssue(id: "candidate", title: "기존 후보", criteria: ["원래 조건"], instruction: "원본 공고와 참고 자료")
            let original = try #require(try await f.repository.snapshot().issues.first { $0.id == issueID })
            let thread = try await f.repository.createProjectConversation(projectID: "p")
            let session = StallariSession(repository: f.repository, rpc: f.rpc, hird: f.hird, threadID: thread.id)
            let args: OMPJSON = .object(["itemID": .string("candidate-item"), "expectedRevision": .number(0),
                "sourceIssueID": .string("candidate"), "organization": .string("회사"), "title": .string("지원 공고"),
                "memo": .string("직군 검토 중"), "deadline": .string("2026-10-23T11:59:00+09:00")])
            let imported = try await session.performTool("save_preparation", arguments: args)
            #expect(imported["revision"]?.integer == 1)
            #expect(imported["fields"]?["submission"]?.string == "unconfirmed")
            #expect(imported["sourceIssue"]?["proposal"]?["instruction"]?.string == "원본 공고와 참고 자료")
            // Retrying a successful import returns the same item and does not duplicate it.
            #expect(try await session.performTool("save_preparation", arguments: args) == imported)
            let list = try await session.performTool("list_preparations", arguments: .object([:]))
            #expect(list["items"]?.array?.count == 1)
            #expect(try await f.repository.snapshot().issues.first { $0.id == issueID } == original)
            await #expect(throws: PersistenceError.self) {
                _ = try await f.repository.approveIssueProposal(issueID: issueID, version: 1, at: .now)
            }
            // Each save appends a version. Saving a submitted copy does not invent submission status.
            let draft = try await session.performTool("save_preparation_draft", arguments: .object([
                "itemID": .string("candidate-item"), "expectedRevision": .number(1), "documentID": .string("answer"),
                "title": .string("지원 동기"), "text": .string("초안 원문"), "kind": .string("draft")]))
            #expect(draft["revision"]?.integer == 2)
            let final = try await session.performTool("save_preparation_draft", arguments: .object([
                "itemID": .string("candidate-item"), "expectedRevision": .number(2), "documentID": .string("answer"),
                "title": .string("지원 동기"), "text": .string("실제 제출한 사본"), "kind": .string("submitted")]))
            #expect(final["drafts"]?.array?.map { $0["version"]?.integer } == [1, 2])
            #expect(final["drafts"]?.array?.first?["text"]?.string == "초안 원문")
            #expect(final["fields"]?["submission"]?.string == "unconfirmed")
            await #expect(throws: StallariError.self) {
                _ = try await session.performTool("save_preparation", arguments: .object([
                    "itemID": .string("candidate-item"), "expectedRevision": .number(1), "memo": .string("낡은 화면 덮어쓰기")]))
            }
            let recorded = try await session.performTool("add_preparation_record", arguments: .object([
                "itemID": .string("candidate-item"), "expectedRevision": .number(3),
                "text": .string("사용자가 제출 완료를 확인함"), "submission": .string("submitted")]))
            #expect(recorded["records"]?.array?.count == 1)
            #expect(recorded["fields"]?["submission"]?.string == "submitted")
            try await f.repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: f.directory.appendingPathComponent("other").path, settings: settings))
            await #expect(throws: StallariError.self) {
                _ = try await session.performTool("list_preparations", arguments: .object(["projectID": .string("other")]))
            }
            #expect(try await f.repository.snapshot().runs.isEmpty)
            #expect(await f.hird.runs.isEmpty)
            _ = await session.shutdown()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
