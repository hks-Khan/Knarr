import Foundation
import Testing
@testable import KnarrCore

private let eventBufferPeer = #"""
import sys,json
def emit(v): print(json.dumps(v,separators=(',',':')),flush=True)
def reply(r): emit(dict(type='response',id=r['id'],command=r['type'],success=True,data=dict(protocolVersion=2)))
emit(dict(type='ready',protocolVersion=1,supportedProtocolVersions=[1,2],maxFrameBytes=1048576,maxReassembledFrameBytes=67108864))
for line in sys.stdin:
 r=json.loads(line)
 if r['type']=='burst':
  boundaries=['tool_execution_start','extension_ui_request','tool_execution_end','extension_error','prompt_result']
  for index,boundary in enumerate(boundaries):
   for n in range(1000):
    emit(dict(type='message_update',messageId='answer',message=dict(role='assistant'),assistantMessageEvent=dict(type='text_delta',contentIndex=0,delta='한글😀')))
   emit(dict(type=boundary,marker=index))
  emit(dict(type='message_end',messageId='answer',message=dict(role='assistant',content=[dict(type='text',text='한글😀'*5000)])))
  emit(dict(type='session_settled'))
  emit(dict(type='burst_end'))
 elif r['type']=='critical_burst':
  for n in range(2000): emit(dict(type='host_tool_call',id=str(n)))
  emit(dict(type='burst_end'))
 reply(r)
"""#

@Suite(.serialized) struct OMPEventBufferTests {
    @Test func slowConsumerCoalescesTextWithoutLosingBoundariesOrBlockingRPC() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        try eventBufferPeer.write(to: fixture.directory.appendingPathComponent("fixture.py"), atomically: true, encoding: .utf8)
        let rpc = OMPRPCSession()
        do {
            try await rpc.start(fixture.configuration)
            let stream = await rpc.subscribe()
            // Deliberately do not read the event stream until its final response arrives.
            // Backpressure at the subscriber would deadlock this request's response.
            #expect(try await rpc.request("burst")["success"]?.bool == true)
            let metrics = try #require(await rpc.eventBufferMetrics().first)
            print("event-buffer received=\(metrics.receivedFrames) coalesced=\(metrics.coalescedFrames) queued=\(metrics.queuedFrames) highWater=\(metrics.peakQueuedFrames)")
            #expect(metrics.coalescedFrames == 4995)
            #expect(metrics.queuedFrames == 13)
            var iterator = stream.makeAsyncIterator(), chunks: [String] = [], boundaries: [String] = []
            var frames = 0
            while let event = await iterator.next() {
                guard case .frame(let frame) = event else { break }
                frames += 1
                let type = frame["type"]?.string ?? ""
                if type == "message_update" { chunks.append(frame["assistantMessageEvent"]?["delta"]?.string ?? "") }
                else { boundaries.append(type) }
                if type == "tool_execution_start" { #expect(try await rpc.request("get_state")["success"]?.bool == true) }
                if type == "message_end" { #expect(frame["message"]?["content"]?.array?.first?["text"]?.string == String(repeating: "한글😀", count: 5000)) }
                if type == "burst_end" { break }
            }
            #expect(chunks.joined() == String(repeating: "한글😀", count: 5000))
            #expect(boundaries == ["tool_execution_start", "extension_ui_request", "tool_execution_end", "extension_error", "prompt_result", "message_end", "session_settled", "burst_end"])
            print("slow-consumer sourceFrames=5008 deliveredFrames=\(frames) deltaFrames=\(chunks.count) textUTF8Bytes=\(chunks.joined().utf8.count)")
            #expect(frames < 25)
            #expect(await rpc.shutdown().remainingProcessIDs.isEmpty)
            guard case .terminated? = await iterator.next() else { Issue.record("Lost termination"); return }
            #expect(await iterator.next() == nil)
        } catch { _ = await rpc.shutdown(cancel: true); throw error }
    }

    @Test func criticalBurstPreservesEveryIDAndCancellationTerminal() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        try eventBufferPeer.write(to: fixture.directory.appendingPathComponent("fixture.py"), atomically: true, encoding: .utf8)
        let rpc = OMPRPCSession()
        do {
            try await rpc.start(fixture.configuration)
            let stream = await rpc.subscribe()
            #expect(try await rpc.request("critical_burst")["success"]?.bool == true)
            let metrics = try #require(await rpc.eventBufferMetrics().first)
            #expect(metrics.queuedFrames == 2001)
            print("critical-only queue=\(metrics.queuedFrames) preserved=2000 hardCap=false")
            let exit = await rpc.shutdown(cancel: true)
            #expect(exit.remainingProcessIDs.isEmpty)
            var ids: [String] = [], terminal = false
            for await event in stream {
                if case .frame(let frame) = event, let id = frame["id"]?.string { ids.append(id) }
                if case .terminated(let value) = event { terminal = value.reason == .cancelled }
            }
            #expect(ids == (0..<2000).map(String.init))
            #expect(terminal)
        } catch { _ = await rpc.shutdown(cancel: true); throw error }
    }
    @Test func mergeBudgetAndMessageIdentityNeverTruncateOrCrossBlocks() async {
        let buffer = OMPEventBuffer()
        func delta(_ id: String, _ index: Int, _ text: String) -> OMPEvent {
            .frame(.object(["type": .string("message_update"), "messageId": .string(id), "message": .object(["role": .string("assistant")]),
                "assistantMessageEvent": .object(["type": .string("text_delta"), "contentIndex": .number(Double(index)), "delta": .string(text)])]))
        }
        for _ in 0..<6000 { buffer.offer(delta("a", 0, "한글😀")); buffer.offer(delta("a", 0, "")) }
        buffer.offer(delta("b", 0, "other")); buffer.offer(delta("a", 1, "next block"))
        buffer.finish()
        var texts: [String] = [], keys: [String] = []
        while let event = await buffer.next() {
            if case .frame(let frame) = event {
                let text = frame["assistantMessageEvent"]?["delta"]?.string ?? ""
                #expect(text.utf8.count <= OMPEventBuffer.maxCoalescedBytes)
                texts.append(text); keys.append((frame["messageId"]?.string ?? "") + ":" + String(frame["assistantMessageEvent"]?["contentIndex"]?.integer ?? -1))
            }
        }
        #expect(texts.prefix(2).joined() == String(repeating: "한글😀", count: 6000))
        #expect(keys == ["a:0", "a:0", "b:0", "a:1"])
    }

}
