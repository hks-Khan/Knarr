import Foundation
import Testing
@testable import KnarrCore

private actor ExposureRPC: StallariRPC {
    let tools: [String]
    init(_ tools: [String]) { self.tools = tools }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) -> OMPJSON {
        .object(["data": .object(["dumpTools": .array(tools.map { .object(["name": .string($0)]) })])])
    }
    func send(_ command: String, fields: [String: OMPJSON]) {}
    func subscribe() -> AsyncStream<OMPEvent> { AsyncStream { $0.finish() } }
    func shutdown(cancel: Bool) -> OMPProcessExit { .init(status: 0, reason: .normal, remainingProcessIDs: []) }
}

@Suite(.serialized)
struct StallariModsTests {
    @Test func launchAllowsOperationalCommandsWithoutEnablingAmbientProviders() {
        let args = StallariTools.arguments(configPath: "/tmp/config", sessionDirectory: "/tmp/sessions")
        for flag in ["--no-lsp", "--no-pty", "--no-title", "--no-ui"] { #expect(!args.contains(flag)) }
        #expect(args.contains("--no-extensions"))
        for name in ["bash", "lsp", "todo", "web_search", "ask"] { #expect(StallariTools.builtInTools.contains(name)) }
        for key in ["xdev:", "modelFallback:", "usageAwareFallback:"] {
            #expect(!StallariTools.discoveryOverlay.contains(key))
        }
    }

    @Test func directCommandsAreExposedAndMissingExecutionFails() async throws {
        let f = try await StallariFixture.make()
        do {
            let args = StallariTools.arguments(configPath: "/tmp/config", sessionDirectory: "/tmp/sessions")
            let index = try #require(args.firstIndex(of: "--tools"))
            #expect(args[index + 1].split(separator: ",").contains("bash"))
            let direct = StallariSession(repository: f.repository,
                rpc: ExposureRPC(Array(Set(StallariTools.exposedNames + ["bash"]))), hird: f.hird)
            #expect(try await direct.checkToolExposure().contains("bash"))
            let missing = StallariSession(repository: f.repository,
                rpc: ExposureRPC(StallariTools.exposedNames.filter { $0 != "bash" }), hird: f.hird)
            await #expect(throws: StallariError.unsafeToolExposure) { try await missing.checkToolExposure() }
            #expect(await f.hird.runs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func launchRestoresBoundedSoftCompaction() {
        for setting in ["enabled: true", "thresholdTokens: 150000", "methodOrder: [soft]", "asyncEnabled: false"] {
            #expect(StallariTools.discoveryOverlay.contains(setting))
        }
    }

    @Test func extraToolsAreAllowedButMutationAndMissingHostToolsFail() async throws {
        let f = try await StallariFixture.make()
        do {
            let extra = StallariSession(repository: f.repository, rpc: ExposureRPC(StallariTools.exposedNames + ["extension_lookup"]), hird: f.hird)
            #expect(try await extra.checkToolExposure().contains("extension_lookup"))
            for name in ["edit", "write", "python", "eval", "notebook"] {
                let unsafe = StallariSession(repository: f.repository, rpc: ExposureRPC(StallariTools.exposedNames + [name]), hird: f.hird)
                await #expect(throws: StallariError.unsafeToolExposure) { try await unsafe.checkToolExposure() }
            }
            let missing = StallariSession(repository: f.repository, rpc: ExposureRPC(StallariTools.exposedNames.filter { $0 != "approve_issue" }), hird: f.hird)
            await #expect(throws: StallariError.unsafeToolExposure) { try await missing.checkToolExposure() }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func loadingErrorsRemainVisibleWhenPreviousModelCannotBeRestored() async throws {
        let f = try await StallariFixture.make()
        await f.rpc.rejectModels()
        let session = StallariSession(repository: f.repository, rpc: f.rpc, hird: f.hird, restartRPC: {
            .object(["generation": .string("next"), "errors": .array([.object(["kind": .string("trusted_extension_startup_failed"), "exitCode": .number(1)])])])
        })
        do {
            let result = try await session.performTool("reload_extensions", arguments: .object([:]))
            let kinds = result["errors"]?.array?.compactMap { $0["kind"]?.string } ?? []
            #expect(kinds.contains("trusted_extension_startup_failed"))
            #expect(kinds.contains("previous_model_restore_failed"))
            #expect(result["model"]?["id"]?.string == "fixture-model")
            #expect(try await f.repository.snapshot().runs.isEmpty)
            _ = await session.shutdown()
            try await f.cleanup()
        } catch { _ = await session.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func ownedExtensionArgumentsAndHirdPolicyAreMerged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-mods-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let extensions = KnarrExtensions(root: root)
        try extensions.prepare()
        try extensions.writeStallari(name: "a.ts", source: "export default function() {}")
        try "export default function() {}".write(to: extensions.directory(.hird).appendingPathComponent("b.js"), atomically: true, encoding: .utf8)
        try "not an extension".write(to: extensions.directory(.stallari).appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
        let stallariArguments = try extensions.arguments(for: .stallari)
        #expect(stallariArguments == ["--trusted-extension", extensions.directory(.stallari).appendingPathComponent("a.ts").resolvingSymlinksInPath().path])
        let policy = root.appendingPathComponent("hird-lsp-policy.ts")
        let hirdArguments = try extensions.arguments(for: .hird, policy: policy)
        #expect(hirdArguments == ["--trusted-extension", policy.path, "--trusted-extension", extensions.directory(.hird).appendingPathComponent("b.js").resolvingSymlinksInPath().path])
    }

    @Test func writingRejectsTraversalAndLinksWithoutTouchingTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-mods-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let extensions = KnarrExtensions(root: root)
        try extensions.prepare()
        for name in ["../bad.ts", "a/b.ts", "a\\b.js", "a..ts", "bad.json", "", "/bad.ts"] {
            #expect(throws: (any Error).self) { try extensions.writeStallari(name: name, source: "unsafe") }
        }
        let target = root.appendingPathComponent("untouched.ts")
        try "original".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: extensions.directory(.stallari).appendingPathComponent("link.ts"), withDestinationURL: target)
        #expect(throws: (any Error).self) { try extensions.writeStallari(name: "link.ts", source: "unsafe") }
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        try extensions.writeStallari(name: "safe.ts", source: "VERSION_ONE")
        try extensions.writeStallari(name: "safe.ts", source: "VERSION_TWO")
        #expect(try String(contentsOf: extensions.directory(.stallari).appendingPathComponent("safe.ts"), encoding: .utf8) == "VERSION_TWO")
    }
}
