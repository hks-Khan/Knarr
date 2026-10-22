import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HirdPolicyFileTests {
    private func dispatch(_ fixture: HirdFixture, mode: HirdRunMode = .change) async throws -> (String, String, [String]) {
        let rpc = ScriptedHirdRPC()
        let run = PersistedRun(hird: .init(id: .init(UUID().uuidString), name: "Hird", role: "change", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now),
            issueID: fixture.run.issueID, projectID: fixture.run.projectID, ompSessionID: nil, ownershipToken: UUID().uuidString, startedAt: .now, mode: mode)
        _ = try await fixture.repository.createRun(run)
        let adapter = OMPHirdAdapter(repository: fixture.repository,
            installation: try OMPInstallation(executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] ??
                URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".runtime/omp/\(OMPInstallation.version)/omp").path)),
            resultRoot: fixture.directory.appendingPathComponent("results"), expectedModel: "ollama/gemma4:12b", makeRPC: { rpc })
        let task = Task { try await adapter.start(run, emit: fixture.sink) }
        do {
            for _ in 0..<500 {
                if await rpc.requests.contains(where: { $0.0 == "prompt" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let prompt = try #require(await rpc.requests.first(where: { $0.0 == "prompt" })?.1["message"]?.string)
            let overlay = await rpc.overlay
            let arguments = await rpc.arguments
            await adapter.cancel(run.id); _ = await task.result
            #expect(await adapter.exits[run.id]?.remainingProcessIDs == [])
            return (overlay, prompt, arguments)
        } catch {
            await adapter.cancel(run.id); _ = await task.result; throw error
        }
    }

    /// Runs the adapter without waiting for a prompt, so a pre-prompt failure surfaces.
    private func directStart(_ fixture: HirdFixture) async throws {
        let rpc = ScriptedHirdRPC()
        let run = PersistedRun(hird: .init(id: .init(UUID().uuidString), name: "Hird", role: "change", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now),
            issueID: fixture.run.issueID, projectID: fixture.run.projectID, ompSessionID: nil, ownershipToken: UUID().uuidString, startedAt: .now, mode: .change)
        _ = try await fixture.repository.createRun(run)
        let executable = ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".runtime/omp/\(OMPInstallation.version)/omp").path
        let adapter = OMPHirdAdapter(repository: fixture.repository,
            installation: try OMPInstallation(executable: URL(fileURLWithPath: executable)),
            resultRoot: fixture.directory.appendingPathComponent("results"), expectedModel: "ollama/gemma4:12b", makeRPC: { rpc })
        do { try await adapter.start(run, emit: fixture.sink) } catch {
            await adapter.cancel(run.id)
            throw error
        }
        await adapter.cancel(run.id)
    }

    @Test func missingFilesCreateCompactionAndEconomyDefaults() async throws {
        let f = try await HirdFixture.make()
        do {
            let (overlay, prompt, _) = try await dispatch(f)
            let directory = f.directory.appendingPathComponent("hird")
            for name in ["overlay.json", "instructions.md", "policy.json"] {
                #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
            }
            let settings = try JSONDecoder().decode(OMPJSON.self, from: Data(overlay.utf8))
            #expect(settings["compaction"]?["enabled"]?.bool == true)
            #expect(settings["compaction"]?["midTurnEnabled"]?.bool == true)
            #expect(settings["compaction"]?["thresholdTokens"]?.integer == 500_000)
            #expect(settings["compaction"]?["thresholdPercent"]?.integer == 60)
            #expect(settings["compaction"]?["keepRecentTokens"]?.integer == 20_000)
            #expect(prompt.contains("PNG"))
            #expect(prompt.contains("crop"))
            #expect(prompt.contains("failure excerpts"))
            #expect(prompt.contains("timeout: 900"))
            #expect(prompt.contains("timeout: 600"))
            #expect(prompt.contains("timeout: 180"))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func userEditsSurviveAndNextDispatchReadsThemAgain() async throws {
        let f = try await HirdFixture.make()
        do {
            _ = try await dispatch(f)
            let directory = f.directory.appendingPathComponent("hird")
            let instructions = directory.appendingPathComponent("instructions.md")
            let overlay = directory.appendingPathComponent("overlay.json")
            let initial = try Data(contentsOf: overlay)
            var settings = try #require(JSONSerialization.jsonObject(with: initial) as? [String: Any])
            var compaction = try #require(settings["compaction"] as? [String: Any])
            compaction["thresholdTokens"] = 150_000; settings["compaction"] = compaction
            let edited = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
            try edited.write(to: overlay)
            try "First user policy revision.\n".write(to: instructions, atomically: true, encoding: .utf8)
            let (firstOverlay, first, _) = try await dispatch(f)
            #expect(first.contains("First user policy revision."))
            #expect(try JSONDecoder().decode(OMPJSON.self, from: Data(firstOverlay.utf8))["compaction"]?["thresholdTokens"]?.integer == 150_000)
            #expect(try Data(contentsOf: overlay) == edited)
            try "Second user policy revision.\n".write(to: instructions, atomically: true, encoding: .utf8)
            let (_, second, _) = try await dispatch(f)
            #expect(second.contains("Second user policy revision."))
            #expect(!second.contains("First user policy revision."))
            #expect(try String(contentsOf: instructions, encoding: .utf8) == "Second user policy revision.\n")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test(arguments: ["overlay.json", "policy.json"])
    func invalidFileRestoresOnlyItAndRecordsOneWarning(name: String) async throws {
        let f = try await HirdFixture.make()
        do {
            _ = try await dispatch(f)
            let directory = f.directory.appendingPathComponent("hird")
            let file = directory.appendingPathComponent(name)
            let original = try Data(contentsOf: file)
            let otherFiles = try ["overlay.json", "instructions.md", "policy.json"].filter { $0 != name }.map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) }
            let bad = Data("{\"unknownPolicyKey\":true}".utf8)
            try bad.write(to: file)
            _ = try await dispatch(f)
            #expect(try Data(contentsOf: file) == original)
            for (other, contents) in otherFiles { #expect(try Data(contentsOf: directory.appendingPathComponent(other)) == contents) }
            let snapshot = try await f.repository.snapshot()
            let warnings = snapshot.issues.flatMap(\.events).filter { $0.text.contains("[hird_policy]") && $0.text.contains(name) }
            #expect(warnings.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    /// A broken user rule file must stop a change run rather than quietly reverting to the
    /// packaged text. The JSON policies keep their restore-and-warn behavior.
    @Test func brokenInstructionsStopTheDispatchWithoutRewritingTheFile() async throws {
        let f = try await HirdFixture.make()
        do {
            _ = try await dispatch(f)
            let file = f.directory.appendingPathComponent("hird/instructions.md")
            let bad = Data([0xff, 0xfe])
            try bad.write(to: file)
            await #expect(throws: HirdError.instructions) { _ = try await directStart(f) }
            #expect(try Data(contentsOf: file) == bad)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test(arguments: ["syntax", "nestedKey", "wrongType", "outOfRange"])
    func invalidOverlayValuesCannotReachOMP(kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-hird-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = HirdPolicyFiles(directory: root)
        _ = try files.load()
        let file = root.appendingPathComponent("overlay.json"), original = try Data(contentsOf: file)
        var settings = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var compaction = try #require(settings["compaction"] as? [String: Any])
        switch kind {
        case "nestedKey": compaction["thresholdToken"] = compaction.removeValue(forKey: "thresholdTokens")
        case "wrongType": compaction["thresholdTokens"] = "200000"
        case "outOfRange": compaction["thresholdPercent"] = 101
        default: break
        }
        settings["compaction"] = compaction
        try (kind == "syntax" ? Data("{".utf8) : JSONSerialization.data(withJSONObject: settings)).write(to: file)
        let restored = try files.load()
        #expect(restored.warnings.count == 1)
        #expect(restored.warnings.first?.contains("overlay.json") == true)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func linkedPolicyNeverReadsOrOverwritesItsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-hird-policy-link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("hird"), files = HirdPolicyFiles(directory: directory)
        _ = try files.load()
        let target = root.appendingPathComponent("outside-policy.txt")
        let contents = "Do not follow this public fixture symlink.\n"
        try contents.write(to: target, atomically: true, encoding: .utf8)
        let file = directory.appendingPathComponent("instructions.md")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: (any Error).self) { _ = try files.load() }
        #expect(try String(contentsOf: target, encoding: .utf8) == contents)
        // The link itself is left untouched; the target content is never read into the policy.
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeSymbolicLink)
    }
}
