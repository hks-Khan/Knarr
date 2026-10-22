import AppKit
import Observation
import SwiftUI
import Testing
@testable import KnarrCore
@testable import KnarrUI

/// No live runtime, credentials, provider calls or writes to the inspected repository.
@MainActor @Observable private final class DocumentWindowStore: KnarrStore {
    let sample = SampleKnarrStore()
    let root: URL
    var didReadResults = false
    init(root: URL) { self.root = root; sample.addProject(path: root.path) }
    var projects: [ProjectSummary] { [.init(id: root.path, name: "숨차", path: root.path, openIssues: 0)] }
    var stallari: StallariInfo { sample.stallari }
    var threads: [ConversationThread] { sample.threads }
    var selectedThreadID: String { sample.selectedThreadID }
    var conversationTabs: [ConversationThread] { sample.conversationTabs }
    var subscriptionUsage: SubscriptionUsageModel { sample.subscriptionUsage }
    var chat: [ChatItem] { sample.chat }
    var stallariWork: [SubagentWork] { sample.stallariWork }
    var extensionPresentation: ExtensionPresentation { sample.extensionPresentation }
    var projectSessionPolicy: ProjectSessionPolicy { sample.projectSessionPolicy }
    func dismissExtensionToast() { sample.dismissExtensionToast() }
    var isResponding: Bool { false }
    var streamingText: String { "" }
    var issues: [KnarrCore.Issue] { [] }
    var models: [String] { [] }
    var model: String? { nil }
    var storageBytes: Int64? { nil }
    var questions: [Question] { [] }
    var composerDraft: ChatDraft { get { sample.composerDraft } set { sample.composerDraft = newValue } }
    func closeConversationTab(_ id: String) { sample.closeConversationTab(id) }
    func createThread(name: String) { sample.createThread(name: name) }
    func selectThread(_ id: String) { sample.selectThread(id) }
    func selectProjectConversation(_ id: String) { sample.selectProjectConversation(id) }
    func renameThread(_ id: String, to name: String) { sample.renameThread(id, to: name) }
    func goToThread(for issue: KnarrCore.Issue.ID) { sample.goToThread(for: issue) }
    func isThreadWorking(_ threadID: String) -> Bool { false }
    func send(_ text: String, about: KnarrCore.Issue.ID?, project: String?, attachments: [URL]) {
        sample.send(text, about: about, project: project, attachments: attachments)
    }
    func steer(_ text: String, issue: KnarrCore.Issue.ID) { sample.steer(text, issue: issue) }
    func perform(_ action: IssueAction, on issue: KnarrCore.Issue.ID) { sample.perform(action, on: issue) }
    func answer(_ question: Question.ID, with answer: QuestionAnswer) { sample.answer(question, with: answer) }
    func cancel(_ question: Question.ID) { sample.cancel(question) }
    func addProject(path: String) { sample.addProject(path: path) }
    func issues(inProject id: String) -> [KnarrCore.Issue] { [] }
    func inspectProject(_ id: String) async -> ProjectInspection { await ProjectGit.inspect(root) }
    func inspectProjectMergeResults(_ id: String) async -> ProjectMergeResults {
        let results = await ProjectMergeResults.read(root: root, issues: [])
        didReadResults = true
        return results
    }
    func renameProject(_ id: String, to name: String) { sample.renameProject(id, to: name) }
    func setProjectArchived(_ id: String, _ archived: Bool) { sample.setProjectArchived(id, archived) }
    func updateProjectSettings(_ id: String, _ settings: ProjectSettings) { sample.updateProjectSettings(id, settings) }
    func saveAgentsFile(_ id: String, text: String, expected: String?) async throws {
        throw StallariError.rejectedEvidence("읽기 전용 화면 검증이에요")
    }
    func selectModel(_ model: String) { sample.selectModel(model) }
    func cleanFinishedWorkspaces() { sample.cleanFinishedWorkspaces() }
}

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ProjectDocumentsWindowTests {
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

    @Test(arguments: [false, true]) func documentActionsKeepDraftUnsentAndRenderActualProject(dark: Bool) async throws {
        _ = NSApplication.shared
        let configured = ProcessInfo.processInfo.environment["KNARR_PROJECT_DOCUMENT_ROOT"]
        let root = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("knarr-document-window-\(UUID())")
        if configured == nil {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("docs/design"), withIntermediateDirectories: true)
            try "# 숨차 세계관·게임 설계\n\n## 세계관 개요\n\n문서 읽기 검증".write(
                to: root.appendingPathComponent("docs/design/world-design.md"), atomically: true, encoding: .utf8)
        }
        defer { if configured == nil { try? FileManager.default.removeItem(at: root) } }
        let store = DocumentWindowStore(root: root)
        let project = try #require(store.projects.first)
        let documents = ProjectDocumentsModel()
        documents.selectedPath = "docs/design/world-design.md"
        let window = TestWindow.make(size: NSSize(width: 1180, height: 960), dark: dark)
        let tab = BindingBox(ProjectTab.documents)
        window.contentView = NSHostingView(rootView: ProjectDetail(store: store, project: project,
            tab: Binding(get: { tab.value }, set: { tab.value = $0 }), issueFilter: .constant(.all),
            open: { _ in }, talk: { store.selectProjectConversation($0) },
            request: { ProjectConversationRequest.prepare(store: store, projectID: project.id, text: $0) },
            documents: documents).environment(\.colorScheme, dark ? .dark : .light))
        TestWindow.present(window)
        defer { window.contentView = nil; window.close() }
        let content = try #require(window.contentView)
        for _ in 0..<500 {
            content.layoutSubtreeIfNeeded()
            if !documents.loading && documents.selected?.relativePath == "docs/design/world-design.md" && !documents.blocks.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(documents.selected?.relativePath == "docs/design/world-design.md")
        content.layoutSubtreeIfNeeded()
        let nodes = elements(content)
        let shown = nodes.flatMap { [$0, value($0, "accessibilityValue"), value($0, "accessibilityLabel")] }
            .compactMap { $0 as? String }
        #expect(shown.contains { $0.contains("docs/design/world-design.md") })
        #expect(shown.contains { $0.contains("숨차 세계관") })
        let ask = try #require(nodes.first { value($0, "accessibilityLabel") as? String == "Stallari에게 묻기" })
        let action = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        #expect(ask.responds(to: action))
        #expect(unsafeBitCast(ask.method(for: action), to: Press.self)(ask, action))
        #expect(store.composerDraft.text == "docs/design/world-design.md")
        #expect(store.threads.first { $0.id == store.selectedThreadID }?.projectID == project.id)
        #expect(!store.chat.contains { $0.kind == .user("docs/design/world-design.md") })
        try save(window, name: "project-documents-\(dark ? "dark" : "light")")
        tab.value = .overview
        for _ in 0..<500 {
            content.layoutSubtreeIfNeeded()
            if store.didReadResults { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.didReadResults)
        try await Task.sleep(for: .milliseconds(100))
        content.layoutSubtreeIfNeeded()
        let overview = elements(content)
        try save(window, name: "project-overview-\(dark ? "dark" : "light")")
        let recent = try #require(documents.recent.first)
        let recentButton = try #require(overview.first {
            value($0, "accessibilityIdentifier") as? String == "project-recent-document-\(recent.relativePath)" && $0.responds(to: action)
        })
        #expect(unsafeBitCast(recentButton.method(for: action), to: Press.self)(recentButton, action))
        for _ in 0..<100 {
            if tab.value == .documents && documents.selected?.relativePath == recent.relativePath { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.value == .documents)
        #expect(documents.selected?.relativePath == recent.relativePath)
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

@MainActor @Observable final class BindingBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
