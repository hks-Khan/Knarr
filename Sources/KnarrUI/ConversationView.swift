import AppKit
import SwiftUI
import KnarrCore
import QuickLook

struct ConversationView: View {
    let store: any KnarrStore
    let open: (Issue.ID) -> Void
    var search: () -> Void = {}
    var focusRequest: UUID?
    var closeProjectPanel: (() -> Void)?
    /// Opens one generated report's detail in the record page.
    var openReport: ((String) -> Void)? = nil
    /// The detail shown beside this conversation, so its top card reads as selected.
    var selectedIssue: Issue.ID? = nil
    @Binding var scrollTarget: UUID?
    private var draft: String { store.composerDraft.text }
    private var attachments: [URL] { store.composerDraft.attachments }
    private var project: String? { lockedProjectID ?? store.composerDraft.project }
    private var lockedProjectID: String? { store.threads.first { $0.id == store.selectedThreadID }?.projectID }
    @State private var followsLatest = true
    @State private var jumpToLatest = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openMessageConversation) private var openMessageConversation
    @State private var inputError: String?
    @State private var previewURL: URL?
    @State private var highlighted: UUID?
    @State private var dropping = false
    @State private var composerFocused = false
    @State private var restoredDraftFocus: UUID?
    /// The project picked in the composer; nil talks about all projects.
    @State private var choosingProject = false
    @State private var transferSelection: ProjectTransferSelection?
    @State private var visibleTransfers: [ProjectTransfer] = []
    /// The issue list under the header; the header chip is its only disclosure control.
    @AppStorage("knarr.issueCardsCollapsed") private var cardsCollapsed = false
    /// Asks the transcript to expand a focused conversation in place; a separate window stays a header action.
    @State private var canvasRequest: MessageConversationCanvasRequest?
    /// A focused conversation panel is on screen, so native chrome yields height to it.
    @State private var canvasVisible = false
    /// The person reopened the main composer tools while a focused conversation is open.
    @State private var composerToolsExpanded = false

    private var projectIsReadOnly: Bool {
        lockedProjectID.flatMap { store.project($0) }?.archived == true
    }

    private func refreshTransfers() {
        if let projectID = lockedProjectID {
            visibleTransfers = store.projectTransfers.filter { $0.originProjectID == projectID && $0.originThreadID == store.selectedThreadID && $0.state != .delivered }
        } else if store.selectedThreadID == ConversationThread.defaultID && store.selectedIssue == nil {
            visibleTransfers = []
        } else {
            visibleTransfers = []
        }
    }

    private func navigateTransfer(_ transfer: ProjectTransfer, main: Bool) {
        if main {
            store.selectThread(ConversationThread.defaultID)
            scrollTarget = transfer.mainMessageID
        } else {
            store.selectThread(transfer.originThreadID)
            scrollTarget = transfer.requestMessageID
        }
    }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            header
            Divider().overlay(K.line)
            IssueCardsView(store: store, maximumHeight: canvasVisible ? min(geometry.size.height / 6, 160) : geometry.size.height / 2,
                           selected: selectedIssue,
                           open: open, collapsed: $cardsCollapsed)
            ProjectTransferCards(store: store, transfers: visibleTransfers, navigate: navigateTransfer,
                                 preview: { previewURL = $0 })
            if let error = store.assistantPersistenceError {
                HStack(alignment: .top, spacing: K.s2) {
                    Text("답변 저장 실패: " + error).font(K.secondary).foregroundStyle(K.red).textSelection(.enabled)
                    Spacer()
                    KButton(title: store.isRetryingAssistantPersistence ? "저장 중…" : "답변 저장 다시 시도",
                            style: .link, enabled: !store.isRetryingAssistantPersistence) {
                        Task { await store.retryAssistantPersistence() }
                    }
                }
                .padding(K.s3).accessibilityIdentifier("assistant-persistence-error")
            }
            ChatWebView(store: store, highlighted: highlighted ?? scrollTarget, following: followsLatest, jumpToLatest: jumpToLatest,
                        target: scrollTarget, open: open, restore: restore, preview: { previewURL = $0 },
                        followingChanged: { followsLatest = $0 }, targetReached: { scrollTarget = nil },
                        resend: stoppedRequest.map { draft in { submit(draft) } },
                        openConversation: { canvasRequest = .init(root: $0) },
                        openConversationWindow: openMessageConversation, canvasRequest: canvasRequest,
                        canvasVisibilityChanged: { canvasVisible = $0 },
                        openWorkReport: openReport,
                        navigateTransfer: navigateTransfer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest {
                        Button { followsLatest = true; jumpToLatest.toggle() } label: {
                            Image(systemName: "arrow.down").font(K.secondary.weight(.semibold)).foregroundStyle(K.ink)
                                .padding(K.s2).background(K.surface, in: Circle())
                                .overlay(Circle().strokeBorder(K.lineStrong)).floatingShadow()
                        }.buttonStyle(.plain).padding(K.s4).help("최신 메시지로 이동").accessibilityLabel("최신 메시지로 이동")
                    }
                }
                .onChange(of: scrollTarget) {
                    guard let target = scrollTarget else { return }
                    followsLatest = false
                    highlighted = target
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(Motion.smoothOut(Motion.verySlow)) { if highlighted == target { highlighted = nil } }
                    }
                }
            if store.issueConversationIsReadOnly || projectIsReadOnly {
                Text(projectIsReadOnly ? "보관한 프로젝트의 대화는 읽기 전용이에요" : "닫힌 이슈의 대화는 읽기 전용이에요")
                    .font(K.secondary).foregroundStyle(K.faint)
                    .padding(K.s4).frame(maxWidth: .infinity)
            } else {
                composer.disabled(store.extensionPresentation.isReloading)
            }
        }
        .background(K.surface)
        .overlay(alignment: .topTrailing) {
            if let toast = store.extensionPresentation.toast {
                HStack(alignment: .top, spacing: K.s2) {
                    Image(systemName: toast.tone == "error" ? "exclamationmark.circle" : "info.circle")
                        .foregroundStyle(toast.tone == "error" ? K.red : K.faint)
                    Text(toast.message).font(K.secondary).textSelection(.enabled)
                    Button(action: store.dismissExtensionToast) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("확장 알림 닫기")
                }
                .padding(K.s3).frame(maxWidth: 340, alignment: .leading)
                .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
                .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.lineStrong))
                .floatingShadow()
                .padding(.top, K.headerHeight + K.s5).padding(.trailing, K.s5)
                .accessibilityIdentifier("stallari-extension-toast")
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(5))
                    if !Task.isCancelled, store.extensionPresentation.toast?.id == toast.id { store.dismissExtensionToast() }
                }
            }
        }
        }
        .quickLookPreview($previewURL)
        .onAppear { refreshTransfers() }
        .onChange(of: store.projectTransfers) { refreshTransfers() }
        .onChange(of: store.selectedThreadID) { refreshTransfers() }
        .onChange(of: canvasVisible) {
            if !canvasVisible { composerToolsExpanded = false }
        }
        .onChange(of: focusRequest) { restoredDraftFocus = nil }
        .sheet(item: $transferSelection) { selection in
            ProjectTransferSheet(store: store, selection: selection)
        }
    }

    // MARK: Header

    /// One line: who, whether Hird is working, then the meters and search. A narrow conversation drops the
    /// meters first, then the status words, so nothing clips.
    private var header: some View {
        let scopedIssues = lockedProjectID.map { store.issues(inProject: $0) } ?? store.issues
        let working = scopedIssues.lazy.filter { $0.archivedAt == nil && $0.displayStatus == .inProgress }
            .flatMap(\.hirds).filter { $0.status == .working }.count
        return ViewThatFits(in: .horizontal) {
            headerRow(working: working, meters: true, statusWords: true)
            headerRow(working: working, meters: false, statusWords: true)
            headerRow(working: working, meters: false, statusWords: false)
        }
        .padding(.horizontal, K.s3)
        .frame(height: K.headerHeight)
    }

    private func headerRow(working: Int, meters: Bool, statusWords: Bool) -> some View {
        let cards = store.topIssueCards
        return HStack(spacing: K.s2) {
            Text("S").font(K.caption.weight(.semibold)).foregroundStyle(K.onInk)
                .frame(width: K.avatar, height: K.avatar).background(K.ink, in: Circle())
                .accessibilityHidden(true)
            Text(lockedProjectID == nil ? "Stallari" : store.projectSessionPolicy.panelTitle)
                .font(K.title).lineLimit(1).truncationMode(.tail).frame(minWidth: 0, alignment: .leading)
            if !cards.entries.isEmpty {
                issueChip(cards)
            }
            if working > 0 {
                Text("·").font(K.secondary).foregroundStyle(K.faint)
                HStack(spacing: K.s2) {
                    Circle().fill(K.accent).frame(width: K.dot, height: K.dot)
                    if statusWords { Text("Hird \(working)명 일하는 중").contentTransition(.numericText()).lineLimit(1) }
                }
                .font(K.secondary).foregroundStyle(K.muted)
                .fixedSize()
                .transition(.textSwap)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Hird \(working)명 일하는 중")
            }
            Spacer(minLength: K.s3)
            if meters { UsageSummaryButton(usage: store.subscriptionUsage, context: store.contextUsage) }
            // A main-window shortcut: sheets, popovers and Quick Look are their own windows and keep their keys.
            Group {
                if meters || statusWords { KButton(title: "대화 기록 검색", action: search) }
                else {
                    Button(action: search) { Image(systemName: "magnifyingglass").font(K.secondary).foregroundStyle(K.muted).frame(width: K.controlHeight, height: K.controlHeight) }
                        .buttonStyle(.plain).accessibilityLabel("대화 기록 검색")
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .help("대화 기록 검색 · ⌘F")
            if lockedProjectID != nil && !projectIsReadOnly && store.selectedIssue == nil {
                Menu {
                    Button("메인으로 전달…") {
                        transferSelection = ProjectTransferSelection.capture(store.chat, streamingID: store.streamingMessageID)
                    }
                    .disabled(store.isResponding || store.assistantPersistenceError != nil || store.chat.isEmpty)
                } label: {
                    Image(systemName: "arrow.up.forward.square").font(K.secondary).foregroundStyle(K.muted)
                        .frame(width: K.controlHeight, height: K.controlHeight)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("메인으로 전달").accessibilityLabel("메인으로 전달")
                .accessibilityIdentifier("project-transfer-menu")
            }
            if let closeProjectPanel, let projectID = lockedProjectID {
                Button(action: closeProjectPanel) {
                    Image(systemName: "xmark").font(K.secondary).foregroundStyle(K.muted)
                        .frame(width: K.controlHeight, height: K.controlHeight)
                }
                .buttonStyle(.plain).help(store.projectSessionPolicy.panelCloseLabel)
                .accessibilityLabel(store.projectSessionPolicy.panelCloseLabel)
                .accessibilityIdentifier("project-session-close-" + projectID)
            }
        }
        .animation(Motion.numberPop, value: working)
    }

    /// The one place the issue list is disclosed. It carries the answer count so the header needs no second row.
    private func issueChip(_ cards: IssueCards) -> some View {
        let answers = cards.answerCount
        return Button { cardsCollapsed.toggle() } label: {
            HStack(spacing: K.s1) {
                Image(systemName: cardsCollapsed ? "chevron.right" : "chevron.down").font(K.caption.weight(.semibold))
                Text(cards.issues.isEmpty ? "진행 중" : "이슈 \(cards.issues.count)").font(K.caption.weight(.medium))
                if answers > 0 {
                    Text("답변 필요 \(answers)").font(K.caption.weight(.medium)).foregroundStyle(K.amber)
                }
            }
            .foregroundStyle(K.muted)
            .padding(.horizontal, K.s2)
            .frame(height: K.chipHeight)
            .background(answers > 0 ? K.amberSoft : K.sunken, in: RoundedRectangle(cornerRadius: K.rSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("이슈 목록")
        .accessibilityLabel(cards.issues.isEmpty ? "진행 중 이슈 목록"
            : "이슈 \(cards.issues.count)개" + (answers > 0 ? ", 답변 필요 \(answers)개" : "") + " 목록")
        .accessibilityAddTraits(cardsCollapsed ? [] : .isSelected)
        .accessibilityIdentifier("issue-cards-disclosure")
    }

    // MARK: Composer

    @ViewBuilder private var extensionBand: some View {
        let state = store.extensionPresentation
        if state.isReloading || !state.statuses.isEmpty || !state.widgets.isEmpty {
            VStack(alignment: .leading, spacing: K.s2) {
                if state.isReloading { Label("확장 다시 불러오는 중", systemImage: "arrow.clockwise") }
                ForEach(state.statuses.keys.sorted(), id: \.self) { key in
                    Text(state.statuses[key] ?? "").textSelection(.enabled)
                }
                ForEach(state.widgets.keys.sorted(), id: \.self) { key in
                    Text((state.widgets[key] ?? []).joined(separator: "\n")).textSelection(.enabled)
                }
            }
            .font(K.secondary).foregroundStyle(K.muted)
            .padding(K.s3).frame(maxWidth: .infinity, alignment: .leading)
            .background(K.sunken, in: RoundedRectangle(cornerRadius: K.rSmall))
            .accessibilityIdentifier("stallari-extension-band")
        }
    }

    /// Progress copy for a send in flight or waiting behind the running answer.
    private var sendStatus: String? {
        if store.isSubmissionWaiting { return "답이 끝나면 보내요" }
        if store.isSubmitting { return "보내는 중" }
        return nil
    }

    /// The project chip, attach button and model control fold behind a disclosure while a focused
    /// conversation owns the height. The editor, send button, draft and accessibility nodes stay.
    private var showComposerTools: Bool { !canvasVisible || composerToolsExpanded }

    private var composer: some View {
        VStack(spacing: K.s2) {
            extensionBand
            if let inputError {
                Text(inputError).font(K.secondary).foregroundStyle(K.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let status = sendStatus {
                Text(status).font(K.secondary).foregroundStyle(K.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(status)
            }
            if let failed = store.failedDraft {
                HStack {
                    Text("전송한 내용을 다시 사용할 수 있어요").font(K.secondary).foregroundStyle(K.muted)
                    Spacer()
                    KButton(title: "불러오기", style: .link) { restore(failed) }
                    KButton(title: "다시 시도", style: .link, enabled: !store.isResponding) { submit(failed) }
                }
            }
            VStack(alignment: .leading, spacing: K.s2) {
                if !attachments.isEmpty { attachmentRow(attachments, removable: true) }
                MessageComposer(text: Binding(get: { draft }, set: { store.composerDraft.text = $0 }), onSubmit: { submit() },
                                onNewConversation: startConversation,
                                onFiles: addAttachments, onImage: pasteImage, onFocus: { composerFocused = $0 },
                                placeholder: lockedProjectID == nil ? nil : store.projectSessionPolicy.composerPlaceholder,
                                focusRequest: restoredDraftFocus ?? focusRequest)
                HStack(spacing: K.s2) {
                    // The project, attach and model controls fold behind one disclosure while a
                    // focused conversation is open, so the panel gets that height back. The editor,
                    // send button and draft keep working and keep their accessibility nodes.
                    if showComposerTools {
                        Button { choosingProject.toggle() } label: {
                            HStack(spacing: K.s1) {
                                Image(systemName: "folder").font(K.caption)
                                Text(store.projects.first { $0.id == project }?.name ?? "전체 프로젝트").font(K.caption).lineLimit(1)
                                if lockedProjectID == nil { Image(systemName: "chevron.down").font(K.caption.weight(.semibold)) }
                            }
                            .foregroundStyle(K.muted)
                            .padding(.horizontal, K.s2)
                            .frame(height: K.chipHeight)
                            .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.lineStrong))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(lockedProjectID != nil)
                        .accessibilityLabel("메시지를 보낼 프로젝트")
                        .popover(isPresented: $choosingProject, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 0) {
                                projectRow(nil, "전체 프로젝트")
                                Divider().overlay(K.line).padding(.vertical, K.s1)
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(store.projects.filter { !$0.archived }) { p in projectRow(p.id, p.name) }
                                    }
                                }
                                .frame(maxHeight: 320)
                            }
                            .padding(K.s1)
                            .frame(width: 240)
                        }
                        Button(action: attach) { Image(systemName: "plus").font(K.secondary).foregroundStyle(K.muted).frame(width: K.chipHeight, height: K.chipHeight) }
                            .buttonStyle(.plain).help("파일 첨부").accessibilityLabel("파일 첨부")
                    } else {
                        KButton(title: "입력 도구", style: .link) { composerToolsExpanded = true }
                            .help("프로젝트·첨부·모델 선택 펼치기")
                            .accessibilityIdentifier("composer-tools")
                    }
                    Spacer()
                    if store.isResponding || store.isSubmissionWaiting { WhileRespondingControl(store: store) }
                    if showComposerTools && lockedProjectID == nil { ModelControls(store: store) }
                    if store.isResponding {
                        Button { store.stopResponse() } label: {
                            Image(systemName: "stop.fill")
                                .font(K.secondary.weight(.semibold)).foregroundStyle(K.red)
                                .frame(width: K.sendButton, height: K.sendButton)
                                .background(K.sunken, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isStopping)
                        .accessibilityLabel("답변 중지")
                        .help("답변 중지")
                    }
                    Button { submit() } label: {
                        Image(systemName: "arrow.up")
                            .font(K.secondary.weight(.semibold)).foregroundStyle(K.onInk)
                            .frame(width: K.sendButton, height: K.sendButton)
                            .background(K.ink.opacity(store.composerDraft.isEmpty ? 0.25 : 1), in: Circle())
                            .animation(Motion.textSwap, value: store.composerDraft.isEmpty)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isStopping || store.isSubmitting || store.composerDraft.isEmpty)
                    .accessibilityLabel("보내기")
                    .help("Enter로 전송 · Shift+Enter로 줄바꿈 · ⌥↩ 새 창에서 대화")
                }
                if lockedProjectID != nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { Spacer(minLength: 0); ModelControls(store: store) }
                    }
                    .frame(height: K.chipHeight)
                }
            }
            .padding(.horizontal, K.s4).padding(.vertical, K.s3)
            .background(K.surface, in: RoundedRectangle(cornerRadius: K.rLarge))
            .overlay(RoundedRectangle(cornerRadius: K.rLarge).strokeBorder(composerFocused || dropping ? K.accent : K.lineStrong, lineWidth: 1))
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                addAttachments(files)
                return !files.isEmpty
            } isTargeted: { dropping = $0 }
        }
        .frame(maxWidth: K.column)
        .padding(.horizontal, K.s5)
        .padding(.top, canvasVisible ? K.s2 : K.s3)
        .padding(.bottom, canvasVisible ? K.s2 : K.s4)
        .frame(maxWidth: .infinity)
    }

    private func projectRow(_ id: String?, _ name: String) -> some View {
        Button { store.composerDraft.project = id; choosingProject = false } label: {
            HStack {
                Text(name).font(K.secondary).lineLimit(1)
                Spacer()
                if project == id { Image(systemName: "checkmark").font(K.caption.weight(.semibold)).foregroundStyle(K.accent) }
            }
            .padding(.horizontal, K.s3).padding(.vertical, K.s1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func restore(_ saved: ChatDraft) {
        guard store.composerDraft.isEmpty || store.composerDraft == saved else {
            inputError = "작성 중인 내용이 있어요. 보낸 뒤 다시 불러와 주세요."; return
        }
        store.composerDraft = saved
        if let lockedProjectID { store.composerDraft.project = lockedProjectID }
        inputError = nil
        restoredDraftFocus = UUID()
    }
    private func addAttachments(_ files: [URL]) {
        store.composerDraft.attachments = ComposerAttachments.adding(files, to: attachments)
    }
    private func pasteImage(_ data: Data) {
        do {
            addAttachments([try ComposerAttachments.saveImage(data, rulesPath: store.responseRulesPath)])
        } catch { inputError = "붙여넣은 이미지를 저장하지 못했어요. 다시 시도해 주세요." }
    }
    private func attachmentRow(_ files: [URL], removable: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: K.s2) {
                ForEach(files, id: \.self) { url in
                    AttachmentChip(url: url, preview: { previewURL = url },
                                   remove: removable ? { store.composerDraft.attachments.removeAll { $0 == url } } : nil)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "첨부"
        guard panel.runModal() == .OK else { return }
        addAttachments(panel.urls)
    }

    static func isImage(_ url: URL) -> Bool { ["png", "jpg", "jpeg", "gif", "webp"].contains(url.pathExtension.lowercased()) }

    /// The last message the person sent, when its reply was stopped and no failed draft already offers a retry.
    private var stoppedRequest: ChatDraft? {
        guard !store.isResponding, store.responseStatus == ResponseProgressView.stoppedStatus, store.failedDraft == nil,
              let item = store.chat.last(where: { if case .user = $0.kind { true } else { false } }),
              case .user(let text) = item.kind else { return nil }
        return ChatDraft(text: text, attachments: item.attachments, project: project)
    }

    private func startConversation() {
        var sending = store.composerDraft
        if let lockedProjectID { sending.project = lockedProjectID }
        guard !ChatWebBridge.isReadOnly(store), !sending.isEmpty, !store.isStopping, !store.isSubmitting else { return }
        inputError = nil
        if store.composerDraft.isEmpty || store.composerDraft == sending { store.composerDraft = .init(project: sending.project) }
        Task { @MainActor in
            do {
                _ = try await store.startMessageConversation(sending, onCreated: { root in
                    canvasRequest = .init(root: root)
                })
            } catch {
                inputError = (error as? ConversationResetError)?.localizedDescription
                    ?? (error as? ChatAttachmentError)?.localizedDescription
                    ?? "전송하지 못했어요. 작성한 내용은 그대로 보관돼 있어요."
                if store.composerDraft.isEmpty { store.composerDraft = sending }
            }
        }
    }

    private func submit(_ saved: ChatDraft? = nil) {
        let sending: ChatDraft = {
            var draft = saved ?? store.composerDraft
            if let lockedProjectID { draft.project = lockedProjectID }
            return draft
        }()
        guard !store.issueConversationIsReadOnly, !sending.isEmpty, !store.isStopping, !store.isSubmitting else { return }
        followsLatest = true
        jumpToLatest.toggle()
        inputError = nil
        // Clear the input the moment the send starts. Leaving the same text in place invites another
        // press that looks like the only way to make anything happen, and sends the message twice.
        if store.composerDraft.isEmpty || store.composerDraft == sending { store.composerDraft = .init(project: sending.project) }
        Task { @MainActor in
            do { try await store.submit(sending) }
            catch {
                // A closed Issue conversation is read-only: nothing here can be sent, so do not
                // put the text back into a composer that is no longer accepting input.
                guard !store.issueConversationIsReadOnly else {
                    inputError = "닫힌 이슈의 대화는 읽기 전용이에요"
                    return
                }
                inputError = (error as? ConversationResetError)?.localizedDescription
                    ?? (error as? ChatAttachmentError)?.localizedDescription ?? "전송하지 못했어요. 내용을 확인하고 다시 시도해 주세요."
                if store.composerDraft.isEmpty { store.composerDraft = sending }
            }
        }
    }
}

// MARK: - Chat pieces

/// A completion condition's state as one small icon: a green check, a red cross, an empty circle.
struct CriterionBox: View {
    let state: Criterion.State
    var body: some View {
        ZStack { mark.id(state).transition(.iconSwap) }
            .frame(width: K.s4, height: K.s4)
            .animation(Motion.iconSwap, value: state)
    }

    @ViewBuilder private var mark: some View {
        switch state {
        case .met: Image(systemName: "checkmark.circle.fill").font(K.secondary).foregroundStyle(K.green)
        case .unmet: Image(systemName: "xmark.circle.fill").font(K.secondary).foregroundStyle(K.red)
        case .pending: Image(systemName: "circle").font(K.secondary).foregroundStyle(K.faint)
        }
    }
}
