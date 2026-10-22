import Foundation
import Testing
@testable import KnarrCore
import KnarrMCP

/// The caller boundary and the durable resend contract. These drive the same dispatcher the
/// socket uses; the app store is the real one, so ownership and version rules are the app's.
@MainActor @Suite(.serialized) struct MCPCallerBoundaryTests {
    // MARK: - Fixed app context

    @Test func callerCannotChooseTheSessionByNamingAnIssueOrThread() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let id = try await f.projectOriginIssue(projectID: "p", key: "project-origin-1")
            // The issue exists and is readable through the adapter's project-scoped reads...
            let detail = try f.payload(await f.tool("get_issue", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue)])))
            #expect(detail["proposal"]?["version"]?.integer == 1)
            // ...but the project-origin write is refused: the caller's context is the app's
            // main conversation, never the issue's owning project conversation.
            #expect(try f.errorCode(await f.tool("update_issue_proposal", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "expectedVersion": .number(1), "instruction": .string("프로젝트 이슈 고치기")
            ]))) == "not_found")
            #expect(try await f.issue(id)?.proposal?.version == 1)

            // A caller cannot smuggle a different origin/thread through the arguments.
            for field in ["threadID", "originThreadID", "conversationThreadID", "source"] {
                #expect(try f.errorCode(await f.tool("update_issue_proposal", .object([
                    "projectID": .string("p"), "issueID": .string(id.rawValue),
                    "expectedVersion": .number(1), "instruction": .string("우회 시도"),
                    field: .string(ConversationThread.defaultID)
                ]))) == "invalid_request")
            }
            #expect(try await f.issue(id)?.proposal?.version == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func duplicateFastPathStillAppliesTheOwnershipGate() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let id = try await f.projectOriginIssue(projectID: "p", key: "project-origin-2")
            // Advance the project issue to version 2 through its own project session.
            let projectSession = try await f.session(threadID: try #require(try await f.issue(id)?.conversationThreadID))
            try await projectSession.updateIssueProposal(issueID: id, expectedVersion: 1,
                                                         instruction: "프로젝트에서 고친 지시")
            let saved = try #require(try await f.issue(id))
            #expect(saved.proposal?.version == 2)
            // This request looks exactly like a resend of the write that made version 2. The
            // caller still has no write authority, so the shortcut must not answer success.
            #expect(try f.errorCode(await f.tool("update_issue_proposal", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "expectedVersion": .number(1), "instruction": .string("프로젝트에서 고친 지시")
            ]))) == "not_found")
            #expect(try await f.issue(id)?.proposal?.version == 2)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func mainOriginWritesStayInsideTheAppContext() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let created = try f.payload(await f.tool("create_issue", .object([
                "projectID": .string("p"), "idempotencyKey": .string("main-origin-1"),
                "title": .string("메인 기원 이슈"), "criteria": .array([.string("경계")]),
                "instruction": .string("메인 문맥 확인")
            ])))
            let id = KnarrCore.Issue.ID(try #require(created["issueID"]?.string))
            let issue = try #require(try await f.issue(id))
            // Creation is filed under the app's main conversation.
            let origin = try #require(try await f.snapshot().threads.first { $0.id == issue.conversationThreadID })
            #expect(origin.originThreadID == ConversationThread.defaultID)
            #expect(try f.payload(await f.tool("update_issue_proposal", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "expectedVersion": .number(1), "instruction": .string("메인 문맥 수정")
            ])))["version"]?.integer == 2)
            #expect(await f.rpc.prompts.isEmpty)
            #expect(await f.hird.runs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func closeReusesMainAuthorityWhileUpdateStaysRestricted() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let id = try await f.projectOriginIssue(projectID: "p", key: "project-close-1")
            // Main may close issues in registered projects regardless of the owning
            // conversation; the adapter reuses that rule rather than inventing one.
            let closed = try f.payload(await f.tool("close_issue", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "reason": .string("cancelled"), "note": .string("정리"),
                "expectedVersion": .number(1)])))
            #expect(closed["status"]?.string == "closed")
            let issue = try #require(try await f.issue(id))
            #expect(issue.archiveReason == IssueCloseReason.cancelled.rawValue)
            #expect(issue.archiveNote == "정리")
            // Proposal edits in that same project conversation stay refused.
            #expect(try f.errorCode(await f.tool("update_issue_proposal", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "expectedVersion": .number(1), "instruction": .string("닫힌 뒤 수정")
            ]))) == "conflict")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    // MARK: - Durable create resend

    @Test func createResendStillMatchesAfterTheProposalWasUpdated() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let original: OMPJSON = .object([
                "projectID": .string("p"), "idempotencyKey": .string("durable-1"),
                "title": .string("재전송 이슈"), "criteria": .array([.string("재전송")]),
                "instruction": .string("처음 지시")
            ])
            let created = try f.payload(await f.tool("create_issue", original))
            let id = KnarrCore.Issue.ID(try #require(created["issueID"]?.string))
            _ = try f.payload(await f.tool("update_issue_proposal", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "expectedVersion": .number(1), "instruction": .string("앱에서 고친 지시")
            ])))
            #expect(try await f.issue(id)?.proposal?.version == 2)

            // The original request is still the same request: same issue, no new version.
            let replay = try f.payload(await f.tool("create_issue", original))
            #expect(replay["issueID"]?.string == id.rawValue)
            #expect(replay["duplicate"]?.bool == true)
            #expect(try await f.issue(id)?.proposal?.version == 2)
            #expect(try await f.snapshot().issues.count == 1)

            // Changing the handoff is a different request; it must not claim that new text was saved.
            var withSummary = original
            if case .object(var fields) = withSummary {
                fields["handoffSummary"] = .string("다른 인계 요약")
                withSummary = .object(fields)
            }
            #expect(try f.errorCode(await f.tool("create_issue", withSummary)) == "conflict")

            // A real difference is still a conflict.
            #expect(try f.errorCode(await f.tool("create_issue", .object([
                "projectID": .string("p"), "idempotencyKey": .string("durable-1"),
                "title": .string("재전송 이슈"), "criteria": .array([.string("재전송")]),
                "instruction": .string("다른 지시")
            ]))) == "conflict")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func createResendSurvivesProjectDefaultChangesAndReopen() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let request: OMPJSON = .object([
                "projectID": .string("p"), "idempotencyKey": .string("defaults-1"),
                "title": .string("기본값 이슈"), "criteria": .array([.string("기본값")]),
                "instruction": .string("기본값 확인")
            ])
            let created = try f.payload(await f.tool("create_issue", request))
            let id = KnarrCore.Issue.ID(try #require(created["issueID"]?.string))
            #expect(created["version"]?.integer == 1)

            // The project gains a default criterion after the issue was created.
            var project = try #require(try await f.snapshot().projects.first { $0.id == "p" })
            project.settings.criteria = ["나중에 추가된 기본 조건"]
            try await f.repository.saveProject(project)

            let replay = try f.payload(await f.tool("create_issue", request))
            #expect(replay["issueID"]?.string == id.rawValue)
            #expect(replay["duplicate"]?.bool == true)
            #expect(try await f.snapshot().issues.count == 1)

            // The same identity is found again in a second process over the same database.
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            let service = KnarrAdminService(repository: reopened) { throw KnarrAdminError.unavailable("다시 연 저장소는 세션이 없습니다") }
            let createdAgain = try await service.adminCall("create_issue", arguments: request)
            #expect(createdAgain["issueID"]?.string == id.rawValue)
            #expect(createdAgain["duplicate"]?.bool == true)
            try await reopened.close()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func concurrentSameKeyCreatesConvergeOnOneIssue() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let request: OMPJSON = .object([
                "projectID": .string("p"), "idempotencyKey": .string("concurrent-1"),
                "title": .string("동시 생성"), "criteria": .array([.string("동시")]),
                "instruction": .string("동시 생성 확인")
            ])
            async let first = f.tool("create_issue", request, id: 21)
            async let second = f.tool("create_issue", request, id: 22)
            let replies = await [first, second]
            let payloads = try replies.map { try f.payload($0) }
            let ids = Set(try payloads.map { try #require($0["issueID"]?.string) })
            #expect(ids.count == 1)
            #expect(payloads.filter { $0["duplicate"]?.bool == false }.count == 1)
            #expect(try await f.snapshot().issues.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    // MARK: - Update resend semantics

    @Test func updateResendDoesNotTreatOmittedFieldsAsMatching() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let created = try f.payload(await f.tool("create_issue", .object([
                "projectID": .string("p"), "idempotencyKey": .string("update-resend-1"),
                "title": .string("수정 재전송"), "criteria": .array([.string("재전송")]),
                "instruction": .string("처음"), "model": .string("openai-codex/fixture-gpt")
            ])))
            let id = KnarrCore.Issue.ID(try #require(created["issueID"]?.string))
            // The app changes the model to something else at version 2.
            let session = try await f.session(threadID: try #require(try await f.issue(id)?.conversationThreadID))
            try await session.updateIssueProposal(issueID: id, expectedVersion: 1,
                                                  instruction: "처음", model: "anthropic/fixture-claude")
            #expect(try await f.issue(id)?.proposal?.model == "anthropic/fixture-claude")

            // A caller resending a request that omits the model must not be told its request
            // succeeded: the saved revision used a model the caller never chose.
            let reply = await f.tool("update_issue_proposal", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "expectedVersion": .number(1), "instruction": .string("처음")
            ]))
            #expect(try f.errorCode(reply) == "conflict")
            #expect(try await f.issue(id)?.proposal?.version == 2)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    // MARK: - Close preconditions

    @Test func closeRequiresTheStatedVersionAndAnIdenticalResend() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let created = try f.payload(await f.tool("create_issue", .object([
                "projectID": .string("p"), "idempotencyKey": .string("close-version-1"),
                "title": .string("닫기 버전"), "criteria": .array([.string("닫기")]),
                "instruction": .string("닫기 확인")
            ])))
            let id = KnarrCore.Issue.ID(try #require(created["issueID"]?.string))
            // A stale expected version is refused before anything is written.
            #expect(try f.errorCode(await f.tool("close_issue", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "reason": .string("cancelled"), "note": .string("정리"),
                "expectedVersion": .number(5)]))) == "conflict")
            #expect(try await f.issue(id)?.archivedAt == nil)

            let closed = try f.payload(await f.tool("close_issue", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "reason": .string("cancelled"), "note": .string("정리"),
                "expectedVersion": .number(1)])))
            #expect(closed["status"]?.string == "closed")
            #expect(try await f.issue(id)?.archivedAt != nil)

            // The same reason with a different note is a different request, not a resend.
            #expect(try f.errorCode(await f.tool("close_issue", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "reason": .string("cancelled"), "note": .string("다른 메모"),
                "expectedVersion": .number(1)]))) == "conflict")
            #expect(try await f.issue(id)?.archiveNote == "정리")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func closeLosesToARunThatStartsFirst() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let created = try f.payload(await f.tool("create_issue", .object([
                "projectID": .string("p"), "idempotencyKey": .string("close-race-1"),
                "title": .string("닫기 경쟁"), "criteria": .array([.string("경쟁")]),
                "instruction": .string("경쟁 확인")
            ])))
            let id = KnarrCore.Issue.ID(try #require(created["issueID"]?.string))
            let threadID = try #require(try await f.issue(id)?.conversationThreadID)
            let owner = try await f.session(threadID: threadID)
            let runID = try await owner.approveIssue(issueID: id, version: 1)
            // The stored run makes the atomic close path refuse; the run keeps running.
            #expect(try f.errorCode(await f.tool("close_issue", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "reason": .string("cancelled"), "note": .string("경쟁"), "expectedVersion": .number(1)]))) == "conflict")
            let issue = try #require(try await f.issue(id))
            #expect(issue.archivedAt == nil)
            #expect(try await f.snapshot().runs.contains { $0.id == runID })
            #expect(!(await f.hird.cancelled).contains(runID))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
