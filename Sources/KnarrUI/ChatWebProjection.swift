import Foundation
import KnarrCore

/// Turns one transcript row into the value the page renders. A row is rebuilt only when the fields
/// it reads change: Hird activity changes an Issue card, not the hundreds of messages around it.
@MainActor enum ChatWebProjection {
    /// Rows built since the last reset. A refresh that rebuilds unchanged rows scales with
    /// transcript length; tests assert the count stays at the changed rows.
    private(set) static var buildCount = 0

    static func resetBuildCount() { buildCount = 0 }

    /// Everything one row reads from the store, snapshotted once per refresh. Equality of this value
    /// is what lets the coordinator keep the previous row without formatting or rewriting it.
    struct Inputs: Equatable {
        struct Transfer: Equatable {
            var summary: String
            var title: String
            var request: String
        }

        var item: ChatItem
        var state: OMPJSON
        var issue: Issue?
        var question: Question?
        /// The issue title a question card names, resolved once.
        var questionIssueTitle: String?
        var approvalBlock: String?
        /// Whether a notice's one-click answer may show; it also needs the issue to be waiting.
        var noticePrimaryEnabled = false
        var transfer: Transfer?
        var mainTransferID: String?
        /// The work report a report card shows, resolved once so a retry updates the same row.
        var report: WorkReport?
        var workReportBusy = false
    }

    /// Lookups shared by every row of one refresh, so a row never re-scans `issues` or `questions`.
    @MainActor struct Context {
        private let issues: [Issue.ID: Issue]
        private let questions: [Question.ID: Question]
        private let pendingIssues: Set<Issue.ID>
        private let transfers: [ProjectTransfer]
        private let threadID: String
        private let approvalBlocks: [Issue.ID: String]
        private let reports: [WorkReport.ID: WorkReport]
        private let workReportBusy: Bool

        init(store: any KnarrStore) {
            reports = Dictionary(store.workReports.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            workReportBusy = store.workReportBusy
            issues = Dictionary(store.issues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            questions = Dictionary(store.questions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            pendingIssues = Set(store.questions.lazy.filter(\.isPending).compactMap(\.issue))
            transfers = store.projectTransfers
            threadID = store.selectedThreadID
            var blocks: [Issue.ID: String] = [:]
            for issue in store.issues where issue.state == .awaitingApproval && issue.proposal != nil {
                if let reason = store.approvalBlockReason(for: issue.id) { blocks[issue.id] = reason }
            }
            approvalBlocks = blocks
        }

        func inputs(_ item: ChatItem, state: OMPJSON) -> Inputs {
            var value = Inputs(item: item, state: state, issue: nil, question: nil, questionIssueTitle: nil,
                               approvalBlock: nil, transfer: nil, mainTransferID: nil)
            func issue(_ id: Issue.ID) { value.issue = issues[id] }
            switch item.kind {
            case .issue(let id): issue(id)
            case .proposal(let id, _):
                issue(id)
                value.approvalBlock = approvalBlocks[id]
            case .notice(let notice):
                issue(notice.issue)
                value.noticePrimaryEnabled = issues[notice.issue]?.state == .needsInput && !pendingIssues.contains(notice.issue)
            case .report(let id):
                value.report = reports[id]
                value.workReportBusy = workReportBusy
            case .question(let id):
                value.question = questions[id]
                value.questionIssueTitle = questions[id]?.issue.flatMap { issues[$0] }?.title
            default: break
            }
            if threadID == ConversationThread.defaultID,
               let transfer = transfers.first(where: { $0.state == .delivered && $0.mainMessageID == item.id }) {
                value.transfer = .init(summary: transfer.summary,
                                       title: transfer.projectName + "에서 전달한 요청", request: transfer.requestText)
            } else if item.conversationRootID == nil, case .user = item.kind,
                      let transfer = transfers.first(where: {
                          $0.state == .delivered && $0.originThreadID == threadID && $0.requestMessageID == item.id
                      }) {
                value.mainTransferID = transfer.id
            }
            return value
        }
    }

    /// A row built from a store, for callers that have one item rather than a full refresh.
    static func row(_ item: ChatItem, store: any KnarrStore, state: OMPJSON, images: ChatImageResolver? = nil) -> OMPJSON {
        row(Context(store: store).inputs(item, state: state), images: images)
    }

    static func row(_ inputs: Inputs, images: ChatImageResolver? = nil) -> OMPJSON {
        buildCount += 1
        let item = inputs.item
        var value: [String: OMPJSON] = ["id": .string(item.id.uuidString), "time": .string(item.at.formatted(date: .omitted, time: .shortened)),
            "at": .number(item.at.timeIntervalSince1970 * 1000),
            "state": inputs.state, "attachments": .array(item.attachments.map { .string($0.lastPathComponent) })]
        value["conversationRootID"] = item.conversationRootID.map { .string($0.uuidString) } ?? .null
        value["isConversationLink"] = .bool(item.isConversationLink)
        func body(_ kind: String, _ text: String) { value["kind"] = .string(kind); value["text"] = .string(text) }
        func issue(_ id: Issue.ID) {
            guard let issue = inputs.issue, issue.id == id else { return }
            value["issue"] = .object(["id": .string(id.rawValue), "title": .string(issue.title), "status": .string(issue.statusLine),
                "met": .number(Double(issue.metCriteria)), "total": .number(Double(issue.acceptance.count)),
                "criteriaSummary": .string(IssueCards.acceptanceSummary(for: issue)),
                "headline": .string(issue.headline), "detail": .string(issue.detail), "state": .string(issue.state.rawValue),
                "steps": .array(issue.allSteps.map { step in
                    let status: String
                    switch step.state { case .done: status = "done"; case .active: status = "active"; case .pending: status = "pending"; case .waiting: status = "waiting"; case .blocked: status = "blocked"; case .failed: status = "failed" }
                    return .object(["title": .string(step.title), "state": .string(status)])
                }),
                "hirds": .array(issue.hirds.map { hird in
                    let status: String, since: Date
                    switch hird.status { case .working: status = "working"; since = hird.lastActivityAt
                    case .waitingOnHuman(let date): status = "waiting"; since = date
                    case .failed(let date): status = "failed"; since = date
                    case .done(let date): status = "done"; since = date }
                    return .object(["state": .string(status), "since": .number(since.timeIntervalSince1970 * 1000)])
                })])
        }
        switch item.kind {
        case .day(let text): body("day", text)
        case .user(let text): body("user", text)
        case .stallari(let text, let project):
            let shown = images.map { resolver in resolver.rewriting(text) } ?? text
            body("assistant", shown); value["project"] = project.map(OMPJSON.string) ?? .null
        case .issue(let id): body("issue", ""); issue(id)
        case .proposal(let id, let version):
            body("proposal", ""); issue(id)
            if let i = inputs.issue, i.id == id, let p = i.proposal, p.version == version, i.archivedAt == nil, i.state == .awaitingApproval {
                value["proposal"] = .object(["version": .number(Double(version)), "instruction": .string(p.instruction),
                    "model": .string(p.model), "thinking": p.thinking.map(OMPJSON.string) ?? .null,
                    "mode": .string(p.mode.rawValue), "previousRun": p.previousRunID.map { .string($0.rawValue) } ?? .null,
                    "editable": .bool(i.approval?.runID == nil && i.proposalReviewNote == nil),
                    "note": i.proposalReviewNote.map(OMPJSON.string) ?? .null,
                    "blockReason": inputs.approvalBlock.map(OMPJSON.string) ?? .null])
            }
        case .autoCheck(let summary, let lines): body("autoCheck", summary); value["lines"] = .array(lines.map(OMPJSON.string))
        case .report(let reportID):
            body("report", "")
            if let report = inputs.report, report.id == reportID {
                let state: String
                switch report.analysisState {
                case .pending: state = "pending"
                case .generating: state = "generating"
                case .ready: state = "ready"
                case .failed: state = "failed"
                case .noActivity: state = "noActivity"
                }
                value["report"] = .object(["id": .string(reportID),
                    "title": .string(report.period.dateLabel + " · " + report.period.title),
                    "state": .string(state),
                    "lines": .array(WorkReportCards.lines(for: report).map(OMPJSON.string)),
                    "error": report.analysisError.map(OMPJSON.string) ?? .null,
                    "retryable": .bool(state == "failed"),
                    "busy": .bool(inputs.workReportBusy)])
            }
        case .notice(let n):
            body("notice", n.body); issue(n.issue); value["title"] = .string(n.title)
            value["tone"] = .string(n.tone == .failed ? "red" : n.tone == .result ? "green" : "amber")
            if let p = n.primary, p.action != .resolvedInput || inputs.noticePrimaryEnabled {
                switch p.action {
                case .approveProposal, .requestProposalChanges, .rejectProposal: break
                default: value["primary"] = .string(p.action == .resolvedInput ? "외부 작업 끝냈어요 · 이어서" : p.label)
                }
            }
        case .question(let id):
            body("question", "")
            if let q = inputs.question, q.id == id {
                let status: String, summary: String
                switch q.state {
                case .pending: status = "pending"; summary = ""
                case .cancelled: status = "cancelled"; summary = "질문 닫음"
                case .unavailable: status = "unavailable"; summary = "실행 또는 연결이 끝나 답을 보낼 수 없어요."
                case .answered(let a): status = "answered"; summary = QuestionCard.summary(a)
                }
                value["question"] = .object(["id": .string(id.rawValue), "asker": .string(q.asker), "issueTitle": inputs.questionIssueTitle.map(OMPJSON.string) ?? .null, "prompt": .string(q.prompt),
                    "options": .array(q.options.map(OMPJSON.string)), "multiple": .bool(q.allowsMultiple), "status": .string(status),
                    "summary": .string(summary), "style": q.replyStyle.map { .string($0.rawValue) } ?? .null,
                    "placeholder": q.placeholder.map(OMPJSON.string) ?? .null, "prefill": q.prefill.map(OMPJSON.string) ?? .null])
            }
        }
        if let transfer = inputs.transfer {
            body("transfer", transfer.summary)
            value["title"] = .string(transfer.title)
            value["request"] = .string(transfer.request)
        } else if let main = inputs.mainTransferID {
            value["mainTransferID"] = .string(main)
        }
        if let activity = item.activity {
            value["kind"] = .string("activity")
            value["activity"] = .object(["kind": .string(activity.kind.rawValue), "title": .string(activity.title),
                "state": .string(activity.state.rawValue), "label": .string(activity.statusLabel),
                "startedAt": .number(item.at.timeIntervalSince1970 * 1000),
                "updatedAt": .number(activity.updatedAt.timeIntervalSince1970 * 1000)])
        }
        return .object(value)
    }
}
