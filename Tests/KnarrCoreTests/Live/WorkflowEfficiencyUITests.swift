import AppKit
import Testing
@testable import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct WorkflowEfficiencyUITests {
    @Test func savedJudgementsRemainVisibleInMainCards() async throws {
        let f = try await LiveFixture.make()
        var harness: HomeHarness?
        do {
            try await f.create(title: "완료 응답과 저장된 판정 일치")
            try await f.dispatch()
            try await f.finish()
            try await f.create("needs-repair", title: "완료 조건 미충족 작업", criteria: ["검사 통과"])
            try await f.dispatch("repair-run", issue: "needs-repair")
            _ = try await f.session.receive(.init(id: "repair-result", runID: "repair-run", at: .now,
                payload: .complete(f.result(), notificationID: "repair-notice")))
            try await f.session.judge(issueID: "needs-repair", runID: "repair-run",
                evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "완료 조건 미충족", met: false)])
            try await f.store.whenIdle()
            #expect(f.store.issues.first { $0.id == "t" }?.state == .done)
            #expect(f.store.issues.first { $0.id == "needs-repair" }?.state == .failed)
            #expect(Set(f.store.topIssueCards.issues.map(\.id)) == ["t", "needs-repair"])
            let h = HomeHarness(width: 1440, height: 900, store: f.store)
            harness = h
            TestWindow.present(h.window)
            await h.waitWeb()
            h.settle()
            let host = try #require(h.window.contentView)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_EFFICIENCY_SCREENSHOTS"]))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("main-judgement-cards.png"))
            h.close(); harness = nil
            try await f.cleanup()
        } catch { harness?.close(); try await f.cleanup(); throw error }
    }
}
