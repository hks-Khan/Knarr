import Foundation

// Storage wire types keep serialization changes out of the KnarrStore/UI contract.
struct StoredChat: Codable {
    let link: ChatLink
    let at: Date
    let kind: Kind
    var activity: ChatActivity?
    var conversationRootID: UUID?
    var preparationID: String?
    var isConversationLink: Bool?
    var attachments: [URL]?
    var actionVersion: Int?
    var actionNote: String?
    enum Kind: Codable {
        case day(String), user(String), stallari(String, project: String?), issue(Issue.ID)
        case autoCheck(summary: String, lines: [String])
        case notice(tone: String, title: String, body: String, issue: Issue.ID, label: String?, action: String?)
        case question(String)
        case proposal(Issue.ID, version: Int)
        /// A derived report card; normally synthesized, stored only if one is ever appended.
        case report(String)
    }
    init(_ item: ChatItem, link: ChatLink) {
        conversationRootID = item.conversationRootID
        preparationID = item.preparationID
        isConversationLink = item.isConversationLink ? true : nil
        self.link = link; at = item.at; activity = item.activity; attachments = item.attachments.isEmpty ? nil : item.attachments
        switch item.kind {
        case .day(let s): kind = .day(s)
        case .user(let s): kind = .user(s)
        case .stallari(let s, let project): kind = .stallari(s, project: project)
        case .issue(let id): kind = .issue(id)
        case .proposal(let id, let version): kind = .proposal(id, version: version)
        case .autoCheck(let summary, let lines): kind = .autoCheck(summary: summary, lines: lines)
        case .notice(let n):
            let tone: String
            switch n.tone { case .needsInput: tone = "needsInput"; case .failed: tone = "failed"; case .result: tone = "result" }
            let action = n.primary.map { b in
                switch b.action {
                case .confirmResult: "confirmResult"
                case .confirmAppResult: "confirmAppResult"
                case .closeIssue: "closeIssue"
                case .requestChanges: "requestChanges"
                case .resolvedInput: "resolvedInput"
                case .approveProposal: "approveProposal"
                case .requestProposalChanges: "requestProposalChanges"
                case .rejectProposal: "rejectProposal"
                case .stop: "stop"
                case .resume: "resume"
                }
            }
            kind = .notice(tone: tone, title: n.title, body: n.body, issue: n.issue, label: n.primary?.label, action: action)
            switch n.primary?.action {
            case .approveProposal(let version): actionVersion = version
            case .requestProposalChanges(let version, let note), .rejectProposal(let version, let note):
                actionVersion = version; actionNote = note
            case .confirmAppResult(let note): actionNote = note
            case .requestChanges(let note): actionNote = note.isEmpty ? nil : note
            case .closeIssue(let reason): actionNote = reason.rawValue
            default: break
            }
        case .question(let id): kind = .question(id.rawValue)
        case .report(let id): kind = .report(id)
        }
    }
    func item() throws -> ChatItem {
        let output: ChatItem.Kind
        switch kind {
        case .day(let s): output = .day(s)
        case .user(let s): output = .user(s)
        case .stallari(let s, let p):
            if let issueID = link.issueID, s.hasPrefix("이슈 인계 issueID=" + issueID.rawValue + " originThreadID="),
               let start = s.range(of: "\n요약: "), let end = s.range(of: "\n완료 조건:\n", range: start.upperBound..<s.endIndex),
               s.contains("\n정확한 저장 제안: ") {
                output = .stallari(String(s[start.upperBound..<end.lowerBound]), project: p)
            } else { output = .stallari(s, project: p) }
        case .issue(let id): output = .issue(id)
        case .proposal(let id, let version): output = .proposal(id, version: version)
        case .autoCheck(let s, let lines): output = .autoCheck(summary: s, lines: lines)
        case .notice(let t, let title, let body, let issue, let label, let a):
            let tone: Notice.Tone
            switch t {
            case "needsInput": tone = .needsInput
            case "failed": tone = .failed
            case "result": tone = .result
            default: throw CodingError.unknownValue
            }
            var button: Notice.Button?
            if let label, let a {
                let action: IssueAction
                switch a {
                case "confirmResult": action = .confirmResult
                case "confirmAppResult":
                    guard let actionNote else { throw CodingError.unknownValue }
                    action = .confirmAppResult(note: actionNote)
                case "closeIssue":
                    guard let actionNote, let reason = IssueCloseReason(rawValue: actionNote) else { throw CodingError.unknownValue }
                    action = .closeIssue(reason: reason)
                case "requestChanges": action = .requestChanges(note: actionNote ?? "")
                case "resolvedInput": action = .resolvedInput
                case "approveProposal":
                    guard let actionVersion else { throw CodingError.unknownValue }
                    action = .approveProposal(version: actionVersion)
                case "requestProposalChanges":
                    guard let actionVersion, let actionNote else { throw CodingError.unknownValue }
                    action = .requestProposalChanges(version: actionVersion, note: actionNote)
                case "rejectProposal":
                    guard let actionVersion, let actionNote else { throw CodingError.unknownValue }
                    action = .rejectProposal(version: actionVersion, note: actionNote)
                case "stop": action = .stop
                case "resume": action = .resume
                default: throw CodingError.unknownValue
                }
                button = .init(label, action)
            } else if label != nil || a != nil { throw CodingError.unknownValue }
            output = .notice(.init(tone: tone, title: title, body: body, issue: issue, primary: button))
        case .question(let id): output = .question(Question.ID(id))
        case .report(let id): output = .report(id)
        }
        var item = ChatItem(id: link.chatID, at: at, kind: output)
        item.attachments = attachments ?? []
        item.activity = activity
        item.conversationRootID = conversationRootID
        item.preparationID = preparationID
        item.isConversationLink = isConversationLink ?? false
        return item
    }
    private enum CodingError: Error { case unknownValue }
}
