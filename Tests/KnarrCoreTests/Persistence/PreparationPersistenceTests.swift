import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct PreparationPersistenceTests {
    @Test func v7MigrationPreservesOriginalRowsAndHistoryOnReopen() async throws {
        let f = try await StallariFixture.make()
        do {
            _ = try await f.issue("source")
            try await f.repository.appendChat(.init(at: .now, kind: .user("이전 대화 원문")), projectID: "p")
            try await f.repository.close()
            let url = f.directory.appendingPathComponent("knarr.db")
            let old = try SQLiteConnection(path: url.path, flags: 2)
            try old.execute("DROP TABLE project_preparations")
            try old.execute("PRAGMA user_version=7")
            let projects = try old.rows("SELECT id,payload FROM projects")
            let issues = try old.rows("SELECT id,project_id,payload FROM issues")
            let chat = try old.rows("SELECT id,payload FROM chat")
            try old.close()
            let migrated = try await SQLiteKnarrRepository.open(at: url)
            #expect(try await migrated.snapshot().preparationItems.isEmpty)
            var project = try #require(try await migrated.snapshot().projects.first { $0.id == "p" })
            #expect(project.settings.workspaceStyle == .development)
            try await migrated.close()
            let raw = try SQLiteConnection(path: url.path, flags: 1)
            #expect(try raw.rows("PRAGMA user_version") == [["8"]])
            #expect(try raw.rows("SELECT id,payload FROM projects") == projects)
            #expect(try raw.rows("SELECT id,project_id,payload FROM issues") == issues)
            #expect(try raw.rows("SELECT id,payload FROM chat") == chat)
            #expect(try raw.rows("PRAGMA foreign_key_check").isEmpty)
            try raw.close()
            let repository = try await SQLiteKnarrRepository.open(at: url)
            project.settings.workspaceStyle = .preparation
            try await repository.saveProject(project)
            let item = try await repository.savePreparation(id: "prep", projectID: "p", fields: .init(title: "준비", documentPaths: ["PROJECT_STATUS.md"]), expectedRevision: 0, sourceIssueID: "source")
            let v1 = try await repository.appendPreparationDraft(itemID: item.id, projectID: "p", expectedRevision: 1,
                documentID: "answer", title: "답변", text: "한글 첫 원문\n둘째 줄", kind: .draft)
            let v2 = try await repository.appendPreparationDraft(itemID: item.id, projectID: "p", expectedRevision: v1.revision,
                documentID: "answer", title: "답변", text: "제출한 원문", kind: .submitted)
            let final = try await repository.appendPreparationRecord(itemID: item.id, projectID: "p", expectedRevision: v2.revision, text: "서류 접수 확인", submission: .submitted)
            try await repository.close()
            let reopened = try await SQLiteKnarrRepository.open(at: url)
            #expect(try await reopened.preparationItem("prep") == final)
            #expect(try await reopened.snapshot().preparationItems == [final])
            #expect(try await reopened.snapshot().runs.isEmpty)
            try await reopened.close()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func importCannotTakeExecutedForeignOrAlreadyImportedIssue() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: f.directory.path))
            let foreign = try await f.legacyIssue(id: "foreign", title: "다른 자료", criteria: ["기준"], instruction: "원문", projectID: "other")
            let active = try await f.issue("active")
            _ = try await f.dispatch("active-run", issue: active)
            _ = try await f.issue("candidate")
            var project = try #require(try await f.repository.snapshot().projects.first { $0.id == "p" })
            project.settings.workspaceStyle = .preparation; try await f.repository.saveProject(project)
            for id in [foreign, active] {
                await #expect(throws: PersistenceError.self) {
                    try await f.repository.savePreparation(id: "bad", projectID: "p", fields: .init(title: "후보"), expectedRevision: 0, sourceIssueID: id)
                }
            }
            let value = try await f.repository.savePreparation(id: "good", projectID: "p", fields: .init(title: "후보"), expectedRevision: 0, sourceIssueID: "candidate")
            await #expect(throws: PersistenceError.self) {
                try await f.repository.savePreparation(id: "duplicate", projectID: "p", fields: value.fields, expectedRevision: 0, sourceIssueID: "candidate")
            }
            await #expect(throws: PersistenceError.self) {
                try await f.repository.appendPreparationRecord(itemID: "good", projectID: "other", expectedRevision: 1, text: "다른 프로젝트 덮어쓰기")
            }
            project.settings.workspaceStyle = .development; try await f.repository.saveProject(project)
            await #expect(throws: PersistenceError.self) {
                try await f.repository.approveIssueProposal(issueID: "candidate", version: 1, at: .now)
            }
            #expect(try await f.repository.preparationItem("good") == value)
            _ = try await f.session.cancelRun("active-run")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}

@MainActor @Suite(.serialized) struct PreparationLiveTests {
    @Test func importedCandidateLeavesExecutionCardsWhileSourceAndChatRemain() async throws {
        let f = try await LiveFixture.make()
        do {
            var p = try #require(try await f.repository.snapshot().projects.first { $0.id == "p" })
            p.settings.workspaceStyle = .preparation; try await f.repository.saveProject(p)
            try await f.create("real-work", projectID: "other")
            let thread = try await f.repository.createProjectConversation(projectID: "p")
            try await f.repository.appendChat(.init(at: .now, kind: .user("후보를 준비 항목으로 옮겨 줘")), projectID: "p", threadID: thread.id)
            var source = KnarrCore.Issue(id: "candidate", title: "지원 후보", projectName: p.name, state: .awaitingApproval,
                headline: "", detail: "", acceptance: [.init(text: "준비", state: .pending, evidence: "")], hirds: [], events: [], startedAt: .now)
            source.proposal = .init(instruction: "후보 준비 원문", model: "openai-codex/fixture-model")
            try await f.repository.saveIssue(source, projectID: "p")
            let sourceCard = ChatItem(at: .now, kind: .proposal("candidate", version: 1))
            try await f.repository.appendChat(sourceCard, projectID: "p", issueID: "candidate")
            for _ in 0..<100 { if f.store.issues.count == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
            let value = try await f.store.savePreparation(id: "prep", projectID: "p", fields: .init(title: "지원 준비"), expectedRevision: 0, sourceIssueID: "candidate")
            for _ in 0..<100 { if f.store.preparationItems.count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
            #expect(f.store.preparationItems == [value])
            #expect(f.store.executionIssues(inProject: "p").isEmpty)
            #expect(f.store.issues(inProject: "p").count == 1)
            #expect(f.store.projects.first { $0.id == "p" }?.openIssues == 0)
            let session = f.session
            let admin = KnarrAdminService(repository: f.repository, session: { session })
            let listed = try await admin.adminCall("list_projects", arguments: .object([:]))
            #expect(listed["projects"]?.array?.first { $0["projectID"]?.string == "p" }?["openIssues"]?.integer == 0)
            #expect(f.store.projects.first { $0.id == "other" }?.openIssues == 1)
            f.store.selectPreparation(value.id, inProject: "p")
            #expect(f.store.selectedPreparationID(inProject: "p") == value.id)
            f.store.selectProjectConversation("p")
            #expect(!f.store.chat.contains { $0.id == sourceCard.id })
            #expect(f.store.chat.contains { if case .user = $0.kind { return true }; return false })
            #expect(try await f.repository.snapshot().chat.contains { $0.id == sourceCard.id })
            #expect(try await f.repository.snapshot().runs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}

@MainActor @Suite(.serialized) struct PreparationContextTests {
    @Test func selectionIsSavedWithTheRootAndDoesNotLeaveSentInputBehind() async throws {
        let f = try await LiveFixture.make()
        do {
            var project = try #require(try await f.repository.snapshot().projects.first { $0.id == "p" })
            project.settings.workspaceStyle = .preparation; try await f.repository.saveProject(project)
            for id in ["prep-a", "prep-b"] {
                _ = try await f.repository.savePreparation(id: id, projectID: "p", fields: .init(title: id), expectedRevision: 0)
            }
            for _ in 0..<100 { if f.store.preparationItems.count == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
            f.store.selectPreparation("prep-a", inProject: "p")
            f.store.composerDraft = .init(text: "A의 작성본을 준비해 주세요", project: "p")
            let root = try await f.store.startMessageConversation(f.store.composerDraft)
            #expect(f.store.composerDraft.isEmpty)
            let snapshot = try await f.repository.snapshot()
            let source = try #require(snapshot.chat.first { $0.id == root })
            let link = try #require(snapshot.chatLinks.first { $0.chatID == root })
            let wire = try JSONDecoder().decode(OMPJSON.self, from: JSONEncoder().encode(StoredChat(source, link: link)))
            #expect(wire["preparationID"]?.string == "prep-a")
            f.store.selectPreparation("prep-b", inProject: "p")
            let rpc = TestStallariRPC()
            let session = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird)
            _ = try await session.send("이 내용을 저장해 주세요", about: nil, projectID: "p", conversationRootID: root, preparationID: "prep-b")
            let prompt = try #require(await rpc.prompts.last?["message"]?.string)
            #expect(prompt.contains("itemID=prep-a "))
            #expect(!prompt.contains("itemID=prep-b "))
            _ = await session.shutdown()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func issueConversationCannotReadOrWriteForeignPreparation() async throws {
        let f = try await StallariFixture.make()
        do {
            for id in ["p", "other"] {
                try await f.repository.saveProject(.init(id: id, name: id, absolutePath: f.directory.path, settings: .init(workspaceStyle: .preparation)))
            }
            _ = try await f.repository.savePreparation(id: "foreign", projectID: "other", fields: .init(title: "다른 자료"), expectedRevision: 0)
            let id = try await f.session.createIssue(id: "local", title: "실행 작업", criteria: ["기준"], instruction: "실행", projectID: "p")
            let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == id })
            let session = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: issue.conversationThreadID)
            for name in ["list_preparations", "add_preparation_record"] {
                await #expect(throws: StallariError.self) {
                    _ = try await session.performTool(name, arguments: .object(["projectID": .string("other"), "itemID": .string("foreign"), "expectedRevision": .number(1), "text": .string("침범")]))
                }
            }
            #expect(try await f.repository.preparationItem("foreign")?.revision == 1)
            _ = await session.shutdown()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}

@Suite(.serialized) struct PreparationRecoveryTests {
    @Test func legacyHubLinkedIssueTopicKeepsItsOwnedProject() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.repository.saveProject(.init(id: StoredProject.hubID, name: "메인", absolutePath: f.directory.path))
            let id = try await f.session.createIssue(id: "legacy", title: "기존 실행", criteria: ["기준"], instruction: "작업", projectID: "p")
            let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == id })
            let item = ChatItem(at: .now, kind: .user("이 이슈의 세부 질문"))
            try await f.repository.appendChat(item, projectID: StoredProject.hubID, threadID: issue.conversationThreadID)
            try await f.repository.linkMessageConversation(item.id, threadID: issue.conversationThreadID)
            let rpc = TestStallariRPC()
            let session = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: issue.conversationThreadID)
            _ = try await session.send("주제 답변", about: nil, conversationRootID: item.id)
            #expect(await rpc.prompts.last?["message"]?.string?.contains("projectID=p ") == true)
            _ = await session.shutdown()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func staleSavePublishesTheNewerRecordWithoutOverwritingIt() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.repository.saveProject(.init(id: "p", name: "준비", absolutePath: f.directory.path, settings: .init(workspaceStyle: .preparation)))
            let first = try await f.repository.savePreparation(id: "item", projectID: "p", fields: .init(title: "공고"), expectedRevision: 0)
            let updates = try await f.repository.subscribe(initial: false)
            var next = first; next.revision += 1; next.fields.memo = "다른 화면의 저장"
            let external = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: 2)
            try external.execute("UPDATE project_preparations SET payload=? WHERE id=?", [String(decoding: try JSONEncoder().encode(next), as: UTF8.self), next.id])
            try external.close()
            await #expect(throws: PersistenceError.self) {
                try await f.repository.savePreparation(id: first.id, projectID: "p", fields: first.fields, expectedRevision: first.revision)
            }
            let published = await withTaskGroup(of: PersistenceUpdate?.self, returning: PersistenceUpdate?.self) { group in
                group.addTask { var iterator = updates.makeAsyncIterator(); return await iterator.next() }
                group.addTask { try? await Task.sleep(for: .milliseconds(200)); return nil }
                let result = await group.next() ?? nil; group.cancelAll(); return result
            }
            #expect(published?.snapshot.preparationItems.first?.fields.memo == "다른 화면의 저장")
            #expect(try await f.repository.preparationItem(first.id) == next)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
