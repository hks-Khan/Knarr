import Foundation
import Testing
@testable import KnarrCore

private let stallariRPCFixture = #"""
import sys,json
results={};prompts=[];tools=[];streaming=False
def emit(v):
 print(json.dumps(v,separators=(',',':')),flush=True)
def reply(r,data={}):
 emit(dict(type='response',id=r['id'],command=r['type'],success=True,data=data))
emit(dict(type='ready',protocolVersion=1,supportedProtocolVersions=[1,2],maxFrameBytes=1048576,maxReassembledFrameBytes=67108864))
for line in sys.stdin:
 r=json.loads(line);t=r['type']
 if t=='negotiate_protocol': reply(r,dict(protocolVersion=2))
 elif t=='set_host_tools':
  tools=r['tools'];reply(r,dict(toolNames=[x['name'] for x in tools]))
 elif t=='get_state': reply(r,dict(sessionId='rpc-fixture',thinkingLevel='high',isStreaming=streaming,dumpTools=[dict(name=n) for n in ('read','grep','glob','bash','task')]+tools,todoPhases=[],isSettled=not streaming))
 elif t=='get_available_thinking_levels': reply(r,dict(levels=['off','high']))
 elif t=='get_available_models': reply(r,dict(models=[dict(provider='openai-codex',id='fixture-model')]))
 elif t=='invoke_host':
  reply(r)
  emit(dict(type='host_tool_call',id=r['callID'],toolCallId='MODEL-'+r['callID'],toolName=r['name'],arguments=r['arguments']))
 elif t=='host_tool_result': results[r['id']]=r
 elif t=='fixture_results': reply(r,dict(results=results,prompts=prompts))
 elif t=='fixture_end':
  reply(r);emit(dict(type='agent_end'));emit(dict(type='prompt_result',status='completed',sessionSettled=True));emit(dict(type='session_settled'))
 elif t=='fixture_cancel':
  reply(r);emit(dict(type='host_tool_cancel',id='cancel-frame',targetId=r['targetId']))
 elif t=='prompt' and r['message']=='/knarr-stallari-tools':
  emit(dict(type='extension_ui_request',method='setStatus',statusKey='__knarr_tool_policy__',statusText='ready'));reply(r,dict(agentInvoked=False))
 elif t=='prompt':
  prompts.append(dict(message=r['message'],streamingBehavior=r.get('streamingBehavior')));reply(r,dict(queued=streaming))
 elif t=='fixture_busy': streaming=r['busy'];reply(r)
 else: reply(r)
"""#

@Suite(.serialized) struct StallariRPCTests {
    @Test func realTransportKeepsReceivingWhileQuestionsPendingAndUsesExactHostFrameID() async throws {
        let f = try await StallariFixture.make()
        let script = f.directory.appendingPathComponent("rpc.py")
        try stallariRPCFixture.write(to: script, atomically: true, encoding: .utf8)
        let rpc = OMPRPCSession()
        let stallari = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird)
        do {
            try await rpc.start(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"), workingDirectory: f.directory, arguments: [script.path]))
            try await stallari.connect()
            func invoke(_ id: String, _ name: String, _ arguments: [String: OMPJSON]) async throws -> OMPJSON {
                _ = try await rpc.request("invoke_host", fields: ["callID": .string(id), "name": .string(name), "arguments": .object(arguments)])
                let deadline = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < deadline {
                    let results = try await rpc.request("fixture_results")
                    if let result = results["data"]?["results"]?[id] { return result }
                    try await Task.sleep(for: .milliseconds(5))
                }
                throw OMPRPCError.timedOut
            }
            // The transport/question fixture keeps its legacy same-thread binding;
            // dedicated issue creation and owner routing are covered end-to-end separately.
            _ = try await f.legacyIssue(id: "t", title: "합계", criteria: ["합계 검사"], instruction: "합계 수정")
            let created = try await invoke("HOST-create", "create_issue", ["issueID": .string("t"), "title": .string("합계"), "criteria": .array([.string("합계 검사")]), "instruction": .string("합계 수정"), "model": .string("openai-codex/fixture-model")])
            #expect(created["id"]?.string == "HOST-create")
            #expect(created["result"]?["details"]?["issueID"]?.string == "t")
            let denied = try await invoke("HOST-unapproved", "dispatch_hird", ["issueID": .string("t"), "runID": .string("unapproved")])
            #expect(denied["isError"]?.bool == true)
            #expect(try await f.repository.snapshot().runs.isEmpty)
            #expect(try await f.repository.snapshot().issues.first?.state == .awaitingApproval)
            let approvedRun = try await stallari.approveIssue(issueID: "t", version: 1)
            _ = try await invoke("HOST-dispatch", "dispatch_hird", ["issueID": .string("t"), "runID": .string(approvedRun.rawValue)])
            for index in 1...2 {
                let answer = try await invoke("HOST-ask\(index)", "ask_user", ["issueID": .string("t"), "runID": .string(approvedRun.rawValue), "questionID": .string("q\(index)"), "prompt": .string("선택 \(index)"), "options": .array([.string("A"), .string("B")])])
                #expect(answer["result"]?["details"]?["status"]?.string == "waitingOnHuman")
            }
            #expect(try await stallari.getState()["data"]?["sessionId"]?.string == "rpc-fixture")
            #expect(try await f.repository.snapshot().questions.filter { $0.state == .pending }.count == 2)
            _ = try await rpc.request("fixture_end")
            let other = try await f.legacyIssue(id: "other", title: "다른 실행", criteria: ["검사"], instruction: "다른 실행")
            _ = try await f.repository.approveIssueProposal(issueID: other, version: 1, at: .now)
            _ = try await stallari.dispatch(issueID: other, runID: "r2")
            _ = try await stallari.receive(.init(id: "end-other", runID: "r2", at: .now, payload: .complete(f.result(), notificationID: "notice-other")))
            #expect(try await rpc.request("fixture_results")["data"]?["prompts"]?.array?.count == 1)
            #expect(try await f.repository.snapshot().issues.allSatisfy { $0.state != .done })
            _ = try await stallari.answer(questionID: "q2", runID: approvedRun, issueID: "t", answer: .init(selectedOptions: ["B"], text: nil))
            _ = try await stallari.answer(questionID: "q1", runID: approvedRun, issueID: "t", answer: .init(selectedOptions: ["A"], text: nil))
            #expect(await f.hird.resolutions.map(\.questionID) == ["q2", "q1"])
            // A duplicate frame gets the stored reply; it does not create another run.
            _ = try await invoke("HOST-dispatch", "dispatch_hird", ["issueID": .string("t"), "runID": .string(approvedRun.rawValue)])
            #expect(try await f.repository.snapshot().runs.count == 2)
            let exit = await stallari.shutdown()
            #expect(exit.remainingProcessIDs.isEmpty)
            print("Stallari RPC fixture: pending_questions=2 get_state=ok other_notification=ok host_id=exact model_end_does_not_judge=true owned_remaining=0")
            try await f.cleanup()
        } catch { _ = await stallari.shutdown(); try await f.cleanup(); throw error }
    }
}
