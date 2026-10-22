import Foundation
import KnarrCore
import KnarrSync

/// Turns what the Mac shows into the records the phone reads.
public enum MobileProjection {
    public static let messageLimit = 150
    public static let eventLimit = 20
    /// Applied results stay visible on the phone this long.
    public static let finishedWindow: TimeInterval = 3 * 24 * 3600

    @MainActor
    public static func records(of store: some KnarrStore, now: Date = .now, keepMessages: Set<String> = []) -> [MobileRecord] {
        records(issues: store.issues.filter { !store.preparationSourceIDs.contains($0.id) }, questions: store.questions, chat: store.chat, projects: store.projects,
                stallari: store.stallari, isResponding: store.isResponding, now: now,
                threads: store.threads, chatByThread: store.chatByThread, keepMessages: keepMessages,
                reports: store.workReports)
    }

    public static func records(issues: [Issue], questions: [Question], chat: [ChatItem], projects: [ProjectSummary],
                               stallari: StallariInfo, isResponding: Bool, now: Date,
                               threads: [ConversationThread] = [], chatByThread: [String: [ChatItem]]? = nil,
                               keepMessages: Set<String> = [], reports: [WorkReport] = []) -> [MobileRecord] {
        var groups: [Issue.ID: MobileIssue.Group] = [:]
        for section in Panel.sections(for: issues, questions: questions) {
            for issue in section.issues {
                // Keep the existing CloudKit group names and phone input routing.
                groups[issue.id] = switch section.kind {
                case .awaitingApproval, .needsAnswer, .judging, .awaitingIntegration, .unmet: .mine
                case .failed: .stopped
                case .inProgress: .working
                }
            }
        }
        var out: [MobileRecord] = []
        var shown = Set<Issue.ID>()
        for issue in issues where issue.archivedAt == nil {
            let group = groups[issue.id] ?? .finished
            if group == .finished, now.timeIntervalSince(lastChange(of: issue)) > finishedWindow { continue }
            out.append(.issue(mobileIssue(issue, group: group, questions: questions)))
            shown.insert(issue.id)
        }
        // Answered questions only matter next to their Issue; pending ones always reach the phone.
        for question in questions {
            // Generation-local Stallari dialogs have no durable phone response route.
            guard let issue = question.issue, question.isPending || shown.contains(issue) else { continue }
            out.append(.question(mobileQuestion(question, issue: issue)))
        }
        let titles = Dictionary(issues.map { ($0.id, $0.title) }, uniquingKeysWith: { $1 })
        let asked = Dictionary(questions.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let byThread = chatByThread ?? [ConversationThread.defaultID: chat]
        // Newest messages per conversation travel always; older pages stay while the phone can use them.
        // The order within one timestamp follows the Mac's own transcript order, so cards keep their place.
        let reportCards = reports.filter { WorkReportCards.isVisible($0) }
        var messages: [(index: Int, message: MobileMessage)] = []
        for (thread, stored) in byThread {
            let items = thread == ConversationThread.defaultID
                ? WorkReportCards.transcript(stored, reports: reportCards, threadID: thread) : stored
            // Day separators are display-only rows, so the recent window counts real messages only.
            let sendable = items.indices.filter { if case .day = items[$0].kind { false } else { true } }
            let kept = keepMessages.isEmpty ? [] : sendable.filter { keepMessages.contains(items[$0].id.uuidString) }
            let recent = sendable.suffix(MobileLimits.recentPerThread)
            for index in Set(recent).union(kept).sorted() {
                if let message = mobileMessage(items[index], thread: thread, titles: titles, questions: asked, reports: reports) {
                    messages.append((index, message))
                }
            }
        }
        var seen = Set<String>()
        out += messages.sorted { $0.message.at == $1.message.at ? $0.index < $1.index : $0.message.at < $1.message.at }
            .compactMap { seen.insert($0.message.id).inserted ? MobileRecord.message($0.message) : nil }
        out += threadRecords(threads: threads, chatByThread: byThread, issues: issues, questions: questions,
                             isResponding: isResponding)
        out += projects.map { .project(MobileProject(id: $0.id, name: $0.name, openIssues: $0.openIssues)) }
        out.append(.status(MobileStatus(isResponding: isResponding, engine: stallari.engine, macRunning: true)))
        return out
    }

    /// One record per conversation: name, owner, latest message time and whether work is happening in it.
    static func threadRecords(threads: [ConversationThread], chatByThread: [String: [ChatItem]], issues: [Issue],
                              questions: [Question], isResponding: Bool) -> [MobileRecord] {
        let titles = Dictionary(issues.map { ($0.id, $0.title) }, uniquingKeysWith: { $1 })
        let projectNames = Dictionary(issues.map { ($0.id, $0.projectName) }, uniquingKeysWith: { $1 })
        let asking = Set(questions.lazy.filter(\.isPending).compactMap(\.issue))
        var known = Set<String>()
        var out: [MobileRecord] = []
        func append(_ thread: ConversationThread) {
            guard known.insert(thread.id).inserted else { return }
            let items = (chatByThread[thread.id] ?? []).filter { if case .day = $0.kind { false } else { true } }
            let working = isResponding && thread.id == ConversationThread.defaultID
                || (thread.issueID.map { id in issues.first { $0.id == id }?.hasActiveHird == true } ?? false)
                || (thread.issueID.map { asking.contains($0) } ?? false)
            let kind: MobileThread.Kind = thread.id == ConversationThread.defaultID ? .main
                : thread.issueID != nil ? .issue : .project
            let name = thread.id == ConversationThread.defaultID ? "메인" : thread.name
            out.append(.thread(MobileThread(id: thread.id, name: name, kind: kind,
                                            project: thread.projectID, issue: thread.issueID?.rawValue,
                                            lastMessageAt: items.map(\.at).max(), working: working,
                                            messageCount: items.count)))
            _ = projectNames; _ = titles
        }
        append(.default)
        for thread in threads { append(thread) }
        for id in chatByThread.keys.sorted() where !known.contains(id) {
            append(ConversationThread(id: id, name: id))
        }
        return out
    }

    /// The page the phone asked for: messages older than `before`, newest first.
    public static func history(items: [ChatItem], thread: String, before: Date, titles: [Issue.ID: String],
                               questions: [Question], reports: [WorkReport] = [], limit: Int = MobileLimits.historyPage) -> [MobileMessage] {
        let asked = Dictionary(questions.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let cards = WorkReportCards.transcript(items, reports: reports, threadID: thread)
        return cards.compactMap { item -> MobileMessage? in
            guard item.at < before, let message = mobileMessage(item, thread: thread, titles: titles, questions: asked, reports: reports) else { return nil }
            return message
        }.sorted { ($0.at, $0.id) > ($1.at, $1.id) }.prefix(limit).map { $0 }
    }

    static func lastChange(of issue: Issue) -> Date {
        ([issue.startedAt] + issue.events.map(\.at) + issue.hirds.map { run -> Date in
            switch run.status {
            case .working: run.lastActivityAt
            case .waitingOnHuman(let at), .failed(let at), .done(let at): at
            }
        }).max() ?? issue.startedAt
    }

    static func mobileIssue(_ issue: Issue, group: MobileIssue.Group, questions: [Question] = []) -> MobileIssue {
        let state: MobileIssue.State = switch issue.state {
        case .running: issue.hasActiveHird ? .running : .failed
        case .needsInput: .needsInput
        case .failed: .failed
        case .done: .done
        case .awaitingApproval: .awaitingApproval
        case .rejected: .rejected
        }
        let criteria = issue.acceptance.map { c -> MobileIssue.Criterion in
            let s: MobileIssue.Criterion.State = switch c.state { case .pending: .pending; case .met: .met; case .unmet: .unmet }
            return .init(text: c.text, state: s, evidence: c.evidence.isEmpty ? nil : c.evidence)
        }
        let progress = issue.hirds.last.map(\.progress).flatMap { p -> String? in
            guard p.total > 0 else { return nil }
            return p.current.map { "\(p.done)/\(p.total) · \($0.title)" } ?? "\(p.done)/\(p.total)"
        }
        let runs = issue.hirds.map { run -> MobileIssue.Run in
            let status: MobileIssue.Run.Status = switch run.status {
            case .working: .working
            case .waitingOnHuman: .waiting
            case .failed: .failed
            case .done: .done
            }
            let steps = run.displaySteps.map { step -> MobileIssue.Run.Step in
                let state: MobileIssue.Run.Step.State = switch step.state {
                case .done: .done
                case .active: .active
                case .pending: .pending
                case .waiting: .waiting
                case .blocked: .blocked
                case .failed: .failed
                }
                return .init(title: step.title, state: state)
            }
            // Only saved stage reports form a plan; activity remains independent of that plan.
            let stageProgress = run.stageProgress
            let stages = stageProgress.flatMap { $0.plannedStages.isEmpty ? nil : $0.steps.map { MobileIssue.Run.Step(title: $0.title, state: stageStep($0.state)) } }
            let activity = run.currentCommand?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? stageProgress?.basis?.nilIfEmpty
                ?? (run.status.isWorkingOrWaiting ? steps.first { $0.state == .active }?.title : nil)
            return .init(name: run.name, role: run.roleSummary, status: status, steps: steps, activity: activity,
                         stages: stages, stage: stageProgress?.reportedStageIndex, startedAt: run.startedAt ?? issue.startedAt,
                         checksPassed: stageProgress?.checks.passed, checksFailed: stageProgress?.checks.failed)
        }
        let events = issue.events.sorted { $0.at > $1.at }.prefix(eventLimit)
            .map { MobileIssue.Event(at: $0.at, actor: $0.actor, text: $0.text) }
        let application: String? = switch issue.application {
        case .applied(let branch, let commit): "원본 \(branch)에 반영했어요 · \(commit.prefix(7))"
        case .kept(let branch, let commit): "\(branch) 브랜치에 보관돼 있어요 · \(commit.prefix(7))"
        case .blocked(let why): "원본 반영이 막혔어요: \(why)"
        case nil: nil
        }
        // updatedAt orders the phone's lists, so it ignores per-tool activity ticks that would re-upload constantly.
        let updated = ([issue.startedAt] + issue.events.map(\.at)).max() ?? issue.startedAt
        let proposal = issue.proposal.map {
            MobileIssue.Proposal(version: $0.version, title: issue.title, criteria: issue.acceptance.map(\.text),
                instruction: $0.instruction.clipped(), model: $0.model, thinking: $0.thinking, mode: $0.mode.rawValue)
        }
        let files = MobileIssueFiles.read(issue)
        return MobileIssue(id: issue.id.rawValue, title: issue.title, project: issue.projectName, state: state, group: group,
                           headline: issue.needsNewProposal ? "실행 없음 · 다시 제안 필요" : issue.headline, detail: issue.detail, criteria: criteria, progress: progress,
                           startedAt: issue.startedAt, updatedAt: updated, runs: runs, events: Array(events), application: application,
                           proposal: proposal, proposalReviewNote: issue.proposalReviewNote,
                           report: files.report, verifications: files.verifications, captures: files.captures,
                           thread: issue.conversationThreadID, status: issue.displayStatus.key)
    }

    static func stageStep(_ state: HirdStep.State) -> MobileIssue.Run.Step.State {
        switch state {
        case .done: .done
        case .active: .active
        case .pending: .pending
        case .waiting: .waiting
        case .blocked: .blocked
        case .failed: .failed
        }
    }

    static func mobileQuestion(_ q: Question, issue: Issue.ID) -> MobileQuestion {
        let state: MobileQuestion.State
        var answer: String?
        switch q.state {
        case .pending: state = .pending
        case .cancelled: state = .cancelled
        case .unavailable: state = .cancelled // Preserve the phone contract: never offer an unrouteable reply.
        case .answered(let a):
            state = .answered
            answer = (a.selectedOptions + [a.text].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · ")
        }
        return MobileQuestion(id: q.id.rawValue, issue: issue.rawValue, asker: q.asker, prompt: q.prompt, options: q.options,
                              allowsMultiple: q.allowsMultiple, state: state, answer: answer, askedAt: q.askedAt)
    }

    static func mobileMessage(_ item: ChatItem, thread: String = ConversationThread.defaultID,
                              titles: [Issue.ID: String], questions: [Question.ID: Question],
                              reports: [WorkReport] = []) -> MobileMessage? {
        let id = item.id.uuidString
        // Pictures the person sent travel as name/type only; the bytes are not in the phone's copy.
        let attachments = item.attachments.isEmpty ? nil : item.attachments.map {
            MobileAttachment(id: $0.lastPathComponent, name: $0.lastPathComponent,
                             type: ChatImageSource.mimeType(for: $0) ?? "application/octet-stream", byteCount: 0)
        }
        // The Mac's own activity record, so the phone folds exactly the same rows into 진행 기록.
        let activity = item.activity.map {
            MobileMessage.Activity(kind: $0.kind.rawValue, title: $0.title, state: $0.state.rawValue,
                                   label: $0.statusLabel, startedAt: item.at, updatedAt: $0.updatedAt)
        }
        switch item.kind {
        case .user(let text): return MobileMessage(id: id, at: item.at, role: .user, text: text, project: nil,
                                                  thread: thread, attachments: attachments)
        case .stallari(let text, let project): return MobileMessage(id: id, at: item.at, role: .stallari, text: text,
                                                                   project: project, thread: thread, attachments: attachments,
                                                                   activity: activity)
        case .notice(let n):
            return MobileMessage(id: id, at: item.at, role: .notice, text: "\(n.title)\n\(n.body)", project: nil,
                                 issue: n.issue.rawValue, thread: thread)
        case .issue(let issue), .proposal(let issue, _):
            guard let title = titles[issue] else { return nil }
            return MobileMessage(id: id, at: item.at, role: .issue, text: title, project: nil, issue: issue.rawValue, thread: thread)
        case .question(let question):
            guard let q = questions[question], let issue = q.issue else { return nil }
            return MobileMessage(id: id, at: item.at, role: .question, text: q.prompt, project: nil, issue: issue.rawValue,
                                 question: q.id.rawValue, thread: thread)
        case .autoCheck(let summary, let lines):
            return MobileMessage(id: id, at: item.at, role: .autoCheck, text: ([summary] + lines).joined(separator: "\n"),
                                 project: nil, thread: thread)
        case .report(let reportID):
            guard let report = reports.first(where: { $0.id == reportID }) else { return nil }
            let state: String
            switch report.analysisState {
            case .pending: state = "pending"
            case .generating: state = "generating"
            case .ready: state = "ready"
            case .failed: state = "failed"
            case .noActivity: state = "noActivity"
            }
            return MobileMessage(id: id, at: item.at, role: .report,
                                 text: report.period.dateLabel + " · " + report.period.title, project: nil, thread: thread,
                                 report: MobileReport(title: report.period.dateLabel + " · " + report.period.title,
                                                      lines: WorkReportCards.lines(for: report), state: state,
                                                      error: report.analysisError))
        case .day: return nil
        }
    }
}

private extension HirdRun.Status {
    var isWorkingOrWaiting: Bool {
        if case .working = self { return true }
        if case .waitingOnHuman = self { return true }
        return false
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
