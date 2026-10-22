import Foundation

/// Events identify a displayed message; native code resolves all authority from the current model.
public struct MobileWebEvent: Codable, Sendable {
    public var session: String
    public var thread: String
    public var action: String
    public var message: String
    public var text: String?
    public var selected: [String]?
    public var index: Int?
    public init(session: String, thread: String, action: String, message: String,
                text: String? = nil, selected: [String]? = nil, index: Int? = nil) {
        self.session = session; self.thread = thread; self.action = action; self.message = message
        self.text = text; self.selected = selected; self.index = index
    }
}

public enum MobileWebCommand: Equatable, Sendable {
    case send(text: String, thread: String, project: String?)
    case answer(question: String, selected: [String], text: String?)
    case cancelQuestion(String), open(String), copy(String), edit(String), state(String), link(URL)
    case preview(message: String, index: Int), cancelPending(String)
}

public enum MobileWebBridge {
    public static func viewportData(_ raw: [String: Any], session: String, thread: String) -> Data? {
        guard raw["action"] as? String == "viewport", raw["session"] as? String == session,
              raw["thread"] as? String == thread, let state = raw["state"] as? [String: Any],
              state["following"] is Bool, JSONSerialization.isValidJSONObject(state),
              let bytes = try? JSONSerialization.data(withJSONObject: state), bytes.count <= 131_072 else { return nil }
        return bytes
    }
    public static let viewportID = "00000000-0000-0000-0000-000000000001"
    @MainActor public static func command(_ event: MobileWebEvent, session: String, thread: String,
                                         model: MobileClientModel) -> MobileWebCommand? {
        guard event.session == session, event.thread == thread else { return nil }
        let text = event.text ?? ""
        guard text.utf8.count <= 32_768 else { return nil }
        if event.action == "state", event.message == viewportID { return .state(viewportID) }
        if event.action == "cancelPending" {
            guard let request = model.requestByID[event.message] else { return nil }
            let target: String
            switch request.kind {
            case .threadMessage(_, let id, _, _): target = id
            case .message: target = ConversationID.main
            default: return nil
            }
            guard thread == "all" || target == thread else { return nil }
            return .cancelPending(request.id)
        }
        guard let message = model.messageByID[event.message],
              thread == "all" || (message.thread ?? ConversationID.main) == thread else { return nil }
        switch event.action {
        case "continue":
            guard message.role == .stallari,
                  message.text.range(of: #"(?m)^ {0,3}(`{3,}|~{3,})openui(?:-lang)?[ \t]*$"#, options: .regularExpression) != nil,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .send(text: text, thread: message.thread ?? ConversationID.main, project: message.project)
        case "answer", "cancelQuestion":
            guard message.role == .question, let id = message.question, let q = model.questions[id],
                  q.issue == message.issue, q.state == .pending, !model.isAwaitingMac(question: id) else { return nil }
            if event.action == "cancelQuestion" { return .cancelQuestion(id) }
            let selected = event.selected ?? []
            let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Set(selected).count == selected.count, selected.allSatisfy(q.options.contains),
                  q.allowsMultiple || selected.count <= 1,
                  !selected.isEmpty || !note.isEmpty else { return nil }
            return .answer(question: id, selected: selected, text: note.isEmpty ? nil : note)
        case "open":
            guard let id = message.issue, model.issues[id] != nil else { return nil }
            return .open(id)
        case "copy": return .copy(message.text)
        case "copyText": return .copy(text)
        case "edit": return message.role == .user ? .edit(message.text) : nil
        case "state": return .state(message.id)
        case "preview":
            guard let index = event.index, let attachments = message.attachments, attachments.indices.contains(index) else { return nil }
            return .preview(message: message.id, index: index)
        case "link":
            guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased()),
                  url.user == nil, url.password == nil else { return nil }
            return .link(url)
        default: return nil
        }
    }
}
