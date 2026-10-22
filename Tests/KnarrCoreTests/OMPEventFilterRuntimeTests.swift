import Foundation
import Testing
@testable import KnarrCore

private actor FilterProbeCounter {
    var frames: [OMPJSON] = []
    func add(_ event: OMPEvent) { if case .frame(let frame) = event { frames.append(frame) } }
    func results() -> Int { frames.filter { $0["type"]?.string == "prompt_result" }.count }
    func reset() { frames = [] }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil))
struct OMPEventFilterRuntimeTests {
    @Test func pinnedRuntimeFiltersAtSourceAndKeepsControlWithoutProviderCalls() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        let script = fixture.directory.appendingPathComponent("filter-probe.ts")
        try """
        export default function(pi) {
          pi.registerCommand("knarr-filter-probe", { handler: async (_, ctx) => {
            for (let i = 0; i < 100; i++) {
              await pi.sendMessage({ customType: "knarr-probe", content: "public fixture " + i, display: true }, { triggerTurn: false });
            }
            ctx.ui.notify("knarr filter probe done", "info");
          }});
        }
        """.write(to: script, atomically: true, encoding: .utf8)
        let rpc = OMPRPCSession(), counter = FilterProbeCounter()
        let stream = await rpc.subscribe()
        let observing = Task { for await event in stream { await counter.add(event) } }
        let install = try OMPInstallation(executable: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])))
        let env = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                   "PI_CODING_AGENT_DIR": fixture.directory.appendingPathComponent("agent").path,
                   "PI_CONFIG_DIR": String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1) + fixture.directory.path.dropFirst()]
        do {
            try await rpc.start(.init(installation: install, workingDirectory: fixture.directory,
                arguments: ["--mode", "rpc-ui", "--no-session", "--no-tools", "--no-lsp", "--no-pty", "--no-extensions", "--trusted-extension", script.path,
                            "--no-skills", "--no-rules", "--no-title", "--model", "anthropic/claude-sonnet-4-5"], environment: env))
            for filtered in [false, true] {
                await counter.reset()
                let names: [OMPJSON] = ["message_end", "tool_execution_start", "tool_execution_end"].map(OMPJSON.string)
                let response = try await rpc.request("set_event_filter", fields: ["events": filtered ? .array(names) : .null, "messageUpdates": .string("delta")])
                #expect(response["data"]?["events"] == (filtered ? .array(names) : .null))
                #expect(response["data"]?["messageUpdates"] == .string("delta"))
                _ = try await rpc.request("prompt", fields: ["message": .string("/knarr-filter-probe")])
                for _ in 0..<500 { if await counter.results() > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
                try #require(await counter.results() == 1)
                let frames = await counter.frames
                let starts = frames.filter { $0["type"]?.string == "message_start" }.count
                let ends = frames.filter { $0["type"]?.string == "message_end" }.count
                let notices = frames.filter { $0["type"]?.string == "extension_ui_request" }.count
                #expect(starts == (filtered ? 0 : 100))
                #expect(ends == 100)
                #expect(notices >= 1)
                #expect(try await rpc.request("get_state")["success"]?.bool == true)
                let bytes = try frames.reduce(0) { try $0 + $1.jsonLine().count }
                print("OMP18.7 native filter=\(filtered) starts=\(starts) ends=\(ends) controlNotices=\(notices) frames=\(frames.count) frameJSONBytes=\(bytes) providerCalls=0")
            }
            #expect(await rpc.shutdown().remainingProcessIDs.isEmpty)
            await observing.value
        } catch { _ = await rpc.shutdown(cancel: true); await observing.value; throw error }
    }
}
