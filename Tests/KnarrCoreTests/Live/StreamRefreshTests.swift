import Foundation
import AppKit
import Testing
import Darwin
import Observation
import os
@testable import KnarrUI
@testable import KnarrCore

@MainActor @Suite(.serialized) struct StreamRefreshTests {
    private func delta(_ text: String, id: String = "burst") -> OMPJSON {
        .object(["type": .string("message_update"), "messageId": .string(id), "message": .object(["role": .string("assistant")]),
                 "assistantMessageEvent": .object(["type": .string("text_delta"), "contentIndex": .number(0), "delta": .string(text)])])
    }
    @Test func tokenBurstPublishesBoundedFramesAndFlushesCompleteText() async throws {
        let f = try await LiveFixture.make()
        do {
            var changes = 0; var last = ""
            for _ in 0..<100 {
                await f.store.observe(frame: delta("가"))
                if f.store.streamingText != last { changes += 1; last = f.store.streamingText }
            }
            #expect(changes < 10)
            await f.store.observe(frame: .object(["type": .string("message_end"), "messageId": .string("burst"), "message": .object(["role": .string("assistant")])]))
            #expect(f.store.chat.contains { $0.kind == .stallari(String(repeating: "가", count: 100), project: nil) })
            try await Task.sleep(for: .milliseconds(300))
            #expect(f.store.streamingMessageID == nil)
            #expect(f.store.chat.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func chatPersistenceDoesNotInvalidateUnchangedProjectAndIssueViews() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            try await f.dispatch()
            try await f.store.whenIdle()
            let invalidated = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking {
                _ = f.store.issues; _ = f.store.questions; _ = f.store.projects
            } onChange: { invalidated.withLock { $0 = true } }
            try await f.repository.appendChat(.init(at: .now, kind: .user("새 대화")), projectID: StoredProject.hubID)
            try await f.store.whenIdle()
            #expect(!invalidated.withLock { $0 })
            var changed = try #require(f.store.issues.first)
            changed.title = "실제로 바뀐 상태"
            changed.hirds = []; changed.events = []
            try await f.repository.saveIssue(changed, projectID: "p")
            try await f.store.whenIdle()
            #expect(invalidated.withLock { $0 })
            #expect(f.store.issues.first?.title == "실제로 바뀐 상태")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test(.enabled(if: KnarrUITests.enabled && ProcessInfo.processInfo.environment["KNARR_STREAM_REPLAY_DB"] != nil))
    func replayLongConversationWhileStreaming() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["KNARR_STREAM_REPLAY_DB"])
        #expect(path.hasSuffix("performance-fixture.db"))
        let replayRoot = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-stream-replay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: replayRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: replayRoot) }
        let replayDB = replayRoot.appendingPathComponent("replay.db")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: replayDB)
        let repository = try await SQLiteKnarrRepository.open(at: replayDB)
        let rpc = LiveTestRPC(), hird = LiveTestHird()
        let session = StallariSession(repository: repository, rpc: rpc, hird: hird)
        let suite = "knarr-replay-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = LiveKnarrStore(repository: repository, session: session, rpc: rpc, hird: hird, preferences: defaults)
        var harness: HomeHarness?
        do {
            try await store.connect()
            harness = HomeHarness(width: 1400, height: 900, store: store)
            let history = store.chat
            let count = history.count
            #expect(count > 100)
            var before = rusage(); getrusage(RUSAGE_SELF, &before)
            let start = ProcessInfo.processInfo.systemUptime
            var profile: Process?
            if let output = ProcessInfo.processInfo.environment["KNARR_STREAM_PROFILE"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "5", "10", "-file", output]
                try process.run(); profile = process
            }
            defer { if let profile, profile.isRunning { profile.terminate() } }
            var published = 0, last = ""
            for _ in 0..<200 {
                await store.observe(frame: delta("답변이 진행되는 동안 화면과 기존 대화를 유지합니다. "))
                if store.streamingText != last { published += 1; last = store.streamingText }
                try await Task.sleep(for: .milliseconds(20))
            }
            await store.observe(frame: .object(["type": .string("message_end"), "messageId": .string("burst"), "message": .object(["role": .string("assistant")])]))
            try await Task.sleep(for: .milliseconds(300))
            var after = rusage(); getrusage(RUSAGE_SELF, &after)
            func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
            let cpu = seconds(after.ru_utime) + seconds(after.ru_stime) - seconds(before.ru_utime) - seconds(before.ru_stime)
            let wall = ProcessInfo.processInfo.systemUptime - start
            print("STREAM_REPLAY history=\(count) chunks=200 publications=\(published) cpu_seconds=\(cpu) wall_seconds=\(wall) cpu_percent=\(100 * cpu / wall)")
            if let profile { while profile.isRunning { try await Task.sleep(for: .milliseconds(20)) } }
            #expect(published < 100)
            #expect(store.streamingMessageID == nil)
            #expect(store.chat.count == count + 1)
            #expect(Array(store.chat.prefix(count)) == history)
            #expect(store.chat.last?.kind == .stallari(String(repeating: "답변이 진행되는 동안 화면과 기존 대화를 유지합니다. ", count: 200), project: nil))
            let bottomDistance = await (try #require(harness)).distanceFromBottom
            #expect(bottomDistance < 23)
            if let screenshot = ProcessInfo.processInfo.environment["KNARR_STREAM_SCREENSHOT"], let host = harness?.window.contentView,
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: screenshot))
            }
            // Read an older, real user message while a second reply grows below it.
            let h = try #require(harness)
            let oldText = try #require(history.prefix(count / 2).reversed().compactMap { item -> String? in
                if case .user(let text) = item.kind, !text.isEmpty { return text }; return nil
            }.first)
            let oldField = try #require(await h.revealMessage(String(oldText.prefix(40))))
            await h.alignMessage(oldField, offset: 40)
            let oldOffset = try #require(await h.messageOffset(oldField))
            #expect((await h.distanceFromBottom) > 200)
            for _ in 0..<40 {
                await store.observe(frame: delta("과거 대화를 읽는 동안 이어지는 답변입니다. ", id: "history-read"))
                try await Task.sleep(for: .milliseconds(20))
            }
            await store.observe(frame: .object(["type": .string("message_end"), "messageId": .string("history-read"), "message": .object(["role": .string("assistant")])]))
            h.settle()
            #expect(abs(try #require(await h.messageOffset(oldField)) - oldOffset) < 2)
            #expect(Array(store.chat.prefix(count)) == history)
            harness?.close(); harness = nil
            _ = await store.shutdown(); try await repository.close()
            defaults.removePersistentDomain(forName: suite)
        } catch {
            harness?.close(); _ = await store.shutdown(); try? await repository.close()
            defaults.removePersistentDomain(forName: suite); throw error
        }
    }

}
