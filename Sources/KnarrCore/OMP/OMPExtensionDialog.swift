import Foundation

/// OMP's existing Hird question sub-protocol, also used by Stallari without a run.
struct OMPExtensionDialog: Sendable, Equatable {
    let rpcID: String
    let method: Question.ReplyStyle
    let prompt: String
    let options: [String]
    let placeholder: String?
    let prefill: String?
    init?(_ frame: OMPJSON) {
        guard let id = frame["id"]?.string, let name = frame["method"]?.string,
              let method = Question.ReplyStyle(rawValue: name) else { return nil }
        rpcID = id; self.method = method
        prompt = (frame["title"]?.string ?? "질문") + (frame["message"]?.string.map { "\n" + $0 } ?? "")
        options = method == .confirm ? ["예", "아니요"] : (frame["options"]?.array?.compactMap(\.string) ?? [])
        placeholder = frame["placeholder"]?.string; prefill = frame["prefill"]?.string
    }
    func response(_ answer: QuestionAnswer?) -> [String: OMPJSON] {
        var fields: [String: OMPJSON] = ["id": .string(rpcID)]
        guard let answer else { fields["cancelled"] = .bool(true); return fields }
        if method == .confirm { fields["confirmed"] = .bool(answer.selectedOptions == ["예"]) }
        else if method == .select { fields["value"] = answer.selectedOptions.first.map(OMPJSON.string) ?? .null }
        else { fields["value"] = .string(answer.text ?? "") }
        return fields
    }
    func accepts(_ answer: QuestionAnswer) -> Bool {
        switch method {
        case .select, .confirm: answer.selectedOptions.count == 1 && options.contains(answer.selectedOptions[0])
        case .input, .editor: answer.selectedOptions.isEmpty
        }
    }
}
