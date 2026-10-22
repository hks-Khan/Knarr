import Foundation
import Darwin
import CryptoKit
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HirdWorkspacePreservationTests {
    struct Fixture {
        let root: URL
        let project: URL
        let base: String
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("hird-capture-" + UUID().uuidString)
            let project = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            for args in [["init", "-q"], ["config", "user.name", "Synthetic"], ["config", "user.email", "synthetic@example.invalid"]] {
                _ = try await HirdWorkspace.git(args, at: project)
            }
            for path in ["source.txt", "deleted.txt", ".build-tracked/value.txt"] {
                let target = project.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("base\n".utf8).write(to: target)
            }
            _ = try await HirdWorkspace.git(["add", "."], at: project)
            _ = try await HirdWorkspace.git(["commit", "-qm", "base"], at: project)
            return .init(root: root, project: project, base: try await HirdWorkspace.git(["rev-parse", "HEAD"], at: project))
        }
        var workspace: RunWorkspace { .init(worktreePath: project.path, branch: nil, ompSessionPath: nil) }
        var resultRoot: URL { root.appendingPathComponent("result") }
        func write(_ path: String, _ data: Data) throws {
            let target = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
        func large(_ path: String) throws {
            let target = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let output = try FileHandle(forWritingTo: target); defer { try? output.close() }
            var state: UInt64 = 0x123456789abcdef
            for _ in 0..<18 {
                var chunk = Data(count: 1_048_576)
                chunk.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                    for index in bytes.indices {
                        state ^= state << 13; state ^= state >> 7; state ^= state << 17
                        bytes[index] = UInt8(truncatingIfNeeded: state)
                    }
                }
                try output.write(contentsOf: chunk)
            }
        }
    }

    @Test func oversizedBinaryCapturePreservesOriginalIndex() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let index = try Data(contentsOf: f.project.appendingPathComponent(".git/index"))
        try f.large("asset.bin")
        let (result, _) = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "large")
        let size = try FileManager.default.attributesOfItem(atPath: try #require(result.diffPath))[.size] as? NSNumber
        #expect(try #require(size).intValue > 16_777_216)
        #expect(try Data(contentsOf: f.project.appendingPathComponent(".git/index")) == index)
    }

    @Test func largeBinaryTrackedCacheDeletionAndEvidenceRoundTrip() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let originalIndex = try Data(contentsOf: f.project.appendingPathComponent(".git/index"))
        try f.large("asset.bin")
        try f.large("docs/evidence/large.bin")
        try f.write("outputs/check/result.txt", Data("evidence".utf8))
        try f.write(".build-generated/cache", Data("cache".utf8))
        try f.write(".build-tracked/value.txt", Data("tracked".utf8))
        try f.write("source.txt", Data("changed".utf8))
        try FileManager.default.removeItem(at: f.project.appendingPathComponent("deleted.txt"))
        let (result, snapshot) = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "synthetic")
        #expect(try Data(contentsOf: f.project.appendingPathComponent(".git/index")) == originalIndex)
        #expect(!snapshot.isEmpty)
        let manifest = try HirdWorkspace.loadManifest(for: result)
        #expect(try HirdWorkspace.fingerprint(URL(fileURLWithPath: try #require(result.diffPath))).byteCount > 16_777_216)
        #expect(manifest.artifacts.filter { $0.role == .evidence }.count == 2)
        #expect(manifest.artifacts.contains { $0.sourcePath == "docs/evidence/large.bin" && $0.byteCount > 16_777_216 })
        for artifact in manifest.artifacts { try HirdWorkspace.verifyArtifact(artifact, manifestURL: URL(fileURLWithPath: try #require(result.artifactManifestPath))) }
        let restored = f.root.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
        _ = try await HirdWorkspace.git(["clone", "-q", f.project.path, restored.path], at: f.root)
        try await HirdWorkspace.restore(result: result, at: restored)
        #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("asset.bin").path))
        #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent("deleted.txt").path))
        #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent(".build-generated/cache").path))
        #expect(try Data(contentsOf: restored.appendingPathComponent(".build-tracked/value.txt")) == Data("tracked".utf8))
        #expect(try HirdWorkspace.fingerprint(restored.appendingPathComponent("docs/evidence/large.bin")) == HirdWorkspace.fingerprint(f.project.appendingPathComponent("docs/evidence/large.bin")))
    }

    @Test func quotaFailurePreservesPriorPatchAndSnapshot() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("source.txt", Data("first".utf8))
        let (prior, snapshot) = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "first")
        let patch = try Data(contentsOf: URL(fileURLWithPath: try #require(prior.diffPath)))
        try f.large("docs/evidence/too-large.bin")
        var policy = try HirdCapturePolicy.bundled()
        policy.maximumArtifactBytes = 1024
        do {
            _ = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "fail", policy: policy)
            Issue.record("artifact quota did not fail")
        } catch let HirdError.workspaceFailure(diagnostic) {
            #expect(diagnostic.outputLimitExceeded)
            #expect(diagnostic.stage == "capture")
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(prior.diffPath))) == patch)
        #expect(!snapshot.isEmpty)
        #expect(FileManager.default.fileExists(atPath: try #require(prior.artifactManifestPath)))
    }

    @Test func secretExclusionAndEvidenceSymlinkAndSpecialFilesAreSkippedWithFixedKind() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write(".env", Data("synthetic-secret".utf8))
        try f.write("docs/evidence/.env", Data("synthetic-secret".utf8))
        try f.write("docs/evidence/result.txt", Data("evidence".utf8))
        let outside = f.root.appendingPathComponent("outside-secret")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("synthetic-secret".utf8).write(to: outside.appendingPathComponent("token.txt"))
        try FileManager.default.createSymbolicLink(at: f.project.appendingPathComponent("docs/evidence/link"), withDestinationURL: outside)
        let fifo = f.project.appendingPathComponent("docs/evidence/pipe")
        #expect(Darwin.mkfifo(fifo.path, 0o644) == 0)
        let (result, snapshot) = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "symlink skipped")
        let manifest = try HirdWorkspace.loadManifest(for: result)
        #expect(manifest.artifacts.allSatisfy { !$0.sourcePath.contains(".env") })
        #expect(manifest.artifacts.contains { $0.role == .evidence && $0.sourcePath == "docs/evidence/result.txt" })
        #expect(manifest.artifacts.allSatisfy { $0.sourcePath != "docs/evidence/link" && $0.sourcePath != "docs/evidence/pipe" })
        #expect(snapshot.files["docs/evidence/link"] == nil && snapshot.files["docs/evidence/pipe"] == nil)
        let diagnostics = f.resultRoot.appendingPathComponent("workspace-diagnostics")
        let names = try FileManager.default.contentsOfDirectory(atPath: diagnostics.path)
        #expect(names.contains("evidence-skipped-symlink.json"))
        #expect(names.contains("evidence-skipped-fifo.json"))
        for name in names.filter({ $0.hasPrefix("evidence-skipped-") }) {
            let text = try String(contentsOf: diagnostics.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains(outside.path) && !text.contains("token.txt") && !text.contains("pipe"))
            let record = try JSONDecoder().decode(HirdWorkspaceDiagnostic.self, from: Data(contentsOf: diagnostics.appendingPathComponent(name)))
            #expect(["symlink", "fifo"].contains(record.failureKind))
            #expect(record.commandKind == "evidence_selection")
        }
    }

    @Test func sourceStabilityRetriesWhenUntrackedFileAppearsDuringCapture() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("source.txt", Data("changed".utf8))
        try writeSlowEvidence(f)
        let task = Task { try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "retry untracked") }
        try await waitForEvidenceCopy(f)
        try f.write("late.txt", Data("late\n".utf8))
        let (result, snapshot) = try await task.value
        #expect(snapshot.files["late.txt"] != nil)
        #expect(try HirdWorkspace.loadManifest(for: result).artifacts.allSatisfy { $0.role != .evidence || $0.sourcePath.hasPrefix("docs/evidence/slow-") })
    }

    @Test func sourceStabilityRetriesWhenEvidenceAppearsDuringCapture() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("source.txt", Data("changed".utf8))
        try writeSlowEvidence(f)
        let task = Task { try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "retry evidence") }
        try await waitForEvidenceCopy(f)
        try f.write("docs/evidence/late.log", Data("late evidence".utf8))
        let (result, snapshot) = try await task.value
        #expect(snapshot.files["docs/evidence/late.log"] != nil)
        #expect(try HirdWorkspace.loadManifest(for: result).artifacts.contains { $0.role == .evidence && $0.sourcePath == "docs/evidence/late.log" })
    }

    @Test func exhaustedSourceStabilityRetryDiagnosesFixedKindWithoutRawPath() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("source.txt", Data("changed".utf8))
        try writeSlowEvidence(f)
        var policy = try HirdCapturePolicy.bundled()
        #expect(policy.sourceStabilityAttempts >= 2)
        policy.sourceStabilityAttempts = 1
        policy.sourceStabilityRetryDelayMilliseconds = 0
        let task = Task {
            try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "unstable", policy: policy)
        }
        try await waitForEvidenceCopy(f)
        try f.write("late.txt", Data("late\n".utf8))
        do {
            _ = try await task.value
            Issue.record("source stability retry limit did not fail")
        } catch let HirdError.workspaceFailure(diagnostic) {
            #expect(diagnostic.stage == "capture")
            #expect(diagnostic.commandKind == "source_stability")
            #expect(diagnostic.failureKind == "source_changed")
            let encoded = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
            #expect(!encoded.contains("late.txt"))
        }
    }

    @Test func sourceStabilityRetryCoversHeadChangeDuringCapture() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("source.txt", Data("changed".utf8))
        try writeSlowEvidence(f)
        var policy = try HirdCapturePolicy.bundled()
        policy.sourceStabilityAttempts = 1
        policy.sourceStabilityRetryDelayMilliseconds = 0
        let task = Task {
            try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "head moved", policy: policy)
        }
        try await waitForEvidenceCopy(f)
        try f.write("head-change.txt", Data("head\n".utf8))
        _ = try await HirdWorkspace.git(["add", "head-change.txt"], at: f.project)
        _ = try await HirdWorkspace.git(["commit", "-qm", "moved during capture"], at: f.project)
        do {
            _ = try await task.value
            Issue.record("HEAD change during capture did not fail the single attempt")
        } catch let HirdError.workspaceFailure(diagnostic) {
            #expect(diagnostic.commandKind == "source_stability")
            #expect(diagnostic.failureKind == "source_changed")
        }
    }

    /// The reported failure: the temporary index is built, then a tracked file changes.
    /// `git diff --quiet` exits 1 for that attempt. With retries disabled (the previous
    /// source_stability behavior) the very same reproduction fails; the default policy
    /// re-stages the file and the saved patch/snapshot carry the final content.
    @Test func trackedFileChangeDuringCaptureRetriesAndKeepsFinalContent() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("source.txt", Data("first\n".utf8))
        try writeSlowEvidence(f)

        var singleAttempt = try HirdCapturePolicy.bundled()
        singleAttempt.sourceStabilityAttempts = 1
        singleAttempt.sourceStabilityRetryDelayMilliseconds = 0
        let control = Task {
            try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base,
                verifications: [], summary: "single attempt", policy: singleAttempt)
        }
        try await waitForEvidenceCopy(f)
        try f.write("source.txt", Data("second\n".utf8))
        do {
            _ = try await control.value
            Issue.record("a tracked change during the single attempt must fail source_stability")
        } catch let HirdError.workspaceFailure(diagnostic) {
            #expect(diagnostic.stage == "capture")
            #expect(diagnostic.commandKind == "source_stability")
            #expect(diagnostic.failureKind == "source_changed")
        }

        // Same reproduction, now with the bundled retry policy: change the tracked file
        // again after the retried attempt has staged the index.
        try f.write("source.txt", Data("first\n".utf8))
        let controlRoot = f.root.appendingPathComponent("retry")
        try HirdSecureFile.createDirectory(controlRoot)
        let retried = Task {
            try await HirdWorkspace.capture(workspace: f.workspace, root: controlRoot, base: f.base,
                verifications: [], summary: "retried")
        }
        try await waitForEvidenceCopy(f, root: controlRoot)
        try f.write("source.txt", Data("second\n".utf8))
        let (result, snapshot) = try await retried.value
        let patch = try String(contentsOf: URL(fileURLWithPath: try #require(result.diffPath)), encoding: .utf8)
        #expect(patch.contains("+second"))
        #expect(!patch.contains("+first"))
        #expect(snapshot.files["source.txt"] != nil)
        let manifest = try HirdWorkspace.loadManifest(for: result)
        let artifact = try #require(manifest.artifacts.first { $0.role == .patch })
        let saved = try HirdSecureFile.transfer(URL(fileURLWithPath: try #require(result.diffPath)), limit: .max)
        #expect(saved.sha256 == artifact.sha256 && saved.byteCount == artifact.byteCount)
    }

    @Test func legacyCaptureFileWithoutRetryPolicyUsesBundleDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hird-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundledData = try HirdPolicyFiles.resource("capture.json")
        var object = try #require(try JSONSerialization.jsonObject(with: bundledData) as? [String: Any])
        object.removeValue(forKey: "sourceStabilityAttempts")
        object.removeValue(forKey: "sourceStabilityRetryDelayMilliseconds")
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try legacy.write(to: root.appendingPathComponent("capture.json"))
        let loaded = try HirdPolicyFiles(directory: root).loadCapture()
        let bundled = try HirdCapturePolicy.bundled()
        #expect(loaded.sourceStabilityAttempts == bundled.sourceStabilityAttempts)
        #expect(loaded.sourceStabilityRetryDelayMilliseconds == bundled.sourceStabilityRetryDelayMilliseconds)
    }

    private func writeSlowEvidence(_ f: Fixture) throws {
        for index in 0..<48 {
            try f.write("docs/evidence/slow-\(String(format: "%02d", index)).bin", Data(repeating: UInt8(index % 251), count: 1_048_576))
        }
    }

    private func waitForEvidenceCopy(_ f: Fixture, root: URL? = nil) async throws {
        let blobs = (root ?? f.resultRoot).appendingPathComponent("blobs")
        for _ in 0..<3_000 {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: blobs.path), !entries.isEmpty { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("evidence copy never started")
        throw HirdError.workspace
    }

    @Test func missingLegacyPatchAndActualPrepareFailureAreDiagnostic() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = RunResult(worktreePath: f.project.path, branch: nil, commit: nil, diffPath: f.root.appendingPathComponent("missing.patch").path, summary: "legacy", verifications: [])
        await #expect(throws: HirdError.self) { try await HirdWorkspace.restore(result: old, at: f.project) }
        await #expect(throws: HirdError.self) {
            _ = try await HirdWorkspace.prepare(project: f.root, root: f.root.appendingPathComponent("failed"), previous: nil)
        }
        let diagnostics = f.root.appendingPathComponent("failed/workspace-diagnostics")
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: diagnostics.path)).isEmpty)
    }

    @Test func deterministicTimeoutAndLimitDiagnosticsContainNoOutput() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        var policy = try HirdCapturePolicy.bundled()
        policy.streamTimeoutSeconds = 0.01
        let destination = f.root.appendingPathComponent("stream")
        do {
            _ = try await HirdWorkspace.streamCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], at: f.project, destination: destination, root: f.resultRoot, stage: "test", kind: "sleep", policy: policy)
            Issue.record("timeout did not fail")
        } catch let HirdError.workspaceFailure(diagnostic) {
            #expect(diagnostic.timedOut)
            #expect(diagnostic.commandKind == "sleep")
            #expect(diagnostic.stage == "test")
            #expect(!String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self).contains("stdout"))
        }
    }
    @Test func legacyPatchRestoresAndTamperedArtifactFailsClosed() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("source.txt", Data("legacy change".utf8))
        let (result, _) = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "captured")
        let legacy = RunResult(worktreePath: f.project.path, branch: nil, commit: f.base, diffPath: result.diffPath, summary: "legacy", verifications: [])
        _ = try await HirdWorkspace.git(["checkout", "--", "source.txt"], at: f.project)
        try await HirdWorkspace.restore(result: legacy, at: f.project)
        #expect(try Data(contentsOf: f.project.appendingPathComponent("source.txt")) == Data("legacy change".utf8))
        let manifestURL = URL(fileURLWithPath: try #require(result.artifactManifestPath))
        let manifest = try HirdWorkspace.loadManifest(for: result)
        let blob = manifestURL.deletingLastPathComponent().appendingPathComponent(try #require(manifest.artifacts.first).blobPath)
        try Data("corruption".utf8).write(to: blob)
        await #expect(throws: HirdError.self) { try await HirdWorkspace.restore(result: result, at: f.project) }
    }

    @Test func pathTraversalManifestIsRejected() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("outputs/result.txt", Data("evidence".utf8))
        let (result, _) = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "captured")
        let url = URL(fileURLWithPath: try #require(result.artifactManifestPath))
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var rows = try #require(json["artifacts"] as? [[String: Any]])
        rows[0]["sourcePath"] = "../outside"
        json["artifacts"] = rows
        let bytes = try JSONSerialization.data(withJSONObject: json)
        let digest = HirdSecureFile.hex(SHA256.hash(data: bytes))
        let unsafe = f.resultRoot.appendingPathComponent("artifacts-" + digest + ".json")
        try bytes.write(to: unsafe)
        let metadata = try #require(result.artifactManifestMetadata)
        let tampered = RunResult(worktreePath: result.worktreePath, branch: result.branch, commit: result.commit, diffPath: result.diffPath, summary: "unsafe", verifications: [],
            artifactManifestPath: unsafe.path, artifactManifestMetadata: .init(sha256: digest, artifactCount: metadata.artifactCount, totalBytes: metadata.totalBytes))
        await #expect(throws: HirdError.self) { try await HirdWorkspace.restore(result: tampered, at: f.project) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("outside").path))
    }
    @Test func legacyIntentToAddNeverTurnsCacheIntoTrackedCode() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write(".build-legacy/cache", Data("cache".utf8))
        try f.write("docs/evidence/result.txt", Data("evidence".utf8))
        _ = try await HirdWorkspace.git(["add", "--intent-to-add", "."], at: f.project)
        let original = try Data(contentsOf: f.project.appendingPathComponent(".git/index"))
        let (result, _) = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "legacy index")
        let patch = try String(contentsOfFile: try #require(result.diffPath), encoding: .utf8)
        #expect(!patch.contains(".build-legacy"))
        #expect(!patch.contains("docs/evidence"))
        #expect(try HirdWorkspace.loadManifest(for: result).artifacts.contains { $0.sourcePath == "docs/evidence/result.txt" && $0.role == .evidence })
        #expect(try Data(contentsOf: f.project.appendingPathComponent(".git/index")) == original)
    }

    @Test func streamDeadlineIsIndependentAndOutputLimitIsRecorded() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        var policy = try HirdCapturePolicy.bundled()
        policy.metadataTimeoutSeconds = 0.01
        policy.streamTimeoutSeconds = 1
        let hash = try await HirdWorkspace.streamCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.05"], at: f.project,
            destination: f.root.appendingPathComponent("slow-stream"), root: f.resultRoot, stage: "test", kind: "sleep", policy: policy)
        #expect(hash.byteCount == 0)
        policy.maximumCommandBytes = 1
        do {
            _ = try await HirdWorkspace.streamCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["synthetic-output"], at: f.project,
                destination: f.root.appendingPathComponent("limited"), root: f.resultRoot, stage: "test", kind: "echo", policy: policy)
            Issue.record("output limit did not fail")
        } catch let HirdError.workspaceFailure(diagnostic) {
            #expect(diagnostic.outputLimitExceeded)
            #expect(diagnostic.exitStatus != nil)
            #expect(!String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self).contains("synthetic-output"))
        }
    }

    @Test func artifactCountQuotaAndExistingBlobCorruptionPreservePriorManifest() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("outputs/first.txt", Data("first".utf8))
        let (prior, _) = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "prior")
        let manifestURL = URL(fileURLWithPath: try #require(prior.artifactManifestPath))
        let priorBytes = try Data(contentsOf: manifestURL)
        try f.write("outputs/second.txt", Data("second".utf8))
        var policy = try HirdCapturePolicy.bundled(); policy.maximumArtifactCount = 2
        await #expect(throws: HirdError.self) {
            _ = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "count failure", policy: policy)
        }
        #expect(try Data(contentsOf: manifestURL) == priorBytes)
        let evidence = try #require(try HirdWorkspace.loadManifest(for: prior).artifacts.first { $0.role == .evidence })
        try Data("corrupt".utf8).write(to: manifestURL.deletingLastPathComponent().appendingPathComponent(evidence.blobPath))
        await #expect(throws: HirdError.self) {
            _ = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "corruption failure")
        }
        #expect(try Data(contentsOf: manifestURL) == priorBytes)
    }

    @Test func evidenceOnlyArchiveHashesLogsAndReportWithoutGit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hird-archive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("check.log"), report = root.appendingPathComponent("report.md")
        let attachment = root.appendingPathComponent("inspection.png")
        try Data([0, 1, 2, 3]).write(to: attachment)
        try Data("synthetic log".utf8).write(to: log); try Data("synthetic report".utf8).write(to: report)
        let check = VerificationRecord(id: "check", command: ["synthetic"], workingDirectory: "", startedAt: .now, finishedAt: .now, exitCode: 1, logPath: log.path, summary: "failed", attachmentPaths: [attachment.path])
        let result = try HirdWorkspace.preserveRunEvidence(previous: nil, workspace: .init(worktreePath: root.appendingPathComponent("missing-worktree").path, branch: nil, ompSessionPath: nil),
            root: root, verifications: [check], summary: "failed capture", reportPath: report.path)
        #expect(result.commit == nil && result.diffPath == nil)
        let manifest = try HirdWorkspace.loadManifest(for: result)
        #expect(manifest.artifacts.contains { $0.role == .verification })
        #expect(manifest.artifacts.contains { $0.role == .report })
        #expect(manifest.artifacts.contains { $0.role == .verification && $0.sourcePath == "inspection.png" && $0.byteCount == 4 })
    }
    @Test func runtimePolicyCannotDisableCredentialProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hird-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var policy = try HirdCapturePolicy.bundled()
        policy.sensitivePrefixes = ["not-a-credential"]
        try JSONEncoder().encode(policy).write(to: root.appendingPathComponent("capture.json"))
        #expect(throws: (any Error).self) { _ = try HirdPolicyFiles(directory: root).loadCapture() }
    }

    @Test func legacyPrepareAndSafeSourceSymlinkAreRestored() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("source.txt", Data("legacy".utf8))
        try FileManager.default.createSymbolicLink(atPath: f.project.appendingPathComponent("asset-link").path, withDestinationPath: "source.txt")
        let (result, _) = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "legacy")
        var previous = PersistedRun(hird: .init(id: "previous", name: "Hird", role: "change", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now),
            issueID: "issue", projectID: "project", ompSessionID: nil, ownershipToken: "synthetic", startedAt: .now)
        previous.result = .init(worktreePath: result.worktreePath, branch: result.branch, commit: result.commit, diffPath: result.diffPath, summary: "legacy", verifications: [])
        let (restored, _) = try await HirdWorkspace.prepare(project: f.project, root: f.root.appendingPathComponent("continued"), previous: previous)
        let tree = URL(fileURLWithPath: restored.worktreePath)
        #expect(try Data(contentsOf: tree.appendingPathComponent("source.txt")) == Data("legacy".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tree.appendingPathComponent("asset-link").path) == "source.txt")
    }
    @Test func systemTemporaryAliasSupportsSecurePolicyReads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hird-alias-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = try HirdPolicyFiles(directory: root).loadCapture()
        #expect(policy.maximumArtifactCount > 0)
        let fd = try HirdSecureFile.openDirectory(root)
        _ = Darwin.close(fd)
    }

    @Test func trackedCredentialUsesMetadataOnlyAndChangesFailClosed() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write(".env", Data("synthetic-credential".utf8))
        _ = try await HirdWorkspace.git(["add", ".env"], at: f.project)
        _ = try await HirdWorkspace.git(["commit", "-qm", "synthetic credential fixture"], at: f.project)
        let base = try await HirdWorkspace.git(["rev-parse", "HEAD"], at: f.project)
        let index = try Data(contentsOf: f.project.appendingPathComponent(".git/index"))
        try f.write("source.txt", Data("ordinary change".utf8))
        let (prior, _) = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: base, verifications: [], summary: "ordinary")
        try f.write(".env", Data("changed-credential".utf8))
        await #expect(throws: HirdError.self) {
            _ = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: base, verifications: [], summary: "must fail")
        }
        #expect(try Data(contentsOf: f.project.appendingPathComponent(".git/index")) == index)
        #expect(try HirdWorkspace.loadManifest(for: prior).artifacts.allSatisfy { $0.sourcePath != ".env" })
    }

    @Test func manifestWithoutDurableDigestIsRejected() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (result, _) = try await HirdWorkspace.capture(workspace: f.workspace, root: f.resultRoot, base: f.base, verifications: [], summary: "captured")
        let missingDigest = RunResult(worktreePath: result.worktreePath, branch: result.branch, commit: result.commit, diffPath: result.diffPath,
            summary: result.summary, verifications: [], artifactManifestPath: result.artifactManifestPath)
        #expect(throws: HirdError.self) { _ = try HirdWorkspace.loadManifest(for: missingDigest) }
    }
    @Test func evidenceSelectionDoesNotDependOnFoundationAbsoluteURLSpelling() async throws {
        let f = try await Fixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("outputs/nested/result.txt", Data("evidence".utf8))
        try f.write("docs/evidence/result.png", Data([1, 2, 3]))
        let policy = try HirdCapturePolicy.bundled()
        let expected = ["docs/evidence/result.png", "outputs/nested/result.txt"]
        for tree in [f.project, URL(fileURLWithPath: f.project.path, isDirectory: true)] {
            #expect(try HirdWorkspace.evidenceSelection(at: tree, tracked: [], policy: policy).paths == expected)
        }
    }
}
