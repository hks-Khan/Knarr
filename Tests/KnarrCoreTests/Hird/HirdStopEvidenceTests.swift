import CryptoKit
import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HirdStopEvidenceTests {
    static func wait(_ fixture: HirdFixture, until predicate: (PersistenceSnapshot) -> Bool) async throws -> PersistenceSnapshot {
        for _ in 0..<500 {
            let snapshot = try await fixture.repository.snapshot()
            if predicate(snapshot) { return snapshot }
            let stopped = snapshot.runs.first?.state.isTerminal == true
            try #require(!stopped, "합성 RPC가 예상 상태 전에 종료됐어요: \(snapshot.runs.first?.stopReason ?? "종료 원인 미보고")")
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try await fixture.repository.snapshot()
        let reached = predicate(snapshot)
        try #require(reached, "정해진 시간 안에 합성 RPC 상태에 도달해야 해요")
        return snapshot
    }

    static func question(_ id: String) -> OMPJSON {
        .object(["type": .string("extension_ui_request"), "id": .string(id), "method": .string("input"), "title": .string("합성 질문")])
    }

    static func abort() -> OMPJSON {
        .object(["type": .string("prompt_result"), "id": .string("prompt-1"), "status": .string("aborted"), "sessionSettled": .bool(true)])
    }

    static func readEvidence(_ fixture: HirdFixture, call: String = "read-evidence", withImage: Bool = false) async {
        var content: [OMPJSON] = [.object(["type": .string("text"), "text": .string("합성 문서 확인 근거")])]
        if withImage {
            content.append(.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(deliveredImage.base64EncodedString())]))
        }
        await fixture.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string(call), "toolName": .string("read"), "args": .object(["path": .string("original.txt")])]))
        await fixture.rpc.frame(.object(["type": .string("tool_execution_end"), "toolCallId": .string(call), "toolName": .string("read"), "isError": .bool(false), "result": .object(["content": .array(content)])]))
    }

    @Test(arguments: ["user", "omp"])
    func questionCancellationThenPromptAbortDoesNotBecomeRunCancellation(source: String) async throws {
        let f = try await HirdFixture.make(temporary: true)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            await f.rpc.frame(Self.question("cancelled-question"))
            let pending = try await Self.wait(f) { !$0.questions.isEmpty }
            let question = try #require(pending.questions.first)
            if source == "user" {
                _ = try await f.repository.cancelQuestion(question.id, runID: f.run.id, at: .now)
                try await f.adapter.deliver(.init(questionID: question.id, runID: f.run.id, issueID: f.run.issueID, answer: nil, cancelled: true))
                #expect(await f.rpc.sendCommands == ["extension_ui_response"])
                #expect(await f.rpc.sends.first == ["id": .string("cancelled-question"), "cancelled": .bool(true)])
            } else {
                await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("cancel-notice"), "method": .string("cancel"), "targetId": .string("cancelled-question")]))
                _ = try await Self.wait(f) { $0.questions.first?.state == .cancelled }
                #expect(await f.rpc.sendCommands.isEmpty)
            }
            #expect(try await f.repository.snapshot().runs[0].state == .working)
            await f.rpc.frame(Self.abort())
            let stopped = try await Self.wait(f) { $0.runs[0].state.isTerminal }
            _ = await task.result
            #expect(stopped.runs[0].state == .failed)
            #expect(stopped.runs[0].stopReason?.contains("[prompt_aborted]") == true)
            #expect(stopped.issues[0].events.contains { $0.text.contains("[question_cancelled]") && $0.text.contains("source=\(source)") })
            #expect(stopped.issues[0].events.contains { $0.text.contains("[prompt_aborted]") && $0.text.contains("cause=unknown") })
            #expect(await f.rpc.requests.filter { $0.0 == "prompt" }.count == 1)
            #expect(await f.rpc.requests.allSatisfy { $0.0 != "abort" && $0.0 != "abort_and_prompt" })
            #expect(await f.rpc.shutdownCancellations.allSatisfy { !$0 })
            #expect(stopped.notifications.isEmpty)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func explicitRunCancelRetainsTombstoneAndDoesNotClaimPromptAbort() async throws {
        let f = try await HirdFixture.make(temporary: true)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            await f.adapter.cancel(f.run.id)
            _ = await task.result
            await f.rpc.frame(Self.abort())
            try await f.adapter.start(f.run, emit: f.sink)
            let saved = try await f.repository.snapshot()
            #expect(saved.runs[0].state == .cancelled)
            #expect(saved.runs[0].stopReason?.contains("[prompt_aborted]") != true)
            #expect(saved.issues[0].events.contains { $0.text.contains("[run_cancelled]") && $0.text.contains("source=user") })
            #expect(await f.rpc.started == 1)
            #expect(await f.rpc.shutdownCancellations.contains(true))
            #expect(saved.notifications.isEmpty)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func transportTerminationPreservesObservedExitWithoutInferringCancellation() async throws {
        let f = try await HirdFixture.make(temporary: true)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            await f.rpc.terminate(status: 73)
            let saved = try await Self.wait(f) { $0.runs[0].state.isTerminal }
            _ = await task.result
            #expect(saved.runs[0].state == .failed)
            #expect(saved.runs[0].stopReason?.contains("[transport_terminated]") == true)
            #expect(saved.issues[0].events.contains { $0.text.contains("[transport_terminated]") && $0.text.contains("status=73") })
            #expect(await f.adapter.exits[f.run.id]?.status == 73)
            #expect(await f.adapter.exits[f.run.id]?.reason == .failed)
            #expect(await f.rpc.shutdownCancellations.allSatisfy { !$0 })
            #expect(saved.notifications.isEmpty)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test(arguments: ["aborted", "cancelled"])
    func archivalCaptureFailurePreservesPrimaryAndLastSnapshotWithNewEvidence(stop: String) async throws {
        let f = try await HirdFixture.make(temporary: true)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            let workspace = try #require(try await f.repository.snapshot().runs[0].workspace)
            let evidence = URL(fileURLWithPath: workspace.worktreePath).appendingPathComponent("docs/evidence")
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try "합성 보존 근거\n".write(to: evidence.appendingPathComponent("archive-proof.log"), atomically: true, encoding: .utf8)
            await f.rpc.frame(HirdResultTests.start("known-good"))
            await f.rpc.frame(HirdResultTests.end(0, call: "known-good"))
            await f.rpc.frame(Self.question("checkpoint-barrier"))
            let checkpoint = try await Self.wait(f) { !$0.questions.isEmpty }
            let previous = try #require(checkpoint.runs[0].result)
            let previousManifestURL = URL(fileURLWithPath: try #require(previous.artifactManifestPath))
            let previousManifestData = try Data(contentsOf: previousManifestURL)
            let previousManifest = try JSONDecoder().decode(HirdArtifactManifest.self, from: previousManifestData)
            let question = try #require(checkpoint.questions.first)
            _ = try await f.repository.answerQuestion(question.id, runID: f.run.id, answer: .init(selectedOptions: [], text: "합성 계속"), at: .now)
            await Self.readEvidence(f, withImage: true)
            await f.rpc.frame(Self.question("read-barrier"))
            _ = try await Self.wait(f) { $0.questions.count == 2 }
            let tree = URL(fileURLWithPath: previous.worktreePath)
            try "not a git worktree\n".write(to: tree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            if stop == "cancelled" { await f.adapter.cancel(f.run.id) }
            else { await f.rpc.frame(Self.abort()) }
            let saved = try await Self.wait(f) { $0.runs[0].state.isTerminal }
            _ = await task.result
            let result = try #require(saved.runs[0].result)
            #expect(saved.runs[0].state == (stop == "cancelled" ? .cancelled : .failed))
            if stop == "aborted" {
                #expect(saved.runs[0].stopReason?.contains("[prompt_aborted]") == true)
                #expect(saved.runs[0].stopReason?.contains("[capture_failed]") == true)
            } else {
                #expect(saved.runs[0].stopReason?.contains("[run_cancelled]") == true)
            }
            #expect(result.summary.contains("[capture_failed]") && result.summary.contains("stage=archive.capture"))
            #expect(result.diffPath == previous.diffPath)
            #expect(result.commit == previous.commit)
            let manifestURL = URL(fileURLWithPath: try #require(result.artifactManifestPath))
            let manifest = try JSONDecoder().decode(HirdArtifactManifest.self, from: Data(contentsOf: manifestURL))
            #expect(previousManifest.artifacts.allSatisfy { manifest.artifacts.contains($0) })
            #expect(try Data(contentsOf: previousManifestURL) == previousManifestData)
            #expect(manifest.artifacts.count > previousManifest.artifacts.count)
            #expect(result.artifactManifestMetadata?.artifactCount == manifest.artifacts.count)
            #expect(result.verifications.count == 2)
            #expect(result.verifications.last?.isInspection == true)
            let inspection = try #require(result.verifications.last)
            #expect(try String(contentsOfFile: inspection.logPath, encoding: .utf8).contains("합성 문서 확인 근거"))
            let imagePath = try #require(inspection.attachmentPaths?.first)
            let image = try #require(manifest.artifacts.first { $0.role == .verification && $0.sourcePath == URL(fileURLWithPath: imagePath).lastPathComponent })
            #expect(image.byteCount == Int64(Self.deliveredImage.count))
            #expect(image.sha256 == HirdSecureFile.hex(SHA256.hash(data: Self.deliveredImage)))
            #expect(try Data(contentsOf: manifestURL.deletingLastPathComponent().appendingPathComponent(image.blobPath)) == Self.deliveredImage)
            if stop == "aborted" {
                #expect(saved.issues[0].events.contains { $0.text.contains("[capture_failed]") && $0.text.contains("stage=archive.capture") })
            }
            #expect(!result.summary.contains("새 스냅샷을 보존했어요"))
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func intermediateCaptureFailureRecordsStageAndKeepsRunAlive() async throws {
        let f = try await HirdFixture.make(temporary: true)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            let workspace = try #require(try await f.repository.snapshot().runs[0].workspace)
            let tree = URL(fileURLWithPath: workspace.worktreePath)
            // A broken Git pointer makes every snapshot attempt fail deterministically.
            let gitEntry = tree.appendingPathComponent(".git")
            let gitPointer = try Data(contentsOf: gitEntry)
            try Data("not a git worktree\n".utf8).write(to: gitEntry)
            await f.rpc.frame(HirdResultTests.start("unstable-check"))
            await f.rpc.frame(HirdResultTests.end(17, call: "unstable-check"))
            await f.rpc.frame(Self.question("capture-barrier"))
            var barrier = try await f.repository.snapshot()
            for _ in 0..<2_000 where barrier.questions.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
                barrier = try await f.repository.snapshot()
            }
            try #require(!barrier.questions.isEmpty, "질문 도달 전 상태: \(barrier.runs[0].state) \(barrier.runs[0].stopReason ?? "")")
            // The failed snapshot never ends the run; the check log is still kept.
            #expect(!barrier.runs[0].state.isTerminal)
            #expect(barrier.issues[0].events.contains { $0.text.contains("[capture_failed]") && $0.text.contains("stage=verification.capture") },
                "\(barrier.issues[0].events.map(\.text))")
            try gitPointer.write(to: gitEntry)
            try "changed\n".write(to: tree.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
            let question = try #require(barrier.questions.first)
            _ = try await f.repository.answerQuestion(question.id, runID: f.run.id, answer: .init(selectedOptions: [], text: "계속"), at: .now)
            try await f.adapter.deliver(.init(questionID: question.id, runID: f.run.id, issueID: f.run.issueID,
                answer: .init(selectedOptions: [], text: "계속"), cancelled: false))
            await f.rpc.frame(HirdResultTests.start("stable-check"))
            await f.rpc.frame(HirdResultTests.end(0, call: "stable-check"))
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            var saved = try await f.repository.snapshot()
            for _ in 0..<2_000 where !saved.runs[0].state.isTerminal {
                try await Task.sleep(for: .milliseconds(10))
                saved = try await f.repository.snapshot()
            }
            try #require(saved.runs[0].state.isTerminal,
                "종료 전 상태: \(saved.runs[0].state) 활동: \(saved.issues[0].events.suffix(6).map(\.text))")
            _ = await task.result
            #expect(saved.runs[0].state == .succeeded)
            #expect(saved.runs[0].stopReason == nil)
            #expect(saved.issues[0].events.contains { $0.text.contains("[capture_failed]") && $0.text.contains("stage=verification.capture") })
            let result = try #require(saved.runs[0].result)
            #expect(result.verifications.map(\.exitCode) == [17, 0])
            #expect(result.diffPath != nil)
            let record = try #require(result.verifications.first)
            #expect(try String(contentsOfFile: record.logPath, encoding: .utf8).contains("FAILED"))
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func completionCaptureFailureStillFailsWithoutClaimingSuccess() async throws {
        let f = try await HirdFixture.make(temporary: true)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            let workspace = try #require(try await f.repository.snapshot().runs[0].workspace)
            let tree = URL(fileURLWithPath: workspace.worktreePath)
            try "changed\n".write(to: tree.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
            await f.rpc.frame(HirdResultTests.start("check"))
            await f.rpc.frame(HirdResultTests.end(0, call: "check"))
            let checked = try await Self.wait(f) { $0.runs[0].result?.diffPath != nil }
            try "not a git worktree\n".write(to: tree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            let saved = try await Self.wait(f) { $0.runs[0].state.isTerminal }
            _ = await task.result
            // The final snapshot is the completion evidence, so a persistent failure cannot pass as success.
            #expect(saved.runs[0].state == .failed)
            #expect(saved.runs[0].stopReason?.contains("[capture_failed]") == true)
            #expect(saved.runs[0].stopReason?.contains("stage=completion.capture") == true)
            #expect(saved.notifications.isEmpty)
            #expect(saved.runs[0].result?.diffPath == checked.runs[0].result?.diffPath)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func evidenceSymlinkDoesNotFailCapture() async throws {
        let f = try await HirdFixture.make(temporary: true)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            let workspace = try #require(try await f.repository.snapshot().runs[0].workspace)
            let tree = URL(fileURLWithPath: workspace.worktreePath)
            let evidence = tree.appendingPathComponent("docs/evidence")
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try "evidence\n".write(to: evidence.appendingPathComponent("proof.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: evidence.appendingPathComponent("third_party"), withDestinationURL: tree.appendingPathComponent("third_party"))
            try "changed\n".write(to: tree.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
            await f.rpc.frame(HirdResultTests.start("check"))
            await f.rpc.frame(HirdResultTests.end(0, call: "check"))
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            let saved = try await Self.wait(f) { $0.runs[0].state.isTerminal }
            _ = await task.result
            #expect(saved.runs[0].state == .succeeded)
            #expect(saved.runs[0].stopReason == nil)
            let result = try #require(saved.runs[0].result)
            #expect(result.diffPath != nil)
            let sessionPath = try #require(workspace.ompSessionPath)
            let diagnostics = URL(fileURLWithPath: sessionPath).deletingLastPathComponent().appendingPathComponent("workspace-diagnostics")
            let names = try FileManager.default.contentsOfDirectory(atPath: diagnostics.path)
            #expect(names.contains("evidence-skipped-symlink.json"))
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
    static func backgroundAdmission(_ call: String = "background-admission") -> OMPJSON {
        .object(["type": .string("tool_execution_end"), "toolCallId": .string(call), "toolName": .string("bash"), "isError": .bool(false),
            "result": .object(["details": .object(["exitCode": .null, "async": .object(["state": .string("running"), "jobId": .string("synthetic-job"), "type": .string("bash")])]),
                "content": .array([.object(["type": .string("text"), "text": .string("합성 백그라운드 접수")])])])])
    }

    static let deliveredImage = Data([137, 80, 78, 71, 13, 10, 26, 10])
    static func backgroundDelivery(withImage: Bool) -> OMPJSON {
        let text = "합성 백그라운드 최종 출력\n[Process exited with code 23]"
        let content: OMPJSON = withImage
            ? .array([.object(["type": .string("text"), "text": .string(text)]),
                      .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(deliveredImage.base64EncodedString())])])
            : .string(text)
        // v18.7.0 buildAsyncResultBatchMessage: job metadata deliberately has no exitCode/status.
        return .object(["type": .string("message_end"), "messageId": .string("synthetic-async-message"),
            "message": .object(["role": .string("custom"), "customType": .string("async-result"), "content": content,
                "details": .object(["jobs": .array([.object(["jobId": .string("synthetic-job"), "type": .string("bash"),
                    "label": .string("python3 -m unittest -v"), "durationMs": .number(500)])])])])])
    }

    @Test(arguments: [false, true])
    func actualBackgroundDeliveryIsArchivedButNeverInferredAsFinishedCheck(captureFails: Bool) async throws {
        let f = try await HirdFixture.make(temporary: true)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            await f.rpc.setSettled(false)
            await f.rpc.frame(HirdResultTests.start("background-admission"))
            await f.rpc.frame(Self.backgroundAdmission())
            await f.rpc.frame(HirdVerificationRetryTests.end(1, settled: false))
            await f.rpc.frame(Self.question("background-barrier"))
            let admission = try await Self.wait(f) { !$0.questions.isEmpty }
            let question = try #require(admission.questions.first)
            _ = try await f.repository.answerQuestion(question.id, runID: f.run.id, answer: .init(selectedOptions: [], text: "합성 계속"), at: .now)
            if captureFails {
                let workspace = try #require(admission.runs[0].workspace)
                try "not a git worktree\n".write(to: URL(fileURLWithPath: workspace.worktreePath).appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            }
            await f.rpc.frame(Self.backgroundDelivery(withImage: true))
            if captureFails {
                // A failed background snapshot is recorded, not fatal: the run keeps going.
                var active = try await f.repository.snapshot()
                for _ in 0..<2_000 where !active.issues[0].events.contains(where: {
                    $0.text.contains("[capture_failed]") && $0.text.contains("stage=background.capture")
                }) {
                    try await Task.sleep(for: .milliseconds(10))
                    active = try await f.repository.snapshot()
                }
                #expect(active.issues[0].events.contains { $0.text.contains("[capture_failed]") && $0.text.contains("stage=background.capture") })
                #expect(!active.runs[0].state.isTerminal)
                await f.adapter.cancel(f.run.id)
                _ = await task.result
                #expect(try await f.repository.snapshot().runs[0].state == .cancelled)
                try await f.cleanup()
                return
            }
            await f.rpc.setSettled(true)
            await f.rpc.frame(.object(["type": .string("session_settled")]))
            try await HirdVerificationRetryTests.awaitPrompts(2, f)
            #expect(try await f.repository.snapshot().runs[0].state != .succeeded)
            await f.adapter.cancel(f.run.id)
            let saved = try await Self.wait(f) { $0.runs[0].state.isTerminal }
            _ = await task.result
            let result = try #require(saved.runs[0].result)
            #expect(result.verifications.count == 2)
            #expect(result.verifications.allSatisfy { $0.exitCode == nil && !$0.isInspection })
            let delivery = try #require(result.verifications.last)
            let log = try String(contentsOfFile: delivery.logPath, encoding: .utf8)
            #expect(log.contains("합성 백그라운드 최종 출력") && log.contains("exited with code 23"))
            let imageLine = try #require(log.split(separator: "\n").first { $0.hasPrefix("Observed image: ") })
            let image = URL(fileURLWithPath: String(imageLine.dropFirst("Observed image: ".count)))
            #expect(try Data(contentsOf: image) == Self.deliveredImage)
            #expect(delivery.attachmentPaths == [image.path])
            let manifestURL = URL(fileURLWithPath: try #require(result.artifactManifestPath))
            let manifest = try JSONDecoder().decode(HirdArtifactManifest.self, from: Data(contentsOf: manifestURL))
            let attachment = try #require(manifest.artifacts.first { $0.role == .verification && $0.sourcePath == image.lastPathComponent })
            #expect(attachment.byteCount == Int64(Self.deliveredImage.count))
            #expect(attachment.sha256 == HirdSecureFile.hex(SHA256.hash(data: Self.deliveredImage)))
            #expect(try Data(contentsOf: manifestURL.deletingLastPathComponent().appendingPathComponent(attachment.blobPath)) == Self.deliveredImage)
            #expect(saved.notifications.isEmpty)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func supportedBackgroundFollowupKeepsAdmissionUnfinishedAndFinalForegroundFailure() async throws {
        let f = try await HirdFixture.make(temporary: true)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            try await HirdVerificationRetryTests.invalidate("missing", f)
            await f.rpc.setSettled(false)
            await f.rpc.frame(HirdResultTests.start("background-admission"))
            await f.rpc.frame(Self.backgroundAdmission())
            await f.rpc.frame(HirdVerificationRetryTests.end(1, settled: false))
            await f.rpc.frame(Self.question("yield-barrier"))
            let yielded = try await Self.wait(f) { !$0.questions.isEmpty }
            #expect(!yielded.runs[0].state.isTerminal)
            #expect(yielded.runs[0].result?.verifications.first?.exitCode == nil)
            let question = try #require(yielded.questions.first)
            _ = try await f.repository.answerQuestion(question.id, runID: f.run.id, answer: .init(selectedOptions: [], text: "합성 계속"), at: .now)
            // The same job delivers a supported custom message, then the ordinary
            // follow-up run performs a separate foreground final verification.
            await f.rpc.frame(Self.backgroundDelivery(withImage: false))
            await f.rpc.frame(.object(["type": .string("agent_start")]))
            await f.rpc.frame(HirdResultTests.start("foreground-final"))
            await f.rpc.frame(HirdResultTests.end(9, call: "foreground-final"))
            await f.rpc.frame(.object(["type": .string("agent_end"), "yielded": .bool(true), "isTerminal": .bool(true)]))
            await f.rpc.setSettled(true)
            await f.rpc.frame(.object(["type": .string("session_settled")]))
            let saved = try await Self.wait(f) { $0.runs[0].state.isTerminal }
            try await task.value
            #expect(saved.runs[0].state == .succeeded)
            #expect(saved.runs[0].result?.verifications.map(\.exitCode) == [nil, nil, 9])
            let logs = try #require(saved.runs[0].result?.verifications)
            try #require(logs.count == 3)
            #expect(try String(contentsOfFile: logs[0].logPath, encoding: .utf8).contains("백그라운드 접수"))
            #expect(try String(contentsOfFile: logs[1].logPath, encoding: .utf8).contains("exited with code 23"))
            #expect(try String(contentsOfFile: logs[2].logPath, encoding: .utf8).contains("FAILED"))
            #expect(await f.rpc.requests.filter { $0.0 == "prompt" }.count == 1)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
}
