import Foundation
import Testing
@testable import KnarrCore
import KnarrMCP

/// Protocol surface and the protected-contract refusals. Each test drives the same dispatcher
/// the socket handler uses, so a passing test covers initialize → tools/list → tools/call.
@MainActor @Suite(.serialized) struct MCPServerTests {
    @Test func initializeToolsListAndUnknownMethodBehavePerProtocol() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let initReply = await f.call("initialize", .object([
                "protocolVersion": .string("2025-06-18"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("fixture"), "version": .string("1.0")])
            ]))
            #expect(initReply["result"]?["protocolVersion"]?.string == "2025-06-18")
            #expect(initReply["result"]?["serverInfo"]?["name"]?.string == "knarr")
            #expect(initReply["result"]?["capabilities"]?["tools"] != nil)
            // A later, newer client version falls back to the server's latest supported version.
            let newer = await f.call("initialize", .object(["protocolVersion": .string("2026-07-28")]), id: 9)
            #expect(newer["result"]?["protocolVersion"]?.string == MCPToolCatalog.latestProtocolVersion)

            // Lifecycle is per connection: a fresh server refuses requests until it negotiates.
            let fresh = MCPServer(service: f.service)
            let premature = await fresh.handle(.object(["jsonrpc": .string("2.0"), "id": .number(5),
                "method": .string("tools/list"), "params": .object([:])]))
            #expect(premature?["error"]?["code"]?.integer == -32600)
            let prematureCall = await fresh.handle(.object(["jsonrpc": .string("2.0"), "id": .number(6),
                "method": .string("tools/call"),
                "params": .object(["name": .string("list_projects"),
                                   "arguments": .object([:])])]))
            #expect(prematureCall?["error"]?["code"]?.integer == -32600)
            _ = await fresh.handle(.object(["jsonrpc": .string("2.0"), "id": .number(7),
                "method": .string("initialize"),
                "params": .object(["protocolVersion": .string("2025-06-18")])]))
            let afterNegotiation = await fresh.handle(.object(["jsonrpc": .string("2.0"), "id": .number(8),
                "method": .string("tools/list"), "params": .object([:])]))
            #expect(afterNegotiation?["result"]?["tools"]?.array?.count == MCPToolCatalog.toolNames.count)
            // That negotiation belongs to `fresh` only; the fixture's own connection is unaffected.

            let listed = await f.call("tools/list")
            let tools = try #require(listed["result"]?["tools"]?.array)
            #expect(tools.compactMap { $0["name"]?.string } == MCPToolCatalog.toolNames)
            for tool in tools {
                #expect(tool["inputSchema"]?["type"]?.string == "object")
                #expect(tool["description"]?.string?.isEmpty == false)
            }
            // A client building a close request from tools/list must be told about the
            // revision guard that the app requires before it can close the saved proposal.
            let closeTool = try #require(tools.first { $0["name"]?.string == "close_issue" })
            let closeSchema = try #require(closeTool["inputSchema"])
            #expect(closeSchema["properties"]?["expectedVersion"]?["type"]?.string == "integer")
            #expect(closeSchema["properties"]?["expectedVersion"]?["minimum"]?.integer == 1)
            #expect(closeSchema["required"]?.array?.contains(.string("expectedVersion")) == true)
            // No filesystem or execution tool is reachable through this catalog.
            for forbidden in ["read", "write", "bash", "eval", "edit"] {
                #expect(!MCPToolCatalog.toolNames.contains(forbidden))
            }

            let missing = await f.call("resources/list")
            #expect(missing["error"]?["code"]?.integer == -32601)
            let unknown = await f.tool("run_shell", .object([:]))
            #expect(unknown["error"]?["data"]?["code"]?.string == "unknown_tool")
            // A notification never gets a reply.
            let notification = await f.server.handle(.object([
                "jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
            #expect(notification == nil)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func createIssueSavesAwaitingApprovalProposalWithoutStartingHirdOrPrompting() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let reply = await f.tool("create_issue", .object([
                "projectID": .string("p"),
                "idempotencyKey": .string("fixture-create-1"),
                "title": .string("MCP로 만든 이슈"),
                "criteria": .array([.string("조회가 동작해요")]),
                "instruction": .string("MCP 어댑터의 조회 경로를 확인해요"),
                "stages": .array([.object(["title": .string("단계1"), "evidence": .string("테스트 통과")])]),
                "handoffSummary": .string("MCP 이슈 생성")
            ]))
            let payload = try f.payload(reply)
            let id = KnarrCore.Issue.ID(try #require(payload["issueID"]?.string))
            #expect(payload["state"]?.string == "awaitingApproval")
            #expect(payload["version"]?.integer == 1)
            #expect(payload["duplicate"]?.bool == false)

            let issue = try #require(try await f.issue(id))
            #expect(issue.state == .awaitingApproval)
            #expect(issue.proposal?.instruction == "MCP 어댑터의 조회 경로를 확인해요")
            #expect(issue.proposal?.mode == .change)
            #expect(issue.proposal?.stagePlan.count == 1)
            #expect(issue.approval == nil)
            #expect(issue.conversationThreadID != ConversationThread.defaultID)
            #expect(issue.acceptance.map(\.text) == ["조회가 동작해요"])
            let snapshot = try await f.snapshot()
            #expect(snapshot.threads.contains { $0.id == issue.conversationThreadID && $0.name == "MCP로 만든 이슈" })
            #expect(snapshot.chatLinks.contains { $0.issueID == id && $0.conversationThreadID == issue.conversationThreadID })
            #expect(snapshot.runs.isEmpty)
            #expect(await f.hird.runs.isEmpty)
            #expect(await f.rpc.prompts.isEmpty)

            // The same key returns the same issue; nothing is created a second time.
            let replay = try f.payload(await f.tool("create_issue", .object([
                "projectID": .string("p"),
                "idempotencyKey": .string("fixture-create-1"),
                "title": .string("MCP로 만든 이슈"),
                "criteria": .array([.string("조회가 동작해요")]),
                "instruction": .string("MCP 어댑터의 조회 경로를 확인해요"),
                "stages": .array([.object(["title": .string("단계1"), "evidence": .string("테스트 통과")])]),
                "handoffSummary": .string("MCP 이슈 생성")
            ])))
            #expect(replay["issueID"]?.string == id.rawValue)
            #expect(replay["duplicate"]?.bool == true)
            #expect(try await f.snapshot().issues.count == 1)

            // The same key with different content is a conflict, never a silent second issue.
            let conflict = try f.errorCode(await f.tool("create_issue", .object([
                "projectID": .string("p"),
                "idempotencyKey": .string("fixture-create-1"),
                "title": .string("다른 제목"),
                "criteria": .array([.string("조회가 동작해요")]),
                "instruction": .string("MCP 어댑터의 조회 경로를 확인해요")
            ])))
            #expect(conflict == "conflict")
            #expect(try await f.snapshot().issues.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func readsReturnTheSameStoredVersionsAndRejectWrongTargets() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            _ = try f.payload(await f.tool("create_issue", .object([
                "projectID": .string("p"), "idempotencyKey": .string("read-1"),
                "title": .string("조회 이슈"), "criteria": .array([.string("조회")]),
                "instruction": .string("조회 경로 확인")
            ])))
            let issues = try f.payload(await f.tool("list_issues", .object(["projectID": .string("p")])))
            let listed = try #require(issues["issues"]?.array?.first)
            let id = try #require(listed["issueID"]?.string)
            #expect(listed["proposalVersion"]?.integer == 1)
            #expect(listed["status"]?.string == "awaitingApproval")
            #expect(issues["nextOffset"] == .null)

            let detail = try f.payload(await f.tool("get_issue", .object([
                "projectID": .string("p"), "issueID": .string(id)])))
            #expect(detail["issue"]?["issueID"]?.string == id)
            #expect(detail["proposal"]?["version"]?.integer == 1)
            #expect(detail["proposalHistory"]?.array?.count == 1)
            #expect(detail["approval"] == .null)
            #expect(detail["criteria"]?.array?.first?["state"]?.string == "pending")

            // An issue is only reachable through the project that actually owns it.
            #expect(try f.errorCode(await f.tool("get_issue", .object([
                "projectID": .string("other"), "issueID": .string(id)]))) == "not_found")
            #expect(try f.errorCode(await f.tool("get_issue", .object([
                "projectID": .string("p"), "issueID": .string("mcp-missing")]))) == "not_found")
            #expect(try f.errorCode(await f.tool("list_issues", .object([
                "projectID": .string("knarr-hub")]))) == "not_found")
            // Unknown arguments are refused; a typo cannot silently act on another target.
            #expect(try f.errorCode(await f.tool("get_issue", .object([
                "projectID": .string("p"), "issueID": .string(id), "expectedVersion": .number(1)]))) == "invalid_request")

            let projects = try f.payload(await f.tool("list_projects", .object([:])))
            let listedProjects = try #require(projects["projects"]?.array?.compactMap { $0["projectID"]?.string })
            #expect(Set(listedProjects) == ["p", "other"])
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func proposalUpdateRequiresExactVersionAndNeverApproves() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let created = try f.payload(await f.tool("create_issue", .object([
                "projectID": .string("p"), "idempotencyKey": .string("update-1"),
                "title": .string("수정 이슈"), "criteria": .array([.string("수정")]),
                "instruction": .string("처음 지시")
            ])))
            let id = KnarrCore.Issue.ID(try #require(created["issueID"]?.string))

            // Stale version: refused with the current version visible in the app's own record.
            #expect(try f.errorCode(await f.tool("update_issue_proposal", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "expectedVersion": .number(3), "instruction": .string("늦은 수정")
            ]))) == "conflict")
            #expect(try await f.issue(id)?.proposal?.version == 1)

            let updated = try f.payload(await f.tool("update_issue_proposal", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "expectedVersion": .number(1), "instruction": .string("고친 지시"),
                "mode": .string("inspect")
            ])))
            #expect(updated["version"]?.integer == 2)
            #expect(updated["duplicate"]?.bool == false)
            let issue = try #require(try await f.issue(id))
            #expect(issue.proposal?.instruction == "고친 지시")
            #expect(issue.proposal?.mode == .inspect)
            #expect(issue.state == .awaitingApproval)
            #expect(issue.approval == nil)
            #expect(issue.proposalHistory?.map(\.version) == [1, 2])
            #expect(try await f.snapshot().runs.isEmpty)
            #expect(await f.hird.runs.isEmpty)

            // A resend of the exact saved revision is reported as the same version, not version 3.
            let replay = try f.payload(await f.tool("update_issue_proposal", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "expectedVersion": .number(1), "instruction": .string("고친 지시"),
                "mode": .string("inspect")
            ])))
            #expect(replay["version"]?.integer == 2)
            #expect(replay["duplicate"]?.bool == true)
            #expect(try await f.issue(id)?.proposalHistory?.count == 2)

            // Same version, different content: refused rather than overwriting a newer revision.
            #expect(try f.errorCode(await f.tool("update_issue_proposal", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "expectedVersion": .number(1), "instruction": .string("다른 지시")
            ]))) == "conflict")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func closePreservesHistoryAndRefusesActiveOrWrongTargets() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let created = try f.payload(await f.tool("create_issue", .object([
                "projectID": .string("p"), "idempotencyKey": .string("close-1"),
                "title": .string("닫을 이슈"), "criteria": .array([.string("닫기")]),
                "instruction": .string("닫기 경로 확인")
            ])))
            let id = KnarrCore.Issue.ID(try #require(created["issueID"]?.string))
            #expect(try f.errorCode(await f.tool("close_issue", .object([
                "projectID": .string("other"), "issueID": .string(id.rawValue),
                "reason": .string("cancelled"), "note": .string("닫기"),
                "expectedVersion": .number(1)]))) == "not_found")
            #expect(try f.errorCode(await f.tool("close_issue", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "reason": .string("applied"), "expectedVersion": .number(1)]))) == "invalid_request")
            #expect(try f.errorCode(await f.tool("close_issue", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "reason": .string("deleted"), "note": .string("닫기"),
                "expectedVersion": .number(1)]))) == "invalid_request")

            let closed = try f.payload(await f.tool("close_issue", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "reason": .string("cancelled"), "note": .string("사용자가 취소"),
                "expectedVersion": .number(1)])))
            #expect(closed["status"]?.string == "closed")
            let issue = try #require(try await f.issue(id))
            #expect(issue.archivedAt != nil)
            #expect(issue.archiveReason == IssueCloseReason.cancelled.rawValue)
            #expect(issue.archiveNote == "사용자가 취소")
            #expect(issue.proposal?.instruction == "닫기 경로 확인")
            #expect(issue.acceptance.map(\.text) == ["닫기"])

            // Repeating the same closure is reported as success without rewriting the record.
            let replay = try f.payload(await f.tool("close_issue", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "reason": .string("cancelled"), "note": .string("사용자가 취소"),
                "expectedVersion": .number(1)])))
            #expect(replay["duplicate"]?.bool == true)
            // A different reason on a closed issue is a conflict, not a second closure.
            #expect(try f.errorCode(await f.tool("close_issue", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "reason": .string("applied"), "note": .string("반영"),
                "expectedVersion": .number(1)]))) == "conflict")

            // A closed issue's proposal is read-only through this adapter too.
            #expect(try f.errorCode(await f.tool("update_issue_proposal", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "expectedVersion": .number(1), "instruction": .string("닫힌 뒤 수정")
            ]))) == "conflict")
            // Archived issues leave the default list but remain readable with includeArchived.
            let listed = try f.payload(await f.tool("list_issues", .object(["projectID": .string("p")])))
            #expect(listed["issues"]?.array?.isEmpty == true)
            let archived = try f.payload(await f.tool("list_issues", .object([
                "projectID": .string("p"), "includeArchived": .bool(true)])))
            #expect(archived["issues"]?.array?.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func closeRefusesWhileHirdIsRunningWithoutCancellingIt() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let created = try f.payload(await f.tool("create_issue", .object([
                "projectID": .string("p"), "idempotencyKey": .string("active-1"),
                "title": .string("진행 중 이슈"), "criteria": .array([.string("진행")]),
                "instruction": .string("진행 중 닫기 확인")
            ])))
            let id = KnarrCore.Issue.ID(try #require(created["issueID"]?.string))
            let threadID = try #require(try await f.issue(id)?.conversationThreadID)
            // Approval remains a screen/Stallari action; this test starts the run through the
            // issue's own session to reach the state the MCP adapter must refuse.
            let owner = StallariSession(repository: f.repository, rpc: f.rpc, hird: f.hird, threadID: threadID)
            let runID = try await owner.approveIssue(issueID: id, version: 1)
            let refused = try f.errorCode(await f.tool("close_issue", .object([
                "projectID": .string("p"), "issueID": .string(id.rawValue),
                "reason": .string("cancelled"), "note": .string("정리"),
                "expectedVersion": .number(1)])))
            #expect(refused == "conflict")
            let issue = try #require(try await f.issue(id))
            #expect(issue.archivedAt == nil)
            let runs = try await f.snapshot().runs
            #expect(runs.contains { $0.id == runID && !$0.state.isTerminal })
            #expect(!(await f.hird.cancelled).contains(runID))
            _ = await owner.shutdown()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
