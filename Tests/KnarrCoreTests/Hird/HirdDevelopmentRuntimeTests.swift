import Foundation
import Testing
@testable import KnarrCore

/// Hold startup before any model request; inspect only public runtime metadata.
actor DevelopmentStartupRPC: HirdRPC {
    let rpc = OMPRPCSession()
    var tools: [String]?
    var release: CheckedContinuation<Void, Never>?
    func start(_ configuration: OMPLaunchConfiguration) async throws {
        try await rpc.start(configuration)
        let state = try await rpc.request("get_state")
        tools = state["data"]?["dumpTools"]?.array?.compactMap { $0["name"]?.string } ?? []
        await withCheckedContinuation { release = $0 }
    }
    func subscribe() async -> AsyncStream<OMPEvent> { await rpc.subscribe() }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON { try await rpc.request(command, fields: fields, timeout: timeout) }
    func send(_ command: String, fields: [String: OMPJSON]) async throws { try await rpc.send(command, fields: fields) }
    func shutdown(cancel: Bool) async -> OMPProcessExit {
        release?.resume(); release = nil
        return await rpc.shutdown(cancel: cancel)
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil))
struct HirdDevelopmentRuntimeTests {
    @Test(arguments: [HirdRunMode.change, .inspect])
    func nativeStartupPreservesModeCapabilitiesWithoutModelUsage(mode: HirdRunMode) async throws {
        let f = try await HirdFixture.make(preserve: true), rpc = DevelopmentStartupRPC()
        var run = f.run; run.mode = mode
        _ = try await f.repository.createRun(run)
        let environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": f.directory.path,
                           "PI_CODING_AGENT_DIR": f.directory.appendingPathComponent("agent").path]
        let adapter = OMPHirdAdapter(repository: f.repository,
            installation: try OMPInstallation(executable: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"]))),
            resultRoot: f.directory.appendingPathComponent("development"), expectedModel: "unused", environment: environment, makeRPC: { rpc })
        let task = Task { try await adapter.start(run, emit: f.sink) }
        do {
            for _ in 0..<500 { if await rpc.tools != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            let tools = try #require(await rpc.tools)
            #expect(tools.contains("ask"), "rpc --no-ui removes ask; the host question receiver is unreachable")
            #expect(tools.contains("lsp") == (mode == .change))
            if mode == .inspect { #expect(Set(tools).isSubset(of: Set(HirdInspectionPolicy.tools))) }
            await adapter.cancel(f.run.id); _ = await task.result
            #expect(await adapter.exits[f.run.id]?.remainingProcessIDs == [])
            try await f.cleanup()
        } catch {
            await adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup(); throw error
        }
    }
}
