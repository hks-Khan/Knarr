import AppKit
import Foundation
import Testing
import KnarrCore
@testable import KnarrUI

/// Offscreen probe for the Hird-activity path: a transcript with long picture messages and two
/// running cards receives tool-activity ticks the way a live Hird produces them. A 10 ms main-queue
/// timer measures how long the main thread stays unavailable; gaps over 100 ms are the stalls a
/// person feels as a dropped click.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ChatPerformanceProbeTests {
    /// A 10 ms run-loop timer records the gap between fires. The harness drives the main run loop
    /// inside `settle`, so a gap above 100 ms is main-thread work a click would have queued behind.
    @MainActor final class StallMeter {
        private var timer: Timer?
        private var last = ProcessInfo.processInfo.systemUptime
        private(set) var gaps: [Double] = []
        func start() {
            last = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    self.gaps.append((now - self.last) * 1000)
                    self.last = now
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        func stop() { timer?.invalidate(); timer = nil }
        var stalls: [Double] { gaps.filter { $0 > 100 } }
        var maxGap: Double { gaps.max() ?? 0 }
        var samples: Int { gaps.count }
    }

    private func picture(at url: URL) throws {
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
        NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        try #require(pixels.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test func hirdActivityTicksKeepTheMainThreadResponsive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-probe-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = root.appendingPathComponent("shot.png")
        try picture(at: shot)

        let store = ChangingCardsStore()
        var issue = ChangingCardsStore.card("probe")
        issue.hirds.append(ChangingCardsStore.hird("probe-2"))
        store.issues = [issue]
        let body = String(repeating: "긴 설명 문장이 계속 이어지는 응답입니다. ", count: 40)
        store.chat = (0..<400).map { i in
            i.isMultiple(of: 2) ? ChatItem(at: Date().addingTimeInterval(Double(i)), kind: .user("질문 \(i) " + body))
                : ChatItem(at: Date().addingTimeInterval(Double(i)), kind: .stallari("답변 \(i)\n\n![화면](\(shot.path))\n\n" + body, project: nil))
        }
        let h = HomeHarness(width: 1200, height: 800, store: store)
        defer { h.close() }
        try await Task.sleep(for: .milliseconds(400))

        let meter = StallMeter()
        ChatWebDiagnostics.reset()
        let started = ProcessInfo.processInfo.systemUptime
        meter.start()
        // Tool-activity ticks: same fields a running Hird changes on every edit/read.
        for tick in 0..<60 {
            store.issues[0].hirds[0].lastActivityAt = .now
            store.issues[0].hirds[0].currentCommand = "edit Sources/File\(tick).swift"
            h.settle(0.05)
        }
        meter.stop()
        let wall = ProcessInfo.processInfo.systemUptime - started
        let stalls = meter.stalls
        let result: [String: Any] = ["ticks": 60, "wall_seconds": wall, "samples": meter.samples,
            "stalls_over_100ms": stalls.count, "max_stall_ms": meter.maxGap,
            "sum_stall_ms": stalls.reduce(0, +), "hosted_messages": store.chat.count,
            "row_builds": ChatWebProjection.buildCount,
            "flush_count": ChatWebDiagnostics.flushCount,
            "flush_stalls_over_100ms": ChatWebDiagnostics.stalls.count,
            "flush_max_ms": ChatWebDiagnostics.flushMilliseconds.max() ?? 0]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("CHAT_STALL_PROBE " + String(decoding: data, as: UTF8.self))
        if let path = ProcessInfo.processInfo.environment["KNARR_CHAT_PROBE_OUT"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
        // The person must not wait behind a tick: no main-thread gap a click would have missed, a
        // bounded per-flush cost, and rows that stay cached across unchanged ticks.
        #expect(stalls.isEmpty, "\(stalls.count) main-thread stalls over 100 ms; worst \(meter.maxGap) ms")
        #expect(ChatWebDiagnostics.flushMilliseconds.max() ?? 0 < 100)
        #expect(ChatWebProjection.buildCount < 10)
    }
}
