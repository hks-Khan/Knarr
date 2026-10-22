import KnarrCore

/// The card's `...` menu and right-click menu share this list, so both offer the same commands
/// and every command goes through the existing store paths the card buttons and drawer use.
/// A disabled command carries a short reason, so the menu never shows a dead row without one.
/// Commands that asked the person to review, merge or re-run a result are gone: Stallari judges
/// and integrates, so the cards only show what the saved records say.
@MainActor
struct IssueCardActions {
    struct Item: Identifiable {
        let id: String
        let title: String
        var enabled = true
        /// Why the command is unavailable; only read when `enabled` is false.
        var reason: String?
        var perform: () -> Void

        /// The row the menu shows: a disabled command names its reason after an em dash.
        var menuTitle: String {
            guard !enabled, let reason, !reason.isEmpty else { return title }
            return title + " — " + reason
        }
    }

    let issue: Issue
    let store: any KnarrStore
    let open: () -> Void
    let goToThread: () -> Void

    private var pending: [Question] { store.pendingQuestions(for: issue.id) }
    private var closed: Bool { issue.displayStatus == .completed || issue.displayStatus == .cancelled }
    private var closeBlock: String? {
        guard issue.archivedAt == nil else { return "이미 닫힘" }
        return issue.hasActiveHird ? "실행 중에는 닫을 수 없어요" : nil
    }
    /// Mirrors the drawer link: moving only helps when the issue lives in another thread.
    var showsThread: Bool {
        store.threads.count > 1 && issue.conversationThreadID != store.selectedThreadID
    }

    var items: [Item] {
        var items = [Item(id: "open", title: "상세 열기", perform: open)]
        if showsThread { items.append(Item(id: "thread", title: "스레드로 이동", perform: goToThread)) }
        items += stateItems
        return items
    }

    /// Only what the person owns: approving a saved proposal, continuing after external work,
    /// answering a question and stopping a run.
    private var stateItems: [Item] {
        guard !closed else { return [] }
        var items: [Item] = []
        if issue.presentationStatus(hasPendingQuestion: !pending.isEmpty) == .awaitingApproval,
           let proposal = issue.proposal, issue.state == .awaitingApproval {
            let block = approvalBlock
            items.append(Item(id: "approve", title: "제안 v\(proposal.version) 실행", enabled: block == nil, reason: block) {
                guard block == nil else { return }
                store.perform(.approveProposal(version: proposal.version), on: issue.id)
            })
        }
        if issue.presentationStatus(hasPendingQuestion: !pending.isEmpty) == .needsAnswer,
           issue.state == .needsInput, pending.isEmpty {
            items.append(Item(id: "resolvedInput", title: "외부 작업 끝냈어요 · 이어서") {
                store.perform(.resolvedInput, on: issue.id)
            })
        }
        if issue.archivedAt == nil, issue.hasActiveHird, issue.state == .running, pending.isEmpty {
            items.append(Item(id: "stop", title: "멈추기") {
                store.perform(.stop, on: issue.id)
            })
        }
        return items
    }

    /// The same conditions the card's primary button uses, including the store's approval blocker.
    private var approvalBlock: String? {
        guard issue.proposal != nil else { return "제안이 없어요" }
        if issue.state != .awaitingApproval { return "지금은 승인할 수 없어요" }
        if issue.proposalReviewNote != nil { return "수정 요청을 보냈어요" }
        if issue.approval?.runID != nil { return "이미 승인됨" }
        if let reason = store.approvalBlockReason(for: issue.id) { return reason }
        return nil
    }

    /// Same closure flow as the drawer footer: one reason per existing `IssueCloseReason`.
    var closeItems: [Item] {
        let block = closeBlock
        return IssueCloseReason.allCases.map { reason in
            Item(id: "close-" + reason.rawValue, title: reason.title, enabled: block == nil, reason: block) {
                guard block == nil else { return }
                store.perform(.closeIssue(reason: reason), on: issue.id)
            }
        }
    }

    var canClose: Bool { issue.archivedAt == nil }
}
