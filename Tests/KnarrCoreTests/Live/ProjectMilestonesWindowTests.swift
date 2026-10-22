import AppKit
import Observation
import SwiftUI
import Testing
@testable import KnarrCore
@testable import KnarrUI

/// Real project detail in an offscreen window. Uses the in-memory sample store, so no runtime,
/// no repository and no provider call is touched.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ProjectMilestonesWindowTests {
    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let attribute = ["accessibilityChildren": "AXChildren", "accessibilityIdentifier": "AXIdentifier",
                         "accessibilityLabel": "AXDescription", "accessibilityValue": "AXValue"][selector]
        return attribute.flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    private func press(_ node: NSObject) -> Bool {
        let action = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        guard node.responds(to: action) else { return false }
        return unsafeBitCast(node.method(for: action), to: Press.self)(node, action)
    }
    private func node(_ nodes: [NSObject], id: String? = nil, label: String? = nil) -> NSObject? {
        nodes.first {
            (id == nil || value($0, "accessibilityIdentifier") as? String == id)
                && (label == nil || value($0, "accessibilityLabel") as? String == label)
                && $0.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        }
    }
    /// SwiftUI fields surface in the AppKit view tree; AX gives them an anonymous node.
    private func fields(_ view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        for sub in view.subviews {
            if let field = sub as? NSTextField { found.append(field) }
            found += fields(sub)
        }
        return found
    }
    /// SwiftUI `TextEditor` is an `NSTextView` inside a scroll view, not a text field.
    private func textViews(_ view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        for sub in view.subviews {
            if let textView = sub as? NSTextView { found.append(textView) }
            found += textViews(sub)
        }
        return found
    }
    private func type(_ text: String, into field: NSTextField) {
        field.stringValue = text
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
    }

    private func open(_ store: SampleKnarrStore, project: String, tab: ProjectTab = .milestones,
                      size: NSSize = NSSize(width: 1180, height: 960), dark: Bool = false) throws -> (NSWindow, NSHostingView<AnyView>) {
        try open(store, project: project, tab: tab, size: size, dark: dark, currentTab: nil)
    }

    private func open(_ store: SampleKnarrStore, project: String, tab: ProjectTab, size: NSSize, dark: Bool,
                      currentTab: BindingBox<ProjectTab>?) throws -> (NSWindow, NSHostingView<AnyView>) {
        let project = try #require(store.projects.first { $0.id == project })
        let window = TestWindow.make(size: size, dark: dark)
        let tab = currentTab ?? BindingBox(tab)
        let view = ProjectDetail(store: store, project: project,
            tab: Binding(get: { tab.value }, set: { tab.value = $0 }), issueFilter: .constant(.all),
            open: { _ in }, talk: { store.selectProjectConversation($0) },
            request: { ProjectConversationRequest.prepare(store: store, projectID: project.id, text: $0) })
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: AnyView(view))
        window.contentView = host
        TestWindow.present(window)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test(arguments: [false, true])
    func createEditAndIssueDraftPreserveHistory(dark: Bool) async throws {
        _ = NSApplication.shared

        // Empty project: the empty state offers creation; the created milestone persists.
        let empty = SampleKnarrStore()
        let (emptyWindow, emptyHost) = try open(empty, project: "soomcha", dark: dark)
        defer { emptyWindow.contentView = nil; emptyWindow.close() }
        try await settle(emptyHost)
        var nodes = elements(emptyHost)
        let emptyText = nodes.flatMap { [$0, value($0, "accessibilityValue"), value($0, "accessibilityLabel")] }
            .compactMap { $0 as? String }
        #expect(emptyText.contains { $0.contains("아직 마일스톤이 없어요") })
        #expect(press(try #require(node(nodes, id: "milestone-create-empty"))))
        try await settle(emptyHost)
        nodes = elements(emptyHost)
        let titleField = try #require(fields(emptyHost).first { $0.placeholderString == "예: 대화 반복 제거" })
        type("첫 배포 준비", into: titleField)
        let targetField = try #require(fields(emptyHost).first { $0.placeholderString == "YYYY-MM-DD" })
        type("2026-11-30", into: targetField)
        try await settle(emptyHost)
        #expect(press(try #require(node(elements(emptyHost), id: "milestone-save"))))
        try await settle(emptyHost)
        let created = try #require(empty.milestones(inProject: "soomcha").first)
        #expect(created.title == "첫 배포 준비")
        #expect(created.targetDate != nil)
        try save(emptyWindow, name: "project-milestones-created-\(dark ? "dark" : "light")")

        // Existing project: edit the target date; earlier weekly records must not move.
        let store = SampleKnarrStore()
        let before = try #require(store.milestones(inProject: "gamza").first { $0.id == "gamza-dialogue" })
        let (window, host) = try open(store, project: "gamza", dark: dark)
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        nodes = elements(host)
        #expect(nodes.contains { (value($0, "accessibilityLabel") as? String) == "대화 반복 제거" })
        #expect(press(try #require(node(nodes, label: "고치기"))))
        try await settle(host)
        nodes = elements(host)
        let editTarget = try #require(fields(host).first { $0.placeholderString == "YYYY-MM-DD" })
        type("2026-12-15", into: editTarget)
        try await settle(host)
        #expect(press(try #require(node(elements(host), id: "milestone-save"))))
        try await settle(host)
        let after = try #require(store.milestones(inProject: "gamza").first { $0.id == "gamza-dialogue" })
        // Past weeks are history; the current week may be revised in place.
        #expect(Array(after.weeks.dropLast()) == Array(before.weeks.dropLast()),
                "target-date edits must not rewrite past weekly plans or results")
        #expect(after.weeks.last?.weekStart == before.weeks.last?.weekStart)
        #expect(after.weeks.last?.scope == before.weeks.last?.scope)
        #expect(after.targetDate != before.targetDate)
        // The trusted save path records the edit; the detail shows it.
        #expect(after.targetDateHistory.count == 1)
        #expect(after.targetDateHistory.first?.previous == before.targetDate)
        #expect(after.targetDateHistory.first?.updated == after.targetDate)
        #expect(press(try #require(node(elements(host), label: "고치기"))))
        try await settle(host)
        #expect(press(try #require(node(elements(host), id: "milestone-save"))))
        try await settle(host)
        let unchanged = try #require(store.milestones(inProject: "gamza").first { $0.id == "gamza-dialogue" })
        #expect(unchanged.targetDateHistory.count == 1, "saving without a date change grows no history")
        let historyText = allText(host)
        #expect(historyText.contains { $0.contains("목표일 변경 이력") })

        // Reorder through the store's single transaction.
        #expect(press(try #require(node(elements(host), label: "순서 아래로"))))
        try await settle(host)
        #expect(store.milestones(inProject: "gamza").map(\.id).prefix(2) == ["gamza-release", "gamza-dialogue"])

        // 이슈 만들기 writes the project draft only, naming the milestone ID.
        let draft = try #require(node(elements(host), id: "milestone-create-issue"))
        #expect(press(draft))
        try await settle(host)
        let text = store.composerDraft.text
        #expect(text.contains("대화 반복 제거"))
        #expect(text.contains("gamza-dialogue"))
        #expect(store.threads.first { $0.id == store.selectedThreadID }?.projectID == "gamza")
        #expect(!store.chat.contains { if case .user(let sent) = $0.kind { sent == text } else { false } })
        // A reached milestone keeps its explicit completion while its target date is edited.
        let doneBefore = try #require(store.milestones(inProject: "gamza").first { $0.id == "gamza-onboarding" })
        #expect(doneBefore.isReached)
        nodes = elements(host)
        #expect(press(try #require(node(nodes, id: "milestone-row-gamza-onboarding"))))
        try await settle(host)
        #expect(press(try #require(node(elements(host), label: "고치기"))))
        try await settle(host)
        type("2026-10-20", into: try #require(fields(host).first { $0.placeholderString == "YYYY-MM-DD" }))
        try await settle(host)
        #expect(press(try #require(node(elements(host), id: "milestone-save"))))
        try await settle(host)
        let doneAfter = try #require(store.milestones(inProject: "gamza").first { $0.id == "gamza-onboarding" })
        #expect(doneAfter.isReached)
        #expect(doneAfter.reachedAt == doneBefore.reachedAt)
        #expect(doneAfter.canReach)
        // Fields the editor no longer shows stay exactly as stored.
        #expect(doneAfter.detail == doneBefore.detail)
        #expect(doneAfter.inScope == doneBefore.inScope)
        #expect(doneAfter.outOfScope == doneBefore.outOfScope)
        #expect(doneAfter.weeks == doneBefore.weeks)
        #expect(doneAfter.evidence == doneBefore.evidence)

        try save(window, name: "project-milestones-detail-\(dark ? "dark" : "light")")
    }

    @Test func overviewOpensTheExactCurrentMilestoneEvenAfterAnotherWasSelected() async throws {
        _ = NSApplication.shared
        let store = SampleKnarrStore()
        let project = try #require(store.projects.first { $0.id == "gamza" })
        let tab = BindingBox(ProjectTab.overview)
        let window = TestWindow.make(size: NSSize(width: 1180, height: 960))
        let view = ProjectDetail(store: store, project: project,
            tab: Binding(get: { tab.value }, set: { tab.value = $0 }), issueFilter: .constant(.all),
            open: { _ in }, talk: { store.selectProjectConversation($0) },
            request: { ProjectConversationRequest.prepare(store: store, projectID: project.id, text: $0) })
        let host = NSHostingView(rootView: AnyView(view))
        window.contentView = host
        TestWindow.present(window)
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        try await settle(host)

        let current = try #require(Milestone.current(in: store.milestones(inProject: "gamza")))
        #expect(current.id == "gamza-dialogue")
        // Overview's 자세히 carries the shown stage's ID into the tab.
        #expect(press(try #require(node(elements(host), id: "overview-milestone-detail"))))
        try await settle(host)
        #expect(tab.value == .milestones)
        #expect(shownDetail(host) == current.title)

        // Choosing another stage, then returning through 개요, must reopen the overview's stage,
        // not the tab's previously selected one.
        #expect(press(try #require(node(elements(host), id: "milestone-row-gamza-release"))))
        try await settle(host)
        #expect(shownDetail(host) == "1.0 출시 준비")
        tab.value = .overview
        try await settle(host)
        #expect(press(try #require(node(elements(host), id: "overview-milestone-detail"))))
        try await settle(host)
        #expect(shownDetail(host) == current.title)
        try save(window, name: "project-milestones-exact-navigation")
    }

    @Test func allReachedOverviewShowsTheReachedStageAndEmptyOverviewStartsTheEditor() async throws {
        _ = NSApplication.shared

        let reached = SampleKnarrStore(milestoneScene: .allReached)
        let project = try #require(reached.projects.first { $0.id == "gamza" })
        let allReached = reached.milestones(inProject: "gamza").allSatisfy { $0.isReached }
        #expect(allReached)
        let tab = BindingBox(ProjectTab.overview)
        let window = TestWindow.make(size: NSSize(width: 1180, height: 960))
        let view = ProjectDetail(store: reached, project: project,
            tab: Binding(get: { tab.value }, set: { tab.value = $0 }), issueFilter: .constant(.all),
            open: { _ in }, talk: { reached.selectProjectConversation($0) },
            request: { ProjectConversationRequest.prepare(store: reached, projectID: project.id, text: $0) })
        let host = NSHostingView(rootView: AnyView(view))
        window.contentView = host
        TestWindow.present(window)
        host.layoutSubtreeIfNeeded()
        try await settle(host)
        let texts = allText(host)
        #expect(texts.contains { $0.contains("아직 마일스톤이 없어요") } == false)
        #expect(texts.contains { $0.contains("모든 마일스톤에 도달했어요") })
        #expect(texts.contains { $0.contains("튜토리얼 정리") })
        #expect(press(try #require(node(elements(host), id: "overview-milestone-detail"))))
        try await settle(host)
        #expect(shownDetail(host) == "튜토리얼 정리")
        try save(window, name: "project-overview-all-reached")
        window.contentView = nil; window.close()

        // Empty project: the overview button opens the editor itself, not just the tab.
        let empty = SampleKnarrStore()
        let emptyProject = try #require(empty.projects.first { $0.id == "soomcha" })
        let emptyTab = BindingBox(ProjectTab.overview)
        let emptyWindow = TestWindow.make(size: NSSize(width: 1180, height: 960))
        let emptyView = ProjectDetail(store: empty, project: emptyProject,
            tab: Binding(get: { emptyTab.value }, set: { emptyTab.value = $0 }), issueFilter: .constant(.all),
            open: { _ in }, talk: { empty.selectProjectConversation($0) },
            request: { ProjectConversationRequest.prepare(store: empty, projectID: emptyProject.id, text: $0) })
        let emptyHost = NSHostingView(rootView: AnyView(emptyView))
        emptyWindow.contentView = emptyHost
        TestWindow.present(emptyWindow)
        emptyHost.layoutSubtreeIfNeeded()
        defer { emptyWindow.contentView = nil; emptyWindow.close() }
        try await settle(emptyHost)
        #expect(press(try #require(node(elements(emptyHost), id: "overview-milestone-create"))))
        try await settle(emptyHost)
        #expect(emptyTab.value == .milestones)
        #expect(fields(emptyHost).contains { $0.placeholderString == "예: 대화 반복 제거" })
        try save(emptyWindow, name: "project-overview-empty-create")
    }

    @Test func weeklyPlanEditsOnlyThisWeekAndResultsComeFromIssues() async throws {
        _ = NSApplication.shared
        let store = SampleKnarrStore()
        let statusesBefore = Dictionary(uniqueKeysWithValues: store.milestones(inProject: "gamza").map { ($0.id, $0.status) })
        let thisWeek = ProjectWeek.start(containing: .now)
        let historyBefore = store.weekPlans(inProject: "gamza").filter { $0.weekStart < thisWeek }
        let tab = BindingBox(ProjectTab.overview)
        let (window, host) = try open(store, project: "gamza", tab: .overview,
                                      size: NSSize(width: 1180, height: 960), dark: false, currentTab: tab)
        defer { window.contentView = nil; window.close() }
        try await settle(host)

        #expect(press(try #require(node(elements(host), id: "week-plan-edit"))))
        try await settle(host)
        let editor = try #require(textViews(host).first { $0.isEditable && !$0.isHidden })
        editor.string = "새 계획 한 줄\n둘째 줄"
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: editor)
        try await settle(host)
        #expect(press(try #require(node(elements(host), id: "week-plan-save"))))
        try await settle(host)
        let saved = try #require(store.weekPlans(inProject: "gamza").first { $0.weekStart == thisWeek })
        #expect(saved.plan == ["새 계획 한 줄", "둘째 줄"])
        #expect(store.weekPlans(inProject: "gamza").filter { $0.weekStart < thisWeek } == historyBefore,
                "past weeks stay untouched")

        // Results are derived from judged issues in this week; the card shows exactly those.
        let expected = ProjectWeek.results(issues: store.issues(inProject: "gamza"),
                                           milestones: store.milestones(inProject: "gamza"),
                                           weekStart: thisWeek)
        let shown = Set(elements(host).compactMap { value($0, "accessibilityIdentifier") as? String }
            .filter { $0.hasPrefix("week-result-") }.map { String($0.dropFirst("week-result-".count)) })
        #expect(shown == Set(expected.map(\.id.rawValue)))
        #expect(store.milestones(inProject: "gamza").allSatisfy { statusesBefore[$0.id] == $0.status },
                "completed issues never mark a milestone reached or change its status")
        try save(window, name: "project-overview-weekly-plan-light")
    }

    @Test func weeklyPlanEvidenceShowsBothWidthsAndThemes() async throws {
        _ = NSApplication.shared
        let store = SampleKnarrStore()
        var (window, host) = try open(store, project: "gamza", tab: .overview,
                                      size: NSSize(width: 1180, height: 960), dark: false)
        try await settle(host)
        try save(window, name: "overview-wide-light")
        window.contentView = nil; window.close()

        (window, host) = try open(store, project: "gamza", tab: .milestones,
                                  size: NSSize(width: 1180, height: 960), dark: true)
        try await settle(host)
        try save(window, name: "milestones-wide-dark")
        window.contentView = nil; window.close()

        (window, host) = try open(store, project: "gamza", tab: .overview,
                                  size: NSSize(width: 700, height: 640), dark: false)
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        try save(window, name: "overview-narrow-light")
    }

    /// The detail's own title, read by identifier so the list's row labels cannot satisfy it.
    private func shownDetail(_ host: NSView) -> String? {
        let nodes = elements(host)
        if let node = nodes.first(where: { (value($0, "accessibilityIdentifier") as? String) == "milestone-detail-title" }) {
            if let label = value(node, "accessibilityLabel") as? String { return label }
            if let raw = value(node, "accessibilityValue") as? String { return raw }
        }
        return nil
    }

    private func allText(_ host: NSView) -> [String] {
        elements(host).flatMap { [$0, value($0, "accessibilityValue"), value($0, "accessibilityLabel")] }
            .compactMap { $0 as? String }
    }

    @Test func narrowWindowKeepsListAndDetailReachable() async throws {
        _ = NSApplication.shared
        let store = SampleKnarrStore()
        let tab = BindingBox(ProjectTab.milestones)
        let (window, host) = try open(store, project: "gamza", tab: .milestones,
                                      size: NSSize(width: 700, height: 640), dark: false, currentTab: tab)
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        let nodes = elements(host)
        let shown = nodes.flatMap { [$0, value($0, "accessibilityValue"), value($0, "accessibilityLabel")] }
            .compactMap { $0 as? String }
        #expect(shown.contains { $0.contains("대화 반복 제거") })
        #expect(shown.contains { $0.contains("저장된 주간 기록") })
        #expect(node(nodes, label: "이슈 만들기") != nil)
        try save(window, name: "milestones-narrow-light")
        // Weekly planning moved to the project: the overview keeps it reachable at this width.
        tab.value = .overview
        try await settle(host)
        let overview = allText(host)
        #expect(overview.contains { $0.contains("이번 주 계획") })
        #expect(overview.contains { $0.contains("이번 주 결과") })
        #expect(overview.contains { $0.contains("현재 마일스톤") })
        try save(window, name: "overview-narrow-from-milestones")
    }

    private func save(_ window: NSWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["KNARR_WINDOW_SCREENSHOTS"], let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
