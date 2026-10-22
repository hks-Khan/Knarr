import AppKit
import SwiftUI
import Testing
@testable import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ProgressPresentationUITests {
    private func value(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }
    private func labels(_ node: NSObject) -> [String] {
        let own = ["accessibilityLabel", "accessibilityValue"].compactMap { value(node, $0) as? String }
        return own + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(labels)
    }
    private func capture(_ host: NSView, _ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["KNARR_REVIEW_SCREENSHOTS"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name + ".png"))
    }
    @Test(arguments: [false, true]) func cardsSeparateActivityPlanAndJudgement(dark: Bool) throws {
        let store = ChangingCardsStore()
        let sample = try #require(SampleKnarrStore(designScene: .issues).issues.first)
        let now = Date.now
        let plan: [IssueStage] = [
            .init(id: "read", title: "자료 확인", evidence: "원문 확인"),
            .init(id: "edit", title: "변경 구현", evidence: "변경과 검사"),
            .init(id: "check", title: "최종 검사", evidence: "실행 결과")
        ]
        func item(_ id: String, _ title: String, ended: Bool, judged: Bool) -> KnarrCore.Issue {
            var issue = sample
            issue.id = KnarrCore.Issue.ID(id)
            issue.title = title
            issue.projectName = "Knarr"
            issue.startedAt = now.addingTimeInterval(-120)
            issue.threadID = ConversationThread.defaultID
            issue.state = judged ? .done : .running
            issue.application = nil
            issue.archivedAt = nil
            issue.acceptance = (1...3).map { Criterion(text: "완료 조건 \($0)", state: judged ? .met : .pending, evidence: "") }
            issue.headline = judged ? "완료 조건 충족" : "Hird 실행"
            issue.detail = ""
            issue.latestResult = nil
            issue.completedAt = ended ? now : nil
            issue.approval = .init(version: 1, approvedAt: now.addingTimeInterval(-120))
            issue.approvalHistory = [issue.approval!]
            var hird = HirdRun(id: HirdRun.ID(id + "-run"), name: "Hird", role: "", status: ended ? .done(at: now) : .working,
                steps: [], currentCommand: ended ? nil : "swift test --filter ReviewResumeTests", lastActivityAt: now)
            hird.startedAt = now.addingTimeInterval(-120)
            hird.currentActivity = .init(kind: .command, target: "swift test --filter ReviewResumeTests", at: now)
            hird.recentActivities = [.init(kind: .read, target: "StallariReview.swift", at: now.addingTimeInterval(-30)),
                .init(kind: .edit, target: "ReviewResumeTests.swift", at: now.addingTimeInterval(-10)), hird.currentActivity!]
            hird.stageProgress = HirdProgress(.init(outcome: ended ? .done : .active, plan: plan))
            issue.hirds = [hird]
            return issue
        }
        store.issues = [item("progress-working", "검증 기록 개선", ended: false, judged: false),
                        item("progress-judging", "MCP 연결 결과 확인", ended: true, judged: false),
                        item("progress-accepted", "탭 미확인 답변 표시", ended: true, judged: true)]
        let host = NSHostingView(rootView: IssueCardsView(store: store, maximumHeight: 500,
            open: { _ in }, collapsed: .constant(false)).frame(width: 960, height: 500, alignment: .top)
            .background(K.canvas)
            .preferredColorScheme(dark ? .dark : .light))
        let window = TestWindow.make(size: NSSize(width: 960, height: 500), dark: dark)
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        TestWindow.present(window)
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded() }
        let all = labels(host)
        try capture(host, "progress-cards-" + (dark ? "dark" : "light"))
        #expect(all.contains { $0.contains("ReviewResumeTests") })
        #expect(all.contains { $0.contains("작업 계획 3개") })
        #expect(!all.contains { $0.contains("단계 1/5") || $0.contains("단계 5/5") })
        #expect(all.contains { $0.contains("판정 중") })
        #expect(all.contains { $0.contains("통합 대기") })
    }
}
