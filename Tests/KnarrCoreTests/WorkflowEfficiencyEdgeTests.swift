import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct WorkflowEfficiencyEdgeTests {
    @Test func generatedTrackedFileStillInvalidatesVerificationIdentity() async throws {
        let f = try await HirdWorkspacePreservationTests.Fixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let policy = try HirdCapturePolicy.bundled()
        let before = try await HirdWorkspace.verificationStamp(workspace: f.workspace, policy: policy)
        try f.write(".build-tracked/value.txt", Data("new!\n".utf8))
        let after = try await HirdWorkspace.verificationStamp(workspace: f.workspace, policy: policy)
        #expect(before != after, "A tracked generated file is part of the final code snapshot")
    }

    @Test(arguments: [false, true]) func mainStartedProjectIssueDeliversAcceptedResultToItsProject(legacyMirror: Bool) async throws {
        let f = try await StallariFixture.make()
        let id = try await f.session.createIssue(id: "from-main", title: "메인에서 요청한 작업", criteria: ["검사"], instruction: "수정", projectID: "p")
        let issueThread = try #require(try await f.repository.snapshot().issues.first?.conversationThreadID)
        let owner = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: issueThread)
        var project: StallariSession?
        do {
            let run = try await owner.approveIssue(issueID: id, version: 1)
            _ = try await owner.receive(.init(id: "end", runID: run, at: .now, payload: .complete(f.result(), notificationID: "notice")))
            try await owner.judge(issueID: id, runID: run, evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "충족")])
            let thread = try #require(try await f.repository.snapshot().threads.first { $0.projectID == "p" })
            if legacyMirror {
                let writer = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: 2)
                do {
                    try writer.execute("DELETE FROM thread_deliveries WHERE id='owner:hird-complete:notice'")
                    let delivery = ThreadDelivery(id: "main:hird-complete:notice", threadID: "default", issueID: id,
                        runID: run, createdAt: .now, kind: .completion(notificationID: "notice", summary: "legacy summary"))
                    let payload = String(decoding: try JSONEncoder().encode(delivery), as: UTF8.self)
                    try writer.execute("INSERT INTO thread_deliveries(id,thread_id,issue_id,run_id,payload) VALUES(?,?,?,?,?)",
                        [delivery.id, delivery.threadID, id.rawValue, run.rawValue, payload])
                    try writer.close()
                } catch { try writer.close(); throw error }
                try await f.session.deliverNotifications()
                #expect(try await f.repository.pendingThreadDeliveries(threadID: thread.id).count == 1)
                #expect(await f.rpc.prompts.isEmpty)
            }
            let rpc = TestStallariRPC()
            let session = StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id)
            project = session
            try await session.deliverNotifications(); try await session.deliverNotifications()
            #expect(await rpc.prompts.count == 1)
            #expect(try await session.getRun(run).id == run)
            await #expect(throws: StallariError.missingIssue) {
                try await session.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "다른 목표")
            }
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            #expect(try await reopened.pendingThreadDeliveries(threadID: thread.id).isEmpty)
            try await reopened.close()
            _ = await session.shutdown(); _ = await owner.shutdown(); try await f.cleanup()
        } catch { _ = await project?.shutdown(); _ = await owner.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func trackingAnExistingIgnoredFileChangesVerificationIdentity() async throws {
        let f = try await HirdWorkspacePreservationTests.Fixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write(".gitignore", Data("vendor.txt\n".utf8))
        try f.write("vendor.txt", Data("already present\n".utf8))
        _ = try await HirdWorkspace.git(["add", ".gitignore"], at: f.project)
        _ = try await HirdWorkspace.git(["commit", "-qm", "ignore"], at: f.project)
        let policy = try HirdCapturePolicy.bundled()
        let before = try await HirdWorkspace.verificationStamp(workspace: f.workspace, policy: policy)
        _ = try await HirdWorkspace.git(["add", "-f", "vendor.txt"], at: f.project)
        _ = try await HirdWorkspace.git(["commit", "-qm", "track"], at: f.project)
        let after = try await HirdWorkspace.verificationStamp(workspace: f.workspace, policy: policy)
        #expect(before != after)
    }

    @Test(arguments: ["exclude", "filemode", "attributes"]) func gitCaptureInputsInvalidateIdentity(kind: String) async throws {
        let f = try await HirdWorkspacePreservationTests.Fixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("untracked.txt", Data("untracked\n".utf8))
        let policy = try HirdCapturePolicy.bundled()
        let before = try await HirdWorkspace.verificationStamp(workspace: f.workspace, policy: policy)
        switch kind {
        case "exclude": try f.write(".git/info/exclude", Data("untracked.txt\n".utf8))
        case "filemode": _ = try await HirdWorkspace.git(["config", "core.filemode", "false"], at: f.project)
        default: try f.write(".git/info/attributes", Data("source.txt text eol=lf\n".utf8))
        }
        let after = try await HirdWorkspace.verificationStamp(workspace: f.workspace, policy: policy)
        #expect(before != after)
    }

    @Test(arguments: ["fixture", "unset", "unspecified"]) func externalCleanFiltersUseFullVerificationInsteadOfMetadataCache(driver: String) async throws {
        let f = try await HirdWorkspacePreservationTests.Fixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write(".gitattributes", Data("source.txt filter=\(driver)\n".utf8))
        _ = try await HirdWorkspace.git(["config", "filter.\(driver).clean", "cat"], at: f.project)
        await #expect(throws: HirdError.self) {
            _ = try await HirdWorkspace.verificationStamp(workspace: f.workspace, policy: HirdCapturePolicy.bundled())
        }
    }

    @Test func indexOnlyAttributesCannotHideEffectiveCaptureAttributes() async throws {
        let f = try await HirdWorkspacePreservationTests.Fixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let attributes = f.root.appendingPathComponent("global-attributes")
        try "*.txt text eol=lf\n".write(to: attributes, atomically: true, encoding: .utf8)
        _ = try await HirdWorkspace.git(["config", "core.attributesfile", attributes.path], at: f.project)
        try f.write(".gitattributes", Data("*.txt -text -eol\n".utf8))
        _ = try await HirdWorkspace.git(["add", ".gitattributes"], at: f.project)
        try FileManager.default.removeItem(at: f.project.appendingPathComponent(".gitattributes"))
        let policy = try HirdCapturePolicy.bundled()
        let before = try await HirdWorkspace.verificationStamp(workspace: f.workspace, policy: policy)
        try "*.txt text eol=crlf\n".write(to: attributes, atomically: true, encoding: .utf8)
        let after = try await HirdWorkspace.verificationStamp(workspace: f.workspace, policy: policy)
        #expect(before != after)
    }

    @Test(arguments: [false, true], [false, true]) func oldDefaultPolicyUpgradesWithoutReplacingCustomInstructions(custom: Bool, readOnly: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-policy-upgrade-" + UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WorkflowEfficiency/project-session-legacy.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        object["panelDefaultWidth"] = 555
        if custom { object["ownershipInstructions"] = "사용자가 직접 쓴 프로젝트 운영 지침" }
        let file = root.appendingPathComponent("project-session.json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        if readOnly { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path) }
        let loaded = try ProjectSessionPolicy.load(directory: root)
        #expect(loaded.panelDefaultWidth == 555)
        #expect(loaded.ownershipInstructions == (custom ? "사용자가 직접 쓴 프로젝트 운영 지침" : ProjectSessionPolicy.current.ownershipInstructions))
        if !readOnly { #expect(try ProjectSessionPolicy.decode(Data(contentsOf: file)) == loaded) }
    }
}
