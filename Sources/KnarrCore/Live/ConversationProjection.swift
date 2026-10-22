import Foundation

/// Shared by every subscriber to one persistence update. Build indexes and screen values
/// once, rather than rescanning all runs/issues/messages in each open conversation.
struct ConversationProjection: Sendable {
    let activeHirdsByProject: [String: Int]
    let installationBlocked: Bool
    let issues: [Issue]
    let projects: [ProjectSummary]
    let questions: [Question]
    let issuesByThread: [String: [Issue]]
    let questionsByThread: [String: [Question]]
    let chatByThread: [String: [ChatItem]]

    init(_ snapshot: PersistenceSnapshot) {
        var active: [String: Int] = [:], latest: [Issue.ID: PersistedRun] = [:]
        let runs = Dictionary(uniqueKeysWithValues: snapshot.runs.map { ($0.id, $0) })
        for run in snapshot.runs {
            latest[run.issueID] = run
            if !run.state.isTerminal || (run.cancellationRequestedAt != nil && run.processEndedAt == nil) {
                active[run.projectID, default: 0] += 1
            }
        }
        activeHirdsByProject = active; installationBlocked = !active.isEmpty
        let names = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0.name) })
        let preparationSources = Set(snapshot.preparationItems.compactMap(\.sourceIssueID))
        var counts: [String: Int] = [:], presented: [Issue] = []
        for var issue in snapshot.issues where snapshot.issueProjects[issue.id] != StoredProject.hubID {
            if let projectID = snapshot.issueProjects[issue.id] {
                if let name = names[projectID] { issue.projectName = name }
                if issue.needsAttention && !preparationSources.contains(issue.id) { counts[projectID, default: 0] += 1 }
            }
            if latest[issue.id]?.state == .succeeded && issue.state == .running { issue.headline = "Stallari 판정 대기" }
            presented.append(issue)
        }
        issues = presented
        issuesByThread = Dictionary(grouping: presented, by: \.conversationThreadID)
        projects = snapshot.projects.filter { $0.id != StoredProject.hubID }.map {
            .init(id: $0.id, name: $0.name, path: $0.absolutePath, openIssues: counts[$0.id] ?? 0,
                  archived: $0.archivedAt != nil, settings: $0.settings)
        }
        let owners = Dictionary(uniqueKeysWithValues: snapshot.issues.map { ($0.id, $0.conversationThreadID) })
        var groupedQuestions: [String: [Question]] = [:], allQuestions: [Question] = []
        for q in snapshot.questions {
            let state: Question.State = switch q.state {
            case .pending: runs[q.runID]?.state.isTerminal == false ? .pending : .unavailable
            case .answered: .answered(q.answer ?? .init(selectedOptions: [], text: nil))
            case .cancelled: .cancelled
            }
            let question = Question(id: .init(q.id), issue: q.issueID, run: q.runID,
                asker: q.source == .stallari ? "Stallari" : "Hird", prompt: q.prompt,
                options: q.options, askedAt: q.createdAt, state: state)
            allQuestions.append(question)
            if let owner = owners[q.issueID] { groupedQuestions[owner, default: []].append(question) }
        }
        questions = allQuestions; questionsByThread = groupedQuestions
        var chats: [String: [ChatItem]] = [:]
        for (item, link) in zip(snapshot.chat, snapshot.chatLinks) { chats[link.conversationThreadID, default: []].append(item) }
        chatByThread = chats
    }
}
