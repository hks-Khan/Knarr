import KnarrSync
import SwiftUI

/// A question Hird or Stallari is waiting on, answered with the same choices the Mac card offers.
struct QuestionCard: View {
    let store: PhoneStore
    let question: MobileQuestion
    @State private var picked: Set<String> = []
    @State private var text = ""

    private var canSend: Bool {
        !picked.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let waiting = store.model.isAwaitingMac(question: question.id)
        VStack(alignment: .leading, spacing: 10) {
            Text("답변 필요")
                .font(.footnote.weight(.semibold)).foregroundStyle(Palette.accent)
            Text(question.prompt).font(.system(size: 14))
            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        Button { toggle(option) } label: {
                            Label(option, systemImage: picked.contains(option) ? "largecircle.fill.circle" : "circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 14))
                        .padding(.vertical, 6)
                        .foregroundStyle(Palette.ink)
                    }
                    if question.allowsMultiple {
                        Text("여러 개 고를 수 있어요").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TextField(question.options.isEmpty ? "답을 적어 주세요" : "추가 내용 (선택)", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
            if waiting {
                Label("Mac에 전달하는 중이에요", systemImage: "paperplane").font(.footnote).foregroundStyle(Palette.amber)
            } else {
                HStack {
                    Button("답변") { send() }.buttonStyle(.borderedProminent).disabled(!canSend)
                    Button("질문 닫기", role: .destructive) { store.send(.cancelQuestion(question.id)) }.buttonStyle(.bordered)
                }
            }
        }
        .font(.system(size: 14))
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        .disabled(waiting)
    }

    private func toggle(_ option: String) {
        if question.allowsMultiple {
            if picked.contains(option) { picked.remove(option) } else { picked.insert(option) }
        } else {
            picked = picked.contains(option) ? [] : [option]
        }
    }

    private func send() {
        let options = question.options.filter(picked.contains)
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        store.send(.answer(question: question.id, options: options, text: note.isEmpty ? nil : note))
    }
}
