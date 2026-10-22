import Foundation
import Testing
@testable import KnarrCore

private actor CompactionProbeRPC: HirdRPC {
    let rpc = OMPRPCSession()
    let result: URL
    let model: String
    init(result: URL, model: String) { self.result = result; self.model = model }
    func start(_ configuration: OMPLaunchConfiguration) async throws {
        var configuration = configuration
        configuration.arguments += ["--model", model]
        let backgroundDefaults = result.deletingLastPathComponent().appendingPathComponent("background-enabled.json")
        try #"{"bash":{"autoBackground":{"enabled":true}}}"#.write(to: backgroundDefaults, atomically: true, encoding: .utf8)
        let overlayIndex = try #require(configuration.arguments.firstIndex(of: "--config"))
        configuration.arguments.insert(contentsOf: ["--config", backgroundDefaults.path], at: overlayIndex)
        let index = try #require(configuration.arguments.firstIndex(of: "--trusted-extension"))
        let extensionURL = URL(fileURLWithPath: configuration.arguments[index + 1])
        let native = try String(contentsOf: extensionURL, encoding: .utf8)
            .replacingOccurrences(of: "export default function(pi)", with: "function deadline(pi)")
        try (native + "\n" + Self.probe).write(to: extensionURL, atomically: true, encoding: .utf8)
        configuration.environment["KNARR_COMPACTION_RESULT"] = result.path
        try await rpc.start(configuration)
    }
    func subscribe() async -> AsyncStream<OMPEvent> { await rpc.subscribe() }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON {
        try await rpc.request(command, fields: fields, timeout: timeout)
    }
    func send(_ command: String, fields: [String: OMPJSON]) async throws { try await rpc.send(command, fields: fields) }
    func shutdown(cancel: Bool) async -> OMPProcessExit { await rpc.shutdown(cancel: cancel) }

    static let probe = """
    export default function(pi) {
      deadline(pi);
      let providerCalls = 0;
      pi.on("before_provider_request", () => { providerCalls++; throw new Error("This probe must never call a model"); });
      pi.on("input", async (event, ctx) => {
        const fs = await import("node:fs");
        const ids = ["compaction.enabled", "compaction.midTurnEnabled", "compaction.thresholdTokens", "compaction.thresholdPercent", "compaction.keepRecentTokens", "lsp.enabled", "bash.autoBackground.enabled"];
        const values = Object.fromEntries(ids.map(id => [id, lookup(id).get(pi.pi.settings)]));
        fs.writeFileSync(process.env.KNARR_COMPACTION_RESULT, JSON.stringify({ values, contextWindow: ctx.model.contextWindow, providerCalls, prompt: event.text, lspTimeoutSeconds: KNARR_HIRD_POLICY.lspTimeoutSeconds }));
        return { handled: true };
      });
    }
    """
}

private final class CompactionProbeFactory: @unchecked Sendable {
    let probes: [CompactionProbeRPC]
    private let lock = NSLock()
    private var index = 0
    init(probes: [CompactionProbeRPC]) { self.probes = probes }
    func next() -> any HirdRPC {
        lock.lock()
        defer { lock.unlock() }
        defer { index += 1 }
        return probes[index]
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil))
struct HirdCompactionRuntimeTests {
    @Test(arguments: [HirdRunMode.change, .inspect])
    func fileOverlayAppliesNativeThresholdForLargeAndSmallModelsWithoutProviderCalls(mode: HirdRunMode) async throws {
        let f = try await HirdFixture.make()
        do {
            let policyDirectory = f.directory.appendingPathComponent("hird")
            let extensions = KnarrExtensions(root: f.directory.appendingPathComponent("owned"))
            try extensions.prepare()
            let ownedMarker = f.directory.appendingPathComponent("owned-extension-loaded")
            let markerPath = String(decoding: try JSONEncoder().encode(ownedMarker.path), as: UTF8.self)
            try """
            import fs from "node:fs";
            export default function(pi) {
              pi.on("session_start", () => fs.writeFileSync(\(markerPath), "loaded"));
            }
            """.write(to: extensions.directory(.hird).appendingPathComponent("probe.ts"), atomically: true, encoding: .utf8)
            let cases = [("openai/gpt-4.1", 500_000, 60, false), ("openai/gpt-4o", 500_000, 60, false), ("openai/gpt-4.1", 150_000, 50, true)]
            let probes = cases.map { CompactionProbeRPC(result: f.directory.appendingPathComponent(UUID().uuidString + ".json"), model: $0.0) }
            let factory = CompactionProbeFactory(probes: probes)
            let adapter = OMPHirdAdapter(repository: f.repository,
                installation: try OMPInstallation(executable: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"]))),
                resultRoot: f.directory.appendingPathComponent("results"), expectedModel: "unused",
                environment: ["HOME": f.directory.appendingPathComponent("home").path,
                    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                    "PI_CODING_AGENT_DIR": f.directory.appendingPathComponent("agent").path,
                    "XDG_CONFIG_HOME": f.directory.appendingPathComponent("config").path], policyDirectory: policyDirectory,
                makeRPC: { factory.next() }, extensionRoot: extensions.root)
            // One long-lived production adapter must observe edits between dispatches.
            for (index, (model, cap, percent, edited)) in cases.enumerated() {
                if edited {
                    let file = policyDirectory.appendingPathComponent("overlay.json")
                    var settings = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                    var compaction = try #require(settings["compaction"] as? [String: Any])
                    compaction["thresholdTokens"] = cap; compaction["thresholdPercent"] = percent; settings["compaction"] = compaction
                    try JSONSerialization.data(withJSONObject: settings).write(to: file)
                    let policyFile = policyDirectory.appendingPathComponent("policy.json")
                    var policy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: policyFile)) as? [String: Any])
                    policy["lspTimeoutSeconds"] = 2
                    if mode == .inspect {
                        policy["inspectTools"] = ["read", "grep", "bash", "todo", "ask"]
                        policy["inspectArguments"] = ["--no-extensions", "--no-rules"]
                    }
                    try JSONSerialization.data(withJSONObject: policy).write(to: policyFile)
                    try "Runtime-only Hird instruction revision.\n".write(to: policyDirectory.appendingPathComponent("instructions.md"), atomically: true, encoding: .utf8)
                }
                let run = PersistedRun(hird: .init(id: .init(UUID().uuidString), name: "Hird", role: "change", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now),
                    issueID: f.run.issueID, projectID: f.run.projectID, ompSessionID: nil, ownershipToken: UUID().uuidString, startedAt: .now, mode: mode, requestedModel: model)
                _ = try await f.repository.createRun(run)
                let rpc = probes[index], result = rpc.result
                let task = Task { try await adapter.start(run, emit: f.sink) }
                do {
                    for _ in 0..<1500 {
                        if FileManager.default.fileExists(atPath: result.path) { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let value = try JSONDecoder().decode(OMPJSON.self, from: Data(contentsOf: result))
                    let window = try #require(value["contextWindow"]?.integer)
                    let threshold = try #require(value["values"]?["compaction.thresholdTokens"]?.integer)
                    #expect(threshold == min(cap, window * percent / 100))
                    #expect(value["values"]?["compaction.thresholdPercent"]?.integer == percent)
                    #expect(value["lspTimeoutSeconds"]?.integer == (edited ? 2 : 10))
                    if edited {
                        let prompt = try #require(value["prompt"]?.string)
                        #expect(prompt.contains("Runtime-only Hird instruction revision."))
                        #expect(!prompt.contains("You are Hird, the coding worker"))
                        #expect(!prompt.contains("Context economy rules:"))
                        #expect(prompt.contains("Do not read credentials"))
                    }
                    #expect(value["values"]?["compaction.enabled"]?.bool == true)
                    #expect(value["values"]?["compaction.midTurnEnabled"]?.bool == true)
                    #expect(value["values"]?["compaction.keepRecentTokens"]?.integer == 20_000)
                    #expect(value["values"]?["lsp.enabled"]?.bool == (mode == .change))
                    let autoBackground = try #require(value["values"]?["bash.autoBackground.enabled"]?.bool as Bool?)
                    #expect(autoBackground == false)
                    #expect(value["providerCalls"]?.integer == 0)
                    #expect(FileManager.default.fileExists(atPath: ownedMarker.path) == (mode == .change))
                    let state = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))
                    #expect(state["data"]?["autoCompactionEnabled"]?.bool == true)
                    if mode == .inspect {
                        let tools = try #require(state["data"]?["dumpTools"]?.array?.compactMap { $0["name"]?.string })
                        #expect(tools.contains("glob") == !edited)
                    }
                    await adapter.cancel(run.id); _ = await task.result
                    let exit = try #require(await adapter.exits[run.id])
                    #expect(exit.remainingProcessIDs == [])
                    print("Hird compaction mode=\(mode.rawValue) model=\(model) context=\(window) threshold=\(threshold) recent=20000 auto_background=\(autoBackground) provider_calls=0 owned_remaining=\(exit.remainingProcessIDs.count)")
                } catch { await adapter.cancel(run.id); _ = await task.result; throw error }
            }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
