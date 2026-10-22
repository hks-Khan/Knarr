import AppKit
import Foundation
import Darwin
import Testing
@testable import KnarrUI
@testable import KnarrCore

@MainActor @Suite(.serialized) struct ResizePerformanceTests {
    @Test(.enabled(if: KnarrUITests.enabled && ProcessInfo.processInfo.environment["KNARR_RESIZE_REPLAY_DB"] != nil))
    func continuousWidthChangesKeepLongConversationResponsive() async throws {
        let source = try #require(ProcessInfo.processInfo.environment["KNARR_RESIZE_REPLAY_DB"])
        #expect(source.hasSuffix("performance-fixture.db"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-resize-replay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("replay.db")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: db)
        let repository = try await SQLiteKnarrRepository.open(at: db)
        let rpc = LiveTestRPC(), hird = LiveTestHird()
        let session = StallariSession(repository: repository, rpc: rpc, hird: hird)
        let suite = "knarr-resize-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = LiveKnarrStore(repository: repository, session: session, rpc: rpc, hird: hird, preferences: defaults)
        var harness: HomeHarness?
        do {
            try await store.connect()
            store.composerDraft = .init(text: "너비를 바꾸어도 남아야 하는 초안")
            let history = store.chat
            #expect(history.count > 200)
            let h = HomeHarness(width: 1400, height: 900, store: store)
            harness = h
            let host = try #require(h.window.contentView)
            var before = rusage(); getrusage(RUSAGE_SELF, &before)
            let started = ProcessInfo.processInfo.systemUptime
            var frames: [Double] = []
            // Consecutive real window geometry changes, with no half-second settle between them.
            for index in 0..<80 {
                let phase = index % 40
                let width = CGFloat(980 + (phase <= 20 ? phase : 40 - phase) * 21)
                let frameStart = ProcessInfo.processInfo.systemUptime
                h.window.setContentSize(NSSize(width: width, height: 900))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                frames.append(ProcessInfo.processInfo.systemUptime - frameStart)
                try await Task.sleep(for: .milliseconds(16))
            }
            var after = rusage(); getrusage(RUSAGE_SELF, &after)
            func seconds(_ v: timeval) -> Double { Double(v.tv_sec) + Double(v.tv_usec) / 1_000_000 }
            let cpu = seconds(after.ru_utime) + seconds(after.ru_stime) - seconds(before.ru_utime) - seconds(before.ru_stime)
            let wall = ProcessInfo.processInfo.systemUptime - started
            let sorted = frames.sorted()
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            let result: [String: Any] = ["history": history.count, "frames": frames.count,
                "cpu_seconds": cpu, "wall_seconds": wall, "cpu_percent": 100 * cpu / wall,
                "frame_median_ms": sorted[sorted.count / 2] * 1000, "frame_p95_ms": p95 * 1000,
                "frame_max_ms": (sorted.last ?? 0) * 1000, "frames_over_50ms": frames.filter { $0 > 0.05 }.count, "frame_samples_ms": frames.map { $0 * 1000 }]
            // Changing the saved top-card disclosure leaves the transcript and draft intact.
            h.resize(width: 1400, height: 900)
            let attachment = root.appendingPathComponent("보존할 첨부.txt")
            try Data("격리 첨부 보존 검사".utf8).write(to: attachment)
            store.composerDraft.attachments = [attachment]
            for index in 0..<40 {
                h.defaults.set(index.isMultiple(of: 2), forKey: "knarr.issueCardsCollapsed")
                try await Task.sleep(for: .milliseconds(16))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            }
            #expect(store.composerDraft.attachments == [attachment])
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print("연속창너비검사 " + String(decoding: data, as: UTF8.self))
            if let path = ProcessInfo.processInfo.environment["KNARR_RESIZE_METRICS"] { try data.write(to: URL(fileURLWithPath: path)) }
            h.settle()
            await h.waitWeb()
            let mounted = try #require(await h.webJSON("document.querySelectorAll('[data-message]').length") as? Int)
            #expect(mounted > 1 && mounted < history.count / 2)
            #expect(store.chat == history)
            #expect(store.composerDraft.text == "너비를 바꾸어도 남아야 하는 초안")
            #expect((await h.distanceFromBottom) < 23)
            if ProcessInfo.processInfo.environment["KNARR_RESIZE_ENFORCE"] == "1" { #expect(p95 < 0.05) }
            if let path = ProcessInfo.processInfo.environment["KNARR_RESIZE_SCREENSHOT"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            h.close(); harness = nil
            _ = await store.shutdown(); try await repository.close()
            defaults.removePersistentDomain(forName: suite)
        } catch {
            harness?.close(); _ = await store.shutdown(); try? await repository.close()
            defaults.removePersistentDomain(forName: suite); throw error
        }
    }
}
