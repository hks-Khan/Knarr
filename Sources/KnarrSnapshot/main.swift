import AppKit
import SwiftUI
import KnarrCore
import KnarrUI

// Renders the home screen with sample data to PNG files for design review.
// Usage: swift run knarr-snapshot [output-directory] [shot-name ...] (no names renders all)
// Project panel smoke: swift run knarr-snapshot <directory> project-panel-resize-smoke
if CommandLine.arguments.contains("--help") {
    print("""
    Usage: swift run knarr-snapshot [output-directory] [shot-name ...]
    No shot names renders all static scenes. Each name selects one scene.
    Project resize scenes: project-panel-{wide,narrow,min,max}-{light,dark}
    Native AppKit event + fresh-process preferences smoke:
      swift run knarr-snapshot <output-directory> project-panel-resize-smoke
      swift run knarr-snapshot <output-directory> issue-panel-resize-smoke
    The smoke uses sample data and isolated preferences, writes JSON/PNG, and launches
    project-panel-resize-restore / issue-panel-resize-restore internally. Events are synthetic
    NSWindow events, not OS/CUA.
    """)
    exit(0)
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "outputs/snapshots", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let selectedShots = Set(CommandLine.arguments.dropFirst(2))
func selected(_ name: String) -> Bool { selectedShots.isEmpty || selectedShots.contains(name) }

struct Shot {
    var name: String
    var opened: Issue.ID? = nil
    var dark = false
    var responding = false
    var text = ""
    var stopped = false
    var size = NSSize(width: 1440, height: 900)
    var page = HomePage.conversation
    var project: String? = nil
    var tab = "overview"
    var board = false
    var approvalPreview = false
    var scene: DesignScene? = nil
    var closedIssues = false
    var extensionUI: Question.ReplyStyle? = nil
    var extensionReload = false
    var issueSessionScene: IssueSessionScene? = nil
    var threadBadgeScene: ThreadBadgeScene? = nil
    var issueStatusScene = false
    var stallariWorkScene: StallariWorkScene? = nil
    var projectSessionScene: ProjectSessionScene? = nil
    var milestoneScene: MilestoneScene? = nil
    var preferredPanelWidth: Double? = nil
    var preferredIssuePanelWidth: Double? = nil
    var panelTitle: String? = nil
    var expandedIssueRecords = false
    /// Click the focused-conversation card before capturing, as a reader would.
    var canvasExpanded = false
    /// Queue another conversation behind the sample answer so the canvas must explain why stop is unavailable.
    var canvasStopBlocked = false
    var stageProgressPreview = false
}
let nestedScrollMarkdown = """
> [!NOTE] 스크롤·행 높이 확인
> 이 안내와 표·코드는 각각의 행 안에 있어야 합니다.

| 항목 | 세부 내용 | 상태 |
| --- | --- | --- |
| 가로 스크롤 | \(String(repeating: "표의 긴 내용 ", count: 12)) | 확인 |
| 세로 스크롤 | 표 위에서도 대화를 위아래로 이동 | 확인 |
| 행 높이 | 코드 마지막 줄과 다음 메시지 보존 | 확인 |

```swift
let wideLine = "\(String(repeating: "긴 코드 ", count: 24))"
let secondLine = 2
let thirdLine = 3
// 코드 마지막 줄
```

본문 마지막 줄
"""
let shots: [Shot] = [
    .init(name: "home-light"),
    .init(name: "issue-stages-light", stageProgressPreview: true),
    .init(name: "issue-stages-dark", dark: true, stageProgressPreview: true),
    .init(name: "issue-stages-drawer-light", opened: "npc-repeat", stageProgressPreview: true),
    .init(name: "issue-stages-drawer-dark", opened: "npc-repeat", dark: true, stageProgressPreview: true),
    .init(name: "threads-light", issueSessionScene: .tabs),
    .init(name: "threads-drawer-dark", opened: "npc-repeat", dark: true, issueSessionScene: .tabs),
    // Unread counts on the main tab and two project tabs, one of them also working.
    .init(name: "thread-badges-light", responding: true, threadBadgeScene: .unread),
    .init(name: "thread-badges-dark", dark: true, responding: true, threadBadgeScene: .unread),
    .init(name: "home-drawer-question-light", opened: "npc-repeat"),
    .init(name: "home-dark", dark: true),
    .init(name: "stallari-extensions-light", extensionUI: .confirm),
    .init(name: "stallari-extensions-editor-dark", dark: true, extensionUI: .editor),
    .init(name: "stallari-extensions-reloading", extensionUI: .confirm, extensionReload: true),
    .init(name: "approval-card-light", approvalPreview: true),
    .init(name: "approval-drawer-light", opened: "qa-approval", approvalPreview: true),
    .init(name: "approval-card-dark", dark: true, approvalPreview: true),
    .init(name: "home-drawer-input-dark", opened: "testflight", dark: true),
    .init(name: "response-wait-light", responding: true),
    .init(name: "response-streaming-dark", dark: true, responding: true, text: "작업 기록을 확인하고 있어요.\n\n확인된 결과부터 정리하겠습니다."),
    .init(name: "response-stopped-light", stopped: true),
    // Minimum-window cards and a mid-size drawer must preserve the transcript and composer.
    .init(name: "home-minimum-window-light", size: NSSize(width: 720, height: 540)),
    .init(name: "home-drawer-narrow-light", opened: "npc-repeat", size: NSSize(width: 900, height: 640)),
    .init(name: "chat-nested-scroll-narrow", responding: true, text: nestedScrollMarkdown, size: NSSize(width: 720, height: 900)),
    .init(name: "chat-nested-scroll-wide", responding: true, text: nestedScrollMarkdown),
    // The 프로젝트 page, one shot per tab.
    .init(name: "projects-overview-light", page: .projects, project: "gamza"),
    .init(name: "projects-overview-dark", dark: true, page: .projects, project: "gamza"),
    .init(name: "projects-issues-light", page: .projects, project: "gamza", tab: "issues"),
    .init(name: "projects-board-dark", dark: true, page: .projects, project: "gamza", tab: "issues", board: true),
    .init(name: "projects-runs-light", page: .projects, project: "gamza", tab: "runs"),
    .init(name: "projects-guide-light", page: .projects, project: "knarr", tab: "guide"),
    .init(name: "projects-guide-empty-dark", dark: true, page: .projects, project: "soomcha", tab: "guide"),
    .init(name: "projects-settings-light", page: .projects, project: "soomcha", tab: "settings"),
    .init(name: "projects-archived-light", page: .projects, project: "aquach"),
    .init(name: "projects-overview-no-milestones-light", page: .projects, project: "soomcha"),
    .init(name: "projects-overview-blocked-light", page: .projects, project: "gamza", milestoneScene: .blocked),
    .init(name: "projects-overview-blocked-dark", dark: true, page: .projects, project: "gamza", milestoneScene: .blocked),
    .init(name: "projects-overview-all-reached-light", page: .projects, project: "gamza", milestoneScene: .allReached),
    .init(name: "projects-overview-all-reached-dark", dark: true, page: .projects, project: "gamza", milestoneScene: .allReached),
    .init(name: "projects-overview-narrow-light", size: NSSize(width: 900, height: 900), page: .projects, project: "gamza"),
    .init(name: "projects-milestones-light", page: .projects, project: "gamza", tab: "milestones"),
    .init(name: "projects-milestones-history-light", page: .projects, project: "gamza", tab: "milestones", milestoneScene: .history),
    .init(name: "projects-milestones-history-dark", dark: true, page: .projects, project: "gamza", tab: "milestones", milestoneScene: .history),
    .init(name: "projects-milestones-blocked-light", page: .projects, project: "gamza", tab: "milestones", milestoneScene: .blocked),
    .init(name: "projects-milestones-all-reached-light", page: .projects, project: "gamza", tab: "milestones", milestoneScene: .allReached),
    .init(name: "projects-milestones-dark", dark: true, page: .projects, project: "gamza", tab: "milestones"),
    .init(name: "projects-milestones-empty-light", page: .projects, project: "soomcha", tab: "milestones"),
    .init(name: "projects-milestones-empty-dark", dark: true, page: .projects, project: "soomcha", tab: "milestones"),
    .init(name: "projects-milestones-narrow-light", size: NSSize(width: 900, height: 640), page: .projects, project: "gamza", tab: "milestones"),
    .init(name: "projects-milestones-narrow-dark", dark: true, size: NSSize(width: 900, height: 640), page: .projects, project: "gamza", tab: "milestones"),
    .init(name: "projects-drawer-light", opened: "testflight", page: .projects, project: "gamza"),
    .init(name: "projects-narrow-light", size: NSSize(width: 900, height: 640), page: .projects, project: "gamza"),
    // Design review scenes: chat elements, issue states and the detail drawer.
    .init(name: "design-chat-callouts-light", size: NSSize(width: 1440, height: 1180), scene: .chatCallouts),
    .init(name: "design-chat-callouts-dark", dark: true, size: NSSize(width: 1440, height: 1180), scene: .chatCallouts),
    .init(name: "design-chat-tables-light", size: NSSize(width: 1440, height: 1180), scene: .chatTables),
    .init(name: "design-chat-tables-dark", dark: true, size: NSSize(width: 1440, height: 1180), scene: .chatTables),
    .init(name: "design-issues-light", scene: .issues, closedIssues: true),
    .init(name: "design-issues-dark", dark: true, scene: .issues, closedIssues: true),
    .init(name: "design-drawer-light", opened: SampleKnarrStore.designDrawerIssue, scene: .issues, closedIssues: true),
    .init(name: "design-drawer-dark", opened: SampleKnarrStore.designDrawerIssue, dark: true, scene: .issues, closedIssues: true),
    // The issue detail beside the conversation: default, dragged wider, and a window too narrow to split.
    .init(name: "issue-panel-default-light", opened: SampleKnarrStore.designDrawerIssue, scene: .issues, closedIssues: true),
    .init(name: "issue-panel-wide-light", opened: SampleKnarrStore.designDrawerIssue, scene: .issues, closedIssues: true,
          preferredIssuePanelWidth: 760),
    .init(name: "issue-panel-narrow-light", opened: SampleKnarrStore.designDrawerIssue, size: NSSize(width: 900, height: 640),
          scene: .issues, closedIssues: true),
    .init(name: "issue-panel-max-light", opened: SampleKnarrStore.designDrawerIssue, scene: .issues, closedIssues: true,
          preferredIssuePanelWidth: 864),
    .init(name: "issue-panel-markdown-light", opened: SampleKnarrStore.designDrawerIssue, scene: .issues, closedIssues: true,
          preferredIssuePanelWidth: 760, expandedIssueRecords: true),
    .init(name: "issue-sessions-main-light", issueSessionScene: .main),
    .init(name: "issue-sessions-main-dark", dark: true, issueSessionScene: .main),
    .init(name: "issue-sessions-question-light", issueSessionScene: .question),
    .init(name: "issue-sessions-question-dark", dark: true, issueSessionScene: .question),
    .init(name: "issue-sessions-approval-light", issueSessionScene: .approval),
    .init(name: "issue-sessions-approval-dark", dark: true, issueSessionScene: .approval),
    .init(name: "issue-sessions-completed-light", issueSessionScene: .completed),
    .init(name: "issue-sessions-completed-dark", dark: true, issueSessionScene: .completed),
    .init(name: "issue-sessions-conversation-light", issueSessionScene: .conversation),
    .init(name: "issue-sessions-conversation-dark", dark: true, issueSessionScene: .conversation),
    .init(name: "issue-sessions-history-light", page: .history, issueSessionScene: .history),
    .init(name: "issue-sessions-history-dark", dark: true, page: .history, issueSessionScene: .history),
    .init(name: "issue-status-cards-light", size: NSSize(width: 1440, height: 1600), issueStatusScene: true),
    .init(name: "issue-status-cards-dark", dark: true, size: NSSize(width: 1440, height: 1600), issueStatusScene: true),
    .init(name: "issue-status-projects-light", page: .projects, project: "issue-status", issueStatusScene: true),
    .init(name: "issue-status-projects-dark", dark: true, page: .projects, project: "issue-status", issueStatusScene: true),
    .init(name: "issue-status-history-light", page: .history, issueStatusScene: true),
    .init(name: "issue-status-history-dark", dark: true, page: .history, issueStatusScene: true),
    .init(name: "issue-tabs-main-light", issueSessionScene: .tabs),
    .init(name: "issue-tabs-main-dark", dark: true, issueSessionScene: .tabs),
    .init(name: "issue-tabs-single-light", issueSessionScene: .singleHird),
    .init(name: "issue-tabs-single-dark", dark: true, issueSessionScene: .singleHird),
    .init(name: "issue-tabs-multiple-light", issueSessionScene: .multipleHirds),
    .init(name: "issue-tabs-multiple-dark", dark: true, issueSessionScene: .multipleHirds),
    .init(name: "stallari-work-single-light", stallariWorkScene: .single),
    .init(name: "stallari-work-single-dark", dark: true, stallariWorkScene: .single),
    .init(name: "stallari-work-multi-light", stallariWorkScene: .multiple),
    .init(name: "stallari-work-multi-dark", dark: true, stallariWorkScene: .multiple),
    .init(name: "project-tabs-light", projectSessionScene: .open),
    .init(name: "project-tabs-dark", dark: true, projectSessionScene: .open),
    .init(name: "project-session-panel-open-light", page: .projects, project: "gamza", projectSessionScene: .open),
    .init(name: "project-session-panel-open-dark", dark: true, page: .projects, project: "gamza", projectSessionScene: .open),
    .init(name: "project-session-panel-closed-light", page: .projects, project: "gamza", projectSessionScene: .closed),
    .init(name: "project-session-panel-closed-dark", dark: true, page: .projects, project: "gamza", projectSessionScene: .closed),
    .init(name: "project-session-with-cards-light", page: .projects, project: "gamza", projectSessionScene: .withCards),
    .init(name: "project-session-with-cards-dark", dark: true, page: .projects, project: "gamza", projectSessionScene: .withCards),
    .init(name: "project-panel-wide-light", size: NSSize(width: 1720, height: 900), page: .projects, project: "gamza", projectSessionScene: .open, preferredPanelWidth: 640),
    .init(name: "project-panel-wide-dark", dark: true, size: NSSize(width: 1720, height: 900), page: .projects, project: "gamza", projectSessionScene: .open, preferredPanelWidth: 640),
    .init(name: "project-panel-narrow-light", size: NSSize(width: 720, height: 540), page: .projects, project: "gamza", projectSessionScene: .open, preferredPanelWidth: 640),
    .init(name: "project-panel-narrow-dark", dark: true, size: NSSize(width: 720, height: 540), page: .projects, project: "gamza", projectSessionScene: .open, preferredPanelWidth: 640),
    .init(name: "project-panel-min-light", size: NSSize(width: 1720, height: 900), page: .projects, project: "gamza", projectSessionScene: .open, preferredPanelWidth: 360, panelTitle: String(repeating: "매우 긴 프로젝트 대화 제목 ", count: 4)),
    .init(name: "project-panel-min-dark", dark: true, size: NSSize(width: 1720, height: 900), page: .projects, project: "gamza", projectSessionScene: .open, preferredPanelWidth: 360, panelTitle: String(repeating: "매우 긴 프로젝트 대화 제목 ", count: 4)),
    .init(name: "project-panel-max-light", page: .projects, project: "gamza", projectSessionScene: .open, preferredPanelWidth: 2000),
    .init(name: "project-panel-max-dark", dark: true, page: .projects, project: "gamza", projectSessionScene: .open, preferredPanelWidth: 2000),
    .init(name: "project-transfer-pending-light", page: .projects, project: "gamza", projectSessionScene: .transferPending),
    .init(name: "project-transfer-source-light", page: .projects, project: "gamza", projectSessionScene: .transferSource),
    .init(name: "project-transfer-source-dark", dark: true, page: .projects, project: "gamza", projectSessionScene: .transferSource),
    .init(name: "project-transfer-main-light", projectSessionScene: .transferMain),
    .init(name: "project-transfer-main-dark", dark: true, projectSessionScene: .transferMain),
    // Focused conversations expanded in place: running, collapsed, and a narrow window.
    // `responding` matches the scene's live answer, so the canvas derives `stoppable` like the real store.
    .init(name: "conversation-canvas-open-light", responding: true, size: NSSize(width: 1440, height: 1180), scene: .conversationCanvas, canvasExpanded: true),
    .init(name: "conversation-canvas-open-dark", dark: true, responding: true, size: NSSize(width: 1440, height: 1180), scene: .conversationCanvas, canvasExpanded: true),
    .init(name: "conversation-canvas-collapsed-light", responding: true, size: NSSize(width: 1440, height: 1180), scene: .conversationCanvas),
    .init(name: "conversation-canvas-narrow-light", responding: true, size: NSSize(width: 900, height: 1000), scene: .conversationCanvas, canvasExpanded: true),
    // A short window: the panel must still show the original and a reply while the main transcript stays visible.
    .init(name: "conversation-canvas-short-light", responding: true, size: NSSize(width: 780, height: 620), scene: .conversationCanvas, canvasExpanded: true),
    // Another conversation queued behind the answer: stop is unavailable and the canvas says why.
    .init(name: "conversation-canvas-stop-blocked-light", responding: true, size: NSSize(width: 1440, height: 1180), scene: .conversationCanvas, canvasExpanded: true, canvasStopBlocked: true),
    // The main conversation after a report exists: the card carries the numbers and opens the detail.
    .init(name: "main-report-card-light", size: NSSize(width: 1440, height: 1180), scene: .reportCard),
    .init(name: "main-report-card-dark", dark: true, size: NSSize(width: 1440, height: 1180), scene: .reportCard),
    .init(name: "main-chat-layout-light", size: NSSize(width: 1440, height: 1180)),
    .init(name: "main-chat-layout-dark", dark: true, size: NSSize(width: 1440, height: 1180)),
    .init(name: "main-chat-layout-narrow-light", size: NSSize(width: 900, height: 1000)),
]

_ = NSApplication.shared
let issueStatusNow = Date()
for shot in shots where selected(shot.name) {
    let appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)!
    let store: SampleKnarrStore
    if shot.stageProgressPreview {
        store = SampleKnarrStore(stageProgressPreview: true, now: issueStatusNow)
    } else if shot.issueStatusScene {
        store = SampleKnarrStore(issueStatusScene: true, now: issueStatusNow)
    } else if let scene = shot.projectSessionScene {
        store = SampleKnarrStore(projectSessionScene: scene)
    } else if let scene = shot.milestoneScene {
        store = SampleKnarrStore(milestoneScene: scene)
    } else if let scene = shot.stallariWorkScene {
        store = SampleKnarrStore(stallariWorkScene: scene)
    } else if let scene = shot.threadBadgeScene {
        store = SampleKnarrStore(threadBadgeScene: scene)
    } else if let scene = shot.issueSessionScene {
        store = SampleKnarrStore(issueSessionScene: scene)
    } else if let scene = shot.scene {
        store = SampleKnarrStore(designScene: scene)
    } else if let style = shot.extensionUI {
        store = SampleKnarrStore(extensionPreview: style, reloading: shot.extensionReload)
    } else if shot.approvalPreview {
        store = SampleKnarrStore(qaProjectPath: out.deletingLastPathComponent().appendingPathComponent("project").path)
    } else {
        store = SampleKnarrStore()
    }
    if let title = shot.panelTitle {
        var values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.projectSessionPolicy)) as! [String: Any]
        values["panelTitle"] = title
        store.projectSessionPolicy = try JSONDecoder().decode(ProjectSessionPolicy.self, from: JSONSerialization.data(withJSONObject: values))
    }
    store.isResponding = shot.responding || shot.stopped
    store.streamingText = shot.text
    if shot.stopped { store.stopResponse() }
    if shot.canvasStopBlocked, !store.respondingConversationRoots.isEmpty {
        // Same shape as Live: the shown root answers while another conversation's reply is queued behind it.
        store.waitingConversationRoots = [UUID()]
    }
    let preferenceSuite = "knarr-snapshot-" + UUID().uuidString
    let preferences = UserDefaults(suiteName: preferenceSuite)!
    defer { preferences.removePersistentDomain(forName: preferenceSuite) }
    preferences.set(shot.tab, forKey: "knarr.projectTab")
    preferences.set(shot.board, forKey: "knarr.projectBoard")
    preferences.set(shot.closedIssues, forKey: "knarr.showClosedIssues")
    preferences.set(false, forKey: "knarr.issueCardsCollapsed")
    if let scene = shot.projectSessionScene {
        preferences.set(scene == .closed, forKey: "knarr.projectSessionCollapsed.gamza")
    }
    if let width = shot.preferredPanelWidth {
        preferences.set(width, forKey: "knarr.projectSessionWidth")
    }
    if let width = shot.preferredIssuePanelWidth {
        preferences.set(width, forKey: "knarr.issuePanelWidth")
    }
    let view = HomeView(store: store, opened: shot.opened, page: shot.page, project: shot.project)
        .frame(width: shot.size.width, height: shot.size.height)
        .defaultAppStorage(preferences)
        .environment(\.chatWebPreferences, preferences)
        .environment(\.colorScheme, shot.dark ? .dark : .light)

    // Host in an offscreen window so AppKit-backed controls draw like they do in the app.
    let host = NSHostingView(rootView: view)
    host.appearance = appearance
    host.frame = NSRect(origin: .zero, size: shot.size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    host.layoutSubtreeIfNeeded()
    // The transcript measures row heights after mounting; a tall message needs a few passes before it is final.
    let steps = shot.scene == nil && shot.issueSessionScene == nil && !shot.issueStatusScene &&
        shot.stallariWorkScene == nil && shot.projectSessionScene == nil && shot.milestoneScene == nil &&
        !shot.stageProgressPreview ? 1 : 8
    for _ in 0..<steps {
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
    }
    if shot.expandedIssueRecords { try IssueCardMenuSmoke.expandIssueRecords(in: host) }

    let webSurfaces = try WebSnapshot.prepare(host)
    var expanded = false
    if shot.canvasExpanded {
        try WebSnapshot.expandCanvas(host)
        host.layoutSubtreeIfNeeded()
        expanded = true
    }
    // The earlier capture predates the canvas; take the surface again after expansion.
    let finalSurfaces = expanded ? try WebSnapshot.prepare(host) : webSurfaces
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap for \(shot.name)") }
    appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
    WebSnapshot.composite(finalSurfaces, host: host, bitmap: rep)
    let file = out.appendingPathComponent("\(shot.name).png")
    try rep.representation(using: .png, properties: [:])!.write(to: file)
    print(file.path)
}

if selectedShots.contains("project-panel-resize-smoke") {
    try ProjectPanelSmoke.run(out: out, restore: false)
}
if selectedShots.contains("project-panel-resize-restore") {
    try ProjectPanelSmoke.run(out: out, restore: true)
}
// Issue detail: native splitter drag, the narrow-window overlay, and a fresh-process width restore.
if selectedShots.contains("issue-panel-resize-smoke") {
    try IssuePanelWidthSmoke.run(out: out, restore: false)
}
if selectedShots.contains("issue-panel-resize-restore") {
    try IssuePanelWidthSmoke.run(out: out, restore: true)
}
// Explicit internal lifecycle faults never enter the normal six-scenario success contract.
if let mode = CommandLine.arguments.dropFirst(2).first, mode.hasPrefix("issue-card-menu-") {
    do {
        switch mode {
        case "issue-card-menu-smoke":
            try IssueCardMenuSmoke.supervise(out: out)
        case "issue-card-menu-internal-fault":
            guard let fault = CommandLine.arguments.last, IssueCardMenuSmoke.faults.contains(fault) else {
                throw IssueCardMenuSmoke.Failure(description: "Missing internal menu fault")
            }
            try IssueCardMenuSmoke.supervise(out: out, fault: fault)
        case "issue-card-menu-worker":
            let arguments = Array(CommandLine.arguments.dropFirst(3))
            let context = try MenuSmokeLifetime.authorizeChild(out: out, role: "worker")
            guard (1...2).contains(arguments.count), let suite = arguments.first, suite == context.suite,
                  (arguments.count == 2 ? arguments[1] : nil) == context.fault else {
                throw IssueCardMenuSmoke.Failure(description: "Missing isolated menu suite")
            }
            if arguments.count == 2 {
                try IssueCardMenuSmoke.runFault(out: out, suite: suite, fault: arguments[1])
            } else {
                try IssueCardMenuSmoke.run(out: out, suite: suite)
            }
        case "issue-card-menu-internal-capture":
            _ = try MenuSmokeLifetime.authorizeChild(out: out, role: "capture")
            try IssueCardMenuSmoke.stalledCapture(out: out)
        case "issue-card-menu-internal-reclaim":
            _ = try MenuSmokeLifetime.reclaim(out: out, external: true, reason: "externalDeadlineOrDefer")
        default:
            throw IssueCardMenuSmoke.Failure(description: "Unknown internal menu command")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("MENU FAILURE: \(error)\n".utf8))
        exit(1)
    }
}

// The Markdown showcase, light and dark, at its natural height.
for dark in [false, true] where selected("markdown-\(dark ? "dark" : "light")") {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let host = NSHostingView(rootView: MarkdownDocument(MarkdownDocument.showcase).environment(\.colorScheme, dark ? .dark : .light))
    host.appearance = appearance
    host.frame = NSRect(x: 0, y: 0, width: 796, height: 10)
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap for markdown") }
    appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
    let file = out.appendingPathComponent("markdown-\(dark ? "dark" : "light").png")
    try rep.representation(using: .png, properties: [:])!.write(to: file)
    print(file.path)
}

// Exact shared MenuBarExtra/header detail content, with explicitly synthetic quota states.
let usageNow: Int64 = 1_791_824_400
let sampleUsage = SampleKnarrStore(now: Date(timeIntervalSince1970: TimeInterval(usageNow))).subscriptionUsage
let staleUsage = SubscriptionUsageModel(clock: { usageNow },
    claude: .init(fiveHour: .init(usedPercent: 93, resetsAt: usageNow + 3600), weekly: nil, capturedAt: usageNow - 600),
    codex: .init(fiveHour: .init(usedPercent: 75, resetsAt: usageNow - 1), weekly: .init(usedPercent: 32, resetsAt: usageNow + 86400), capturedAt: usageNow - 600),
    sample: true)
for (name, usage) in [("usage-menu", sampleUsage), ("usage-stale-reset", staleUsage),
                       ("usage-unavailable", SubscriptionUsageModel(clock: { usageNow }, sample: true))] {
    for dark in [false, true] where selected("\(name)-\(dark ? "dark" : "light")") {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: MenuBarUsageView(usage: usage).environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = appearance
        host.frame = NSRect(x: 0, y: 0, width: 342, height: 540)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance; window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no usage bitmap") }
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        let file = out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        try rep.representation(using: .png, properties: [:])!.write(to: file)
        window.contentView = nil; window.close()
        print(file.path)
    }
}

// Exact permission guidance used by Settings; no native center is touched by snapshots.
if selected("settings-instructions-light") || selected("settings-instructions-dark") {
    let store = SampleKnarrStore()
    for dark in [false, true] where selected("settings-instructions-\(dark ? "dark" : "light")") {
        let view = SettingsSheet(store: store, previewHeight: 1600)
            .frame(width: 560, height: 1600)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 1600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded() }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.appearance!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        let file = out.appendingPathComponent("settings-instructions-\(dark ? "dark" : "light").png")
        try rep.representation(using: .png, properties: [:])!.write(to: file)
        print(file.path)
        window.contentView = nil; window.close()
    }
}

for dark in [false, true] where selected("notification-settings-\(dark ? "dark" : "light")") {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let host = NSHostingView(rootView: DesktopNotificationSettings(status: .denied)
        .padding(24).frame(width: 520, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light))
    host.appearance = appearance
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance; window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no notification bitmap") }
    appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
    let file = out.appendingPathComponent("notification-settings-\(dark ? "dark" : "light").png")
    try rep.representation(using: .png, properties: [:])!.write(to: file)
    window.contentView = nil; window.close()
    print(file.path)
}
// Auto install switch states: on with a live line, waiting, and a build failure.
for (scene, enabled, status) in [("current", true, AutoInstallPolicy.current.status("current", ["installed": "ec489d3", "main": "ec489d3"])),
                                 ("waiting", true, AutoInstallPolicy.current.status("waiting", ["installed": "ec489d3", "main": "4a91b2c"])),
                                 ("failed", true, AutoInstallPolicy.current.status("failed", ["reason": AutoInstallPolicy.current.reason("signature")])),
                                 ("off", false, AutoInstallPolicy.current.status("off"))] {
    for dark in [false, true] where selected("auto-install-settings-\(scene)-\(dark ? "dark" : "light")") {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: AutoInstallSettings(policy: AutoInstallPolicy.current,
            enabled: enabled, status: status, setEnabled: { _ in })
            .padding(24).frame(width: 520, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance; window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no auto install bitmap") }
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        let file = out.appendingPathComponent("auto-install-settings-\(scene)-\(dark ? "dark" : "light").png")
        try rep.representation(using: .png, properties: [:])!.write(to: file)
        window.contentView = nil; window.close()
        print(file.path)
    }
}

let label = MenuBarUsageLabel.render(sampleUsage.headlines)
let labelRenderer = ImageRenderer(content: Image(nsImage: label).padding(8).background(Color.white))
labelRenderer.scale = 2
if selected("usage-menu-label"), let tiff = labelRenderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
    let file = out.appendingPathComponent("usage-menu-label.png")
    try rep.representation(using: .png, properties: [:])!.write(to: file)
    print(file.path)
}
