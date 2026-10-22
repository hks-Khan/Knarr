import Foundation
import Darwin
import Testing
@testable import KnarrCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil))
struct HiveOMPWireTests {
    private func stop(_ server: Process, _ stopped: DispatchSemaphore) {
        if server.isRunning { server.terminate() }
        if stopped.wait(timeout: .now() + 3) == .timedOut {
            kill(server.processIdentifier, SIGKILL)
            #expect(stopped.wait(timeout: .now() + 3) == .success)
        }
        #expect(!server.isRunning)
    }
    @Test func realOMPHighFragmentedToolDeltasReasoningContinuationAndStreamEnd() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent(".build/hive-recovery/wire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = root.appendingPathComponent("wire.json")
        let portFile = root.appendingPathComponent("port")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [project.appendingPathComponent("Tests/Fixtures/Hive/server.py").path, records.path, portFile.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        server.standardInput = FileHandle.nullDevice
        let stopped = DispatchSemaphore(value: 0)
        server.terminationHandler = { _ in stopped.signal() }
        try server.run()
        defer { stop(server, stopped) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: portFile.path), server.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try #require(Int(try String(contentsOf: portFile, encoding: .utf8)))
        let runtime = HiveProviderRuntime(baseURL: try #require(URL(string: "http://127.0.0.1:\(port)/api/v3")))
        let installation = try OMPInstallation(executable: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])))
        await #expect(throws: HiveProbeError.credentialRequired) { try await HiveOMPProbe.run(installation: installation, runtime: runtime, root: root) }
        #expect(!FileManager.default.fileExists(atPath: records.path))
        try runtime.replaceCredential("knarr-hive-wire-synthetic-only")
        let receipt = try await HiveOMPProbe.run(installation: installation, runtime: runtime, root: root)
        #expect(receipt.requestedModel == "hive/deepseek-ai/deepseek-v4.1-flash-1017")
        #expect(receipt.observedModel == receipt.requestedModel)
        #expect(receipt.thinkingLevel == "high")
        #expect(receipt.reasoningObserved)
        #expect(receipt.toolResultRoundTrip && receipt.streamSettled)
        #expect(receipt.exitCode == 0 && receipt.remainingProcessIDs.isEmpty)
        let stallariRoot = root.appendingPathComponent("stallari")
        try FileManager.default.createDirectory(at: stallariRoot, withIntermediateDirectories: true)
        let stallari = try StallariTools.configuration(installation: installation, workingDirectory: stallariRoot,
            configurationFile: stallariRoot.appendingPathComponent("config.yml"), sessionDirectory: stallariRoot.appendingPathComponent("sessions"),
            environment: HiveOMPProbe.isolatedEnvironment(in: stallariRoot), loadingExtensions: false, hive: runtime)
        let catalogRPC = OMPRPCSession()
        do {
            try await catalogRPC.start(stallari)
            let catalog = try await catalogRPC.request("get_available_models")
            let hive = try #require(catalog["data"]?["models"]?.array?.first { $0["provider"]?.string == "hive" })
            #expect(hive["api"]?.string == "openai-completions")
            #expect(hive["maxTokens"]?.integer == 393_216)
            #expect(!String(decoding: try catalog.jsonLine(), as: UTF8.self).contains("knarr-hive-wire-synthetic-only"))
            let exit = await catalogRPC.shutdown()
            #expect(exit.status == 0 && exit.remainingProcessIDs.isEmpty)
        } catch { _ = await catalogRPC.shutdown(cancel: true); throw error }
        let stallariReceipt = try await HiveOMPProbe.run(configuration: stallari)
        #expect(stallariReceipt.observedModel == receipt.requestedModel)
        #expect(stallariReceipt.thinkingLevel == "high" && stallariReceipt.toolResultRoundTrip && stallariReceipt.streamSettled)
        #expect(stallariReceipt.exitCode == 0 && stallariReceipt.remainingProcessIDs.isEmpty)
        var hirds: [OMPJSON] = []
        for mode in [HirdRunMode.change, .inspect] {
            hirds.append(try await verifyHird(mode: mode, runtime: runtime, installation: installation, records: records))
        }
        let values = try JSONDecoder().decode([OMPJSON].self, from: Data(contentsOf: records))
        #expect(values.count >= 6)
        for value in values {
            #expect(value["path"]?.string == "/api/v3/chat/completions")
            #expect(value["model"]?.string == "deepseek-ai/deepseek-v4.1-flash-1017")
            #expect(value["reasoning"]?.string == "high")
            #expect(value["stream"]?.bool == true)
            #expect(value["authorizationMatched"]?.bool == true)
            #expect(value["outputBudget"]?.integer == 393_216)
        }
        for index in [0, 2] {
            #expect(values[index]["toolContinuation"]?.bool == false)
            #expect(values[index + 1]["toolContinuation"]?.bool == true)
            #expect(values[index + 1]["reasoningRetained"]?.bool == true)
        }
        let encoded = try JSONEncoder().encode(receipt)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("knarr-hive-wire-synthetic-only"))
        if let output = ProcessInfo.processInfo.environment["KNARR_HIVE_WIRE_EVIDENCE"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoded.write(to: directory.appendingPathComponent("standalone-receipt.json"), options: .atomic)
            try JSONEncoder().encode(stallariReceipt).write(to: directory.appendingPathComponent("stallari-receipt.json"), options: .atomic)
            try OMPJSON.object(["fixture": .bool(true), "liveHive": .bool(false), "wireRequests": .array(values), "hirds": .array(hirds)]).jsonLine()
                .write(to: directory.appendingPathComponent("wire-evidence.json"), options: .atomic)
        }
        print("HIVE_WIRE_FIXTURE OMP=18.7.0 requested=\(receipt.requestedModel) observed=\(receipt.observedModel) reasoning_effort=high tool_continuation=true reasoning_retained=true stream_settled=true exit=\(receipt.exitCode) remaining=\(receipt.remainingProcessIDs.count) live_Hive=false")
    }

    private func verifyHird(mode: HirdRunMode, runtime: HiveProviderRuntime, installation: OMPInstallation, records: URL) async throws -> OMPJSON {
        let fixture = try await HirdFixture.make()
        let rpc = OMPRPCSession()
        let run = PersistedRun(hird: .init(id: .init(UUID().uuidString), name: "Hive wire fixture", role: "Return only HIVE_HIRD_FIXTURE_OK. This is a synthetic connection check; do not use tools or change files.", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now),
            issueID: fixture.run.issueID, projectID: fixture.run.projectID, ompSessionID: nil, ownershipToken: UUID().uuidString, startedAt: .now, mode: mode,
            requestedModel: HiveProviderRuntime.modelIdentifier, requestedThinking: "high")
        _ = try await fixture.repository.createRun(run)
        // Keep OMP's HOME-relative config/cache paths inside the fixture cleanup root.
        let adapter = OMPHirdAdapter(repository: fixture.repository, installation: installation,
            resultRoot: fixture.directory.appendingPathComponent("results"), expectedModel: "openai-codex/gpt-6.1-sol",
            environment: HiveOMPProbe.isolatedEnvironment(in: fixture.directory.appendingPathComponent("omp", isDirectory: true)), makeRPC: { rpc }, hive: runtime)
        let startingCount = try JSONDecoder().decode([OMPJSON].self, from: Data(contentsOf: records)).count
        let task = Task { try await adapter.start(run, emit: fixture.sink) }
        do {
            let deadline = ContinuousClock.now + .seconds(25)
            while ContinuousClock.now < deadline {
                if let data = try? Data(contentsOf: records),
                   let values = try? JSONDecoder().decode([OMPJSON].self, from: data), values.count > startingCount { break }
                try await Task.sleep(for: .milliseconds(40))
            }
            // Connection fixture does not approve a code task or bypass final-check policy.
            await adapter.cancel(run.id)
            _ = await task.result
            let saved = try #require(try await fixture.repository.snapshot().runs.first { $0.id == run.id })
            #expect(saved.requestedModel == HiveProviderRuntime.modelIdentifier)
            #expect(saved.observedModel == saved.requestedModel)
            #expect(saved.observedThinking == "high")
            let wire = try JSONDecoder().decode([OMPJSON].self, from: Data(contentsOf: records))
            #expect(wire.count > startingCount)
            #expect(wire[startingCount]["reasoning"]?.string == "high")
            let exit = await rpc.shutdown()
            #expect(exit.remainingProcessIDs.isEmpty)
            let requested = saved.requestedModel ?? "missing", observed = saved.observedModel ?? "missing"
            let high = saved.observedThinking == "high"
            print("HIVE_HIRD_FIXTURE mode=\(mode.rawValue) requested=\(requested) observed=\(observed) high=\(high) remaining=\(exit.remainingProcessIDs.count) live_Hive=false coding_acceptance=false")
            try await fixture.cleanup()
            return .object(["mode": .string(mode.rawValue), "requestedModel": .string(requested), "observedModel": .string(observed),
                            "requestedThinking": .string("high"), "observedThinking": .string(saved.observedThinking ?? "missing"),
                            "exitCode": .number(Double(exit.status)), "remainingProcessIDs": .array(exit.remainingProcessIDs.map { .number(Double($0)) }),
                            "codingAcceptance": .bool(false)])
        } catch {
            await adapter.cancel(run.id); _ = await task.result
            try await fixture.cleanup()
            throw error
        }
    }
}
