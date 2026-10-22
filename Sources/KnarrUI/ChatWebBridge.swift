import Foundation
import KnarrCore

enum ChatWebCommand {
    case copy(String), edit(ChatDraft), preview(URL), open(Issue.ID)
    case perform(IssueAction, Issue.ID), answer(Question.ID, QuestionAnswer), cancel(Question.ID)
    case startConversation(UUID), openConversation(UUID), openConversationWindow(UUID), canvasSend(UUID, String), canvasStop(UUID)
    case navigateTransfer(ProjectTransfer, Bool)
    case state(UUID, OMPJSON), continueConversation(String), link(URL)
    /// Opens one image the transcript actually displays; the identifier is resolved natively.
    case imagePreview(String)
    /// Opens or retries one generated work report; the id must match the card's stored report.
    case openReport(String), retryReport(String)
}

/// Events carry identity, not execution authority. Resolve against the current native store.
@MainActor final class ChatWebBridge {
    let session = UUID().uuidString
    private var submitted: Set<String> = []
    func release(message: UUID) { submitted = submitted.filter { !$0.hasPrefix(message.uuidString + ":") } }
    static func isReadOnly(_ store: any KnarrStore) -> Bool {
        store.issueConversationIsReadOnly || store.threads.first { $0.id == store.selectedThreadID }?
            .projectID.flatMap { store.project($0) }?.archived == true
    }
    /// Runs a canvas stop after admission. The message, thread and session that admitted it must still be
    /// current: the answer may have finished and another root or thread may have started since. Returns
    /// whether a stop was actually requested, so the caller never reports success for a discarded event.
    @discardableResult
    func stop(_ root: UUID, store: any KnarrStore, thread: String, session: String) -> Bool {
        guard session == self.session, store.selectedThreadID == thread,
              !store.isStopping, store.stoppableConversationRoots.contains(root) else { return false }
        store.stopResponse()
        return true
    }
    func command(_ event: OMPJSON, store: any KnarrStore, conversationRootID: UUID? = nil) -> ChatWebCommand? {
        guard event["session"]?.string == session, event["thread"]?.string == store.selectedThreadID,
              let action = event["action"]?.string, let raw = event["message"]?.string,
              let id = UUID(uuidString: raw) else { return nil }
        // A report card is derived from the saved report, so it has no stored chat row.
        if action == "reportOpen" || action == "reportRetry" {
            guard conversationRootID == nil, let reportID = event["report"]?.string,
                  WorkReportCards.messageID(reportID: reportID) == id,
                  let report = store.workReports.first(where: { $0.id == reportID }),
                  WorkReportCards.isVisible(report) else { return nil }
            if action == "reportOpen" {
                return report.analysisState == .pending || report.analysisState == .generating ? nil : .openReport(reportID)
            }
            guard !Self.isReadOnly(store), report.analysisState == .failed, !store.workReportBusy else { return nil }
            return .retryReport(reportID)
        }
        let receipt = store.selectedThreadID == ConversationThread.defaultID
            ? store.projectTransfers.first { $0.state == .delivered && $0.mainMessageID == id } : nil
        guard let item = store.chat.first(where: { $0.id == id }) ?? receipt?.receiptItem else { return nil }
        guard Self.matchesScope(event, conversationRootID: conversationRootID),
              item.conversationRootID == conversationRootID else { return nil }
        if let conversationRootID {
            guard let root = store.chat.first(where: { $0.id == conversationRootID }),
                  root.conversationRootID == nil, root.isConversationLink, case .user = root.kind else { return nil }
        }
        let text = event["text"]?.string ?? ""
        guard text.utf8.count <= 65_536 else { return nil }
        let readOnly = Self.isReadOnly(store)
        switch action {
        case "transferMain":
            guard conversationRootID == nil, case .user = item.kind,
                  let transfer = store.projectTransfers.first(where: {
                      $0.state == .delivered && $0.originThreadID == store.selectedThreadID && $0.requestMessageID == id
                  }) else { return nil }
            return .navigateTransfer(transfer, true)
        case "transferSource":
            guard conversationRootID == nil, let receipt else { return nil }
            return .navigateTransfer(receipt, false)
        case "startConversation":
            guard !readOnly, item.conversationRootID == nil, case .user = item.kind else { return nil }
            return .startConversation(id)
        case "openConversation":
            guard item.isConversationLink, item.conversationRootID == nil, case .user = item.kind else { return nil }
            return .openConversation(id)
        case "canvasWindow":
            guard item.isConversationLink, item.conversationRootID == nil, case .user = item.kind else { return nil }
            return .openConversationWindow(id)
        case "canvasSend":
            guard !readOnly, conversationRootID == nil, item.isConversationLink, case .user = item.kind,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .canvasSend(id, text)
        case "canvasStop":
            guard !readOnly, conversationRootID == nil, !store.isStopping, store.stoppableConversationRoots.contains(id) else { return nil }
            return .canvasStop(id)
        case "copy":
            switch item.kind { case .user(let s), .stallari(let s, _): return .copy(s); default: return nil }
        case "copyText": return .copy(text)
        case "link":
            guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { return nil }
            return .link(url)
        case "edit":
            guard !readOnly, case .user(let text) = item.kind else { return nil }
            return .edit(.init(text: text, attachments: item.attachments, project: store.composerDraft.project,
                conversationRootID: item.conversationRootID))
        case "preview":
            guard let index = event["index"]?.integer, item.attachments.indices.contains(index) else { return nil }
            return .preview(item.attachments[index])
        case "imagePreview":
            guard case .stallari = item.kind, text.hasPrefix("\(ChatImageSource.scheme)://image/") else { return nil }
            return .imagePreview(text)
        case "open":
            let issueID: Issue.ID
            switch item.kind {
            case .issue(let i), .proposal(let i, _): issueID = i
            case .notice(let n): issueID = n.issue
            default: return nil
            }
            guard store.issue(issueID) != nil else { return nil }
            return .open(issueID)
        case "approve", "revise", "reject":
            guard !readOnly, case .proposal(let issueID, let version) = item.kind,
                  event["version"]?.integer == version, let issue = store.issue(issueID),
                  issue.archivedAt == nil, issue.state == .awaitingApproval,
                  issue.proposal?.version == version, issue.approval?.runID == nil, issue.proposalReviewNote == nil else { return nil }
            let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if action == "approve" && store.approvalBlockReason(for: issueID) != nil { return nil }
            if action == "revise" && note.isEmpty { return nil }
            let key = id.uuidString + ":proposal:\(version)"
            guard submitted.insert(key).inserted else { return nil }
            return .perform(action == "approve" ? .approveProposal(version: version) :
                action == "revise" ? .requestProposalChanges(version: version, note: note) : .rejectProposal(version: version, note: note), issueID)
        case "noticePrimary":
            guard !readOnly, case .notice(let notice) = item.kind, let primary = notice.primary,
                  let issue = store.issue(notice.issue), issue.archivedAt == nil else { return nil }
            if primary.action == .resolvedInput && (issue.state != .needsInput || store.questions.contains { $0.issue == issue.id && $0.isPending }) { return nil }
            // Approval must originate from the exact versioned proposal surface.
            switch primary.action { case .approveProposal, .requestProposalChanges, .rejectProposal: return nil; default: break }
            return .perform(primary.action, issue.id)
        case "answer", "cancelQuestion":
            guard !readOnly, case .question(let qid) = item.kind, let q = store.question(qid), q.isPending else { return nil }
            if action == "cancelQuestion" { guard submitted.insert(id.uuidString + ":question").inserted else { return nil }; return .cancel(qid) }
            let selected = event["selected"]?.array?.compactMap(\.string) ?? []
            guard Set(selected).count == selected.count, selected.allSatisfy(q.options.contains), q.allowsMultiple || selected.count <= 1 else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch q.replyStyle {
            case .select, .confirm: guard !selected.isEmpty else { return nil }
            case .input, .editor: break
            case nil: guard !selected.isEmpty || !trimmed.isEmpty else { return nil }
            }
            guard submitted.insert(id.uuidString + ":question").inserted else { return nil }
            return .answer(qid, .init(selectedOptions: selected, text: q.replyStyle == nil ? (trimmed.isEmpty ? nil : trimmed) : text))
        case "state":
            guard let state = event["state"], case .object = state,
                  let bytes = try? JSONEncoder().encode(state), bytes.count <= 131_072 else { return nil }
            return .state(id, state)
        case "continue":
            guard !readOnly, item.activity == nil, case .stallari(let source, _) = item.kind,
                  source.range(of: #"(?m)^ {0,3}(`{3,}|~{3,})openui(?:-lang)?[ \t]*$"#, options: .regularExpression) != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .continueConversation(text)
        default: return nil
        }
    }
    static func matchesScope(_ event: OMPJSON, conversationRootID: UUID?) -> Bool {
        guard let value = event["conversationRootID"], value != .null else { return conversationRootID == nil }
        guard let raw = value.string, let id = UUID(uuidString: raw) else { return false }
        return id == conversationRootID
    }
}

/// UI-only state; message text and execution records remain in the existing repository.
@MainActor final class ChatWebStateStore {
    let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    private func key(thread: String, message: UUID) -> String {
        let scope = Data(thread.utf8).base64EncodedString()
        return "knarr.chat.web.v1.\(scope).\(message.uuidString)"
    }
    func load(thread: String, message: UUID) -> OMPJSON {
        guard let data = preferences.data(forKey: key(thread: thread, message: message)), data.count <= 131_072,
              let state = try? JSONDecoder().decode(OMPJSON.self, from: data), case .object = state else { return .object([:]) }
        return state
    }
    @discardableResult func save(_ state: OMPJSON, thread: String, message: UUID) -> Bool {
        guard case .object = state, let data = try? JSONEncoder().encode(state), data.count <= 131_072 else { return false }
        preferences.set(data, forKey: key(thread: thread, message: message)); return true
    }
}
