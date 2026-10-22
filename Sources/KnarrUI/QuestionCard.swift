import SwiftUI
import KnarrCore

/// A question from Hird or Stallari. Pending: pick an option and/or type, then send or close.
/// Resolved: one quiet line saying what was decided.
struct QuestionCard: View {
    let question: Question
    /// Shown in the conversation, where the card needs to say which Issue it is about.
    var issueTitle: String?
    let answer: (QuestionAnswer) -> Void
    let cancel: () -> Void

    @State private var picked: [String] = []
    @State private var text = ""

    var body: some View {
        switch question.state {
        case .pending: pending
        case .answered(let a): resolved("checkmark.circle", K.green, "\(question.asker) 질문에 답함 · \(Self.summary(a))")
        case .cancelled: resolved("xmark.circle", K.faint, "\(question.asker) 질문 닫음")
        case .unavailable: resolved("exclamationmark.triangle", K.amber, question.extensionIdentity == nil
            ? "\(question.asker)의 실행이 끝나 답을 보낼 수 없어요. 이슈에서 재작업을 요청해 주세요."
            : "확장 연결이 바뀌어 이전 질문에 답을 보낼 수 없어요.")
        }
    }

    /// A decision is asked of the person: the accent bar and icon say so, nothing is filled.
    private var pending: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(K.accent).frame(width: 2)
            VStack(alignment: .leading, spacing: K.s3) {
                HStack(spacing: K.s2) {
                    Image(systemName: "questionmark.circle").font(K.secondary).foregroundStyle(K.accent)
                    Text("\(question.asker)가 묻고 있어요").font(K.secondary.weight(.semibold))
                    if let issueTitle {
                        Text(issueTitle).font(K.secondary).foregroundStyle(K.muted).lineLimit(1)
                    }
                    Spacer()
                    Text(question.askedAt.formatted(date: .omitted, time: .shortened))
                        .font(K.caption).foregroundStyle(K.faint)
                }
                Text(question.prompt).font(K.body).lineSpacing(K.bodyLineSpacing).textSelection(.enabled)

                if !question.options.isEmpty {
                    FlowRow(spacing: K.s2) {
                        ForEach(question.options, id: \.self) { option in
                            let on = picked.contains(option)
                            Button { toggle(option) } label: {
                                Text(option)
                                    .font(K.secondary.weight(on ? .semibold : .regular))
                                    .foregroundStyle(K.ink)
                                    .padding(.horizontal, K.s3).padding(.vertical, K.s1)
                                    .background(on ? K.accentSoft : K.surface, in: RoundedRectangle(cornerRadius: K.rSmall))
                                    .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(on ? K.accent : K.lineStrong))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }

                if question.replyStyle != .select && question.replyStyle != .confirm {
                    if question.replyStyle == .editor {
                        TextEditor(text: $text).font(K.secondary).frame(minHeight: 90, maxHeight: 180)
                            .scrollContentBackground(.hidden).padding(K.s2)
                            .background(K.surface, in: RoundedRectangle(cornerRadius: K.rSmall))
                            .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.lineStrong))
                    } else {
                        TextField("", text: $text,
                                  prompt: Text(question.placeholder ?? (question.options.isEmpty ? "답을 적어 주세요" : "덧붙일 말 (선택)")).foregroundStyle(K.faint),
                                  axis: .vertical)
                            .textFieldStyle(.plain).font(K.secondary).lineLimit(1...4)
                            .padding(.horizontal, K.s3).padding(.vertical, K.s2)
                            .background(K.surface, in: RoundedRectangle(cornerRadius: K.rSmall))
                            .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.lineStrong))
                            .onSubmit(send)
                    }
                }

                HStack(spacing: K.s2) {
                    KButton(title: "보내기", style: .primary, enabled: canSend, action: send)
                    KButton(title: "질문 닫기", action: cancel)
                    Spacer()
                    if question.allowsMultiple {
                        Text("여러 개 고를 수 있어요").font(K.caption).foregroundStyle(K.faint)
                    }
                }
            }
            .padding(.leading, K.s3).padding(.vertical, K.s1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if let prefill = question.prefill { text = prefill } }
    }

    private func resolved(_ symbol: String, _ color: Color, _ line: String) -> some View {
        HStack(spacing: K.s2) {
            Image(systemName: symbol).font(K.secondary).foregroundStyle(color)
            Text(line).font(K.secondary).foregroundStyle(K.muted).lineLimit(2)
            Spacer()
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool {
        switch question.replyStyle {
        case .select, .confirm: !picked.isEmpty
        case .input, .editor: true
        case nil: !picked.isEmpty || !trimmed.isEmpty
        }
    }

    private func toggle(_ option: String) {
        if picked.contains(option) {
            picked.removeAll { $0 == option }
        } else {
            picked = question.allowsMultiple ? picked + [option] : [option]
        }
    }

    private func send() {
        guard canSend else { return }
        answer(QuestionAnswer(selectedOptions: picked, text: question.replyStyle == nil ? (trimmed.isEmpty ? nil : trimmed) : text))
    }

    static func summary(_ a: QuestionAnswer) -> String {
        (a.selectedOptions + [a.text].compactMap { $0 }).joined(separator: " · ")
    }
}
