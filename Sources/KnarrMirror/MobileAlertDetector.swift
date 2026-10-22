import Foundation
import KnarrCore
import KnarrSync

/// Spots the moments worth a push on the phone by comparing each look with the previous one.
/// The first look only records where issues stand, and Issues or questions that show up already settled
/// (loaded from the database after launch) are not announced, so opening Knarr never floods the phone.
public struct MobileAlertDetector: Sendable {
    private var states: [Issue.ID: IssueState]?
    private var proposalVersions: [Issue.ID: Int] = [:]
    private var since: Date?
    private var seenQuestions: Set<Question.ID> = []
    private var seenMessages: Set<UUID> = []
    private var replyExpected = false

    public init() {}

    /// The phone just sent Stallari a message, so its next reply should reach the phone.
    public mutating func expectReply() { replyExpected = true }

    public mutating func alerts(issues: [Issue], questions: [Question], chat: [ChatItem], now: Date) -> [MobileAlert] {
        let replies = chat.filter { if case .stallari = $0.kind { true } else { false } }
        defer {
            states = Dictionary(issues.map { ($0.id, $0.state) }, uniquingKeysWith: { $1 })
            proposalVersions = Dictionary(issues.compactMap { issue in issue.proposal.map { (issue.id, $0.version) } }, uniquingKeysWith: { $1 })
            seenQuestions.formUnion(questions.map(\.id))
            seenMessages.formUnion(replies.map(\.id))
        }
        guard let previous = states, let since else { self.since = now; return [] }

        var out: [MobileAlert] = []
        func add(_ title: String, _ body: String, _ issue: Issue.ID?) {
            out.append(MobileAlert(id: UUID().uuidString, createdAt: now, title: title, body: body, issue: issue?.rawValue))
        }
        for issue in issues where issue.archivedAt == nil {
            guard previous[issue.id] != nil || issue.state == .awaitingApproval else { continue }
            guard previous[issue.id] != issue.state ||
                    (issue.state == .awaitingApproval && proposalVersions[issue.id] != issue.proposal?.version) else { continue }
            switch issue.state {
            case .awaitingApproval: add("제안을 승인해 주세요", issue.title, issue.id)
            case .done where !issue.confirmed: add("결과가 나왔어요", issue.title, issue.id)
            case .failed: add("이슈가 멈췄어요", issue.title, issue.id)
            case .needsInput: add("Hird가 기다려요", firstLine(issue.detail).map { "\(issue.title) · \($0)" } ?? issue.title, issue.id)
            default: break
            }
        }
        for question in questions where question.isPending && !seenQuestions.contains(question.id) && question.askedAt >= since {
            add("질문이 왔어요", question.prompt, question.issue)
        }
        if replyExpected, let reply = replies.last(where: { !seenMessages.contains($0.id) }), case .stallari(let text, _) = reply.kind {
            add("Stallari 답변", text, nil)
            replyExpected = false
        }
        return out
    }

    private func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
