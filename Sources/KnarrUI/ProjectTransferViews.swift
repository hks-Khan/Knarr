import SwiftUI
import KnarrCore
import QuickLook

/// Captured only when the user opens the sheet, never rebuilt while rendering history.
struct ProjectTransferSelection: Identifiable {
    let id = UUID()
    let requestID: UUID
    let messages: [ChatItem]

    static func capture(_ chat: [ChatItem], streamingID: UUID?) -> Self? {
        guard let index = chat.lastIndex(where: { if case .user = $0.kind { return true }; return false }) else { return nil }
        let messages = chat[index...].filter { item in
            guard item.id != streamingID else { return false }
            switch item.kind { case .user, .stallari: return true; default: return false }
        }
        return .init(requestID: chat[index].id, messages: messages)
    }

    static func text(_ item: ChatItem) -> String {
        switch item.kind { case .user(let text), .stallari(let text, _): return text; default: return "" }
    }
}

struct ProjectTransferSheet: View {
    let store: any KnarrStore
    let selection: ProjectTransferSelection
    @Environment(\.dismiss) private var dismiss
    @State private var summary = ""
    @State private var submitting = false
    @State private var error: String?
    @State private var previewURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: K.s4) {
            Text("메인으로 전달").font(K.title)
            Text("저장된 원본 요청과 요약을 메인에 전달합니다. 전달은 실행 승인이 아니며, 기존 이슈의 소유권과 제안 버전은 바뀌지 않습니다.")
                .font(K.secondary).foregroundStyle(K.muted)
            Text("전달 요약").font(K.caption).foregroundStyle(K.muted)
            TextEditor(text: $summary).font(K.body).frame(minHeight: K.headerHeight)
                .padding(K.s2).overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.lineStrong))
                .accessibilityIdentifier("project-transfer-summary")
            Text("저장된 원본 · 읽기 전용").font(K.caption).foregroundStyle(K.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: K.s4) {
                    ForEach(selection.messages) { item in
                        VStack(alignment: .leading, spacing: K.s1) {
                            Text(item.id == selection.requestID ? "사용자 원본 요청" : "관련 답변").font(K.caption).foregroundStyle(K.muted)
                            Text(ProjectTransferSelection.text(item)).font(K.secondary).textSelection(.enabled)
                            Text(item.id.uuidString).font(K.mono).foregroundStyle(K.faint).textSelection(.enabled)
                            ForEach(item.attachments, id: \.self) { url in
                                Button { previewURL = url } label: { Label(url.lastPathComponent, systemImage: "paperclip") }
                                    .buttonStyle(.link).font(K.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(error).font(K.secondary).foregroundStyle(K.red).textSelection(.enabled) }
            HStack {
                Spacer()
                KButton(title: "취소", enabled: !submitting) { dismiss() }
                KButton(title: submitting ? "저장 중…" : "전달 요청 저장", style: .primary,
                        enabled: !submitting && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isResponding && store.assistantPersistenceError == nil) {
                    submitting = true
                    Task {
                        do {
                            _ = try await store.transferToMain(summary: summary, requestMessageID: selection.requestID, messageIDs: selection.messages.map(\.id))
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        submitting = false
                    }
                }
            }
        }
        .padding(K.s5).frame(width: K.column, height: K.column)
        .quickLookPreview($previewURL)
    }
}

struct ProjectTransferCards: View {
    let store: any KnarrStore
    let transfers: [ProjectTransfer]
    let navigate: (ProjectTransfer, Bool) -> Void
    let preview: (URL) -> Void
    @State private var retrying: Set<String> = []
    @State private var retryError: String?

    var body: some View {
        if !transfers.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: K.s3) {
                    ForEach(transfers) { transfer in
                        VStack(alignment: .leading, spacing: K.s2) {
                            HStack {
                                Text(transfer.projectName).font(K.secondary.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text(status(transfer)).font(K.caption).foregroundStyle(tint(transfer))
                            }
                            Text(transfer.summary).font(K.secondary).textSelection(.enabled)
                            DisclosureGroup("사용자 원본 요청 · 실행 승인 아님") {
                                Text(transfer.requestText).font(K.secondary).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("원본 요청: \(transfer.requestMessageID.uuidString)").font(K.mono).foregroundStyle(K.faint).textSelection(.enabled)
                            }.font(K.caption).foregroundStyle(K.muted)
                            Text("전달 ID: \(transfer.id)").font(K.mono).foregroundStyle(K.faint).textSelection(.enabled)
                            ForEach(transfer.attachments.indices, id: \.self) { index in
                                let attachment = transfer.attachments[index]
                                Button { preview(attachment.url) } label: { Label(attachment.url.lastPathComponent, systemImage: "paperclip") }
                                    .buttonStyle(.link).font(K.secondary)
                                    .help("원본 메시지: " + attachment.messageID.uuidString)
                            }
                            if let error = transfer.lastError { Text(error).font(K.secondary).foregroundStyle(K.red) }
                            HStack {
                                KButton(title: "원본 요청으로 이동", style: .link) { navigate(transfer, false) }
                                if transfer.state == .delivered {
                                    KButton(title: "메인으로 이동", style: .link) { navigate(transfer, true) }
                                }
                                if transfer.state == .failed {
                                    KButton(title: "같은 요청 다시 전달", style: .link, enabled: !retrying.contains(transfer.id)) {
                                        retrying.insert(transfer.id)
                                        Task {
                                            do { try await store.retryProjectTransfer(transfer.id) }
                                            catch { retryError = error.localizedDescription }
                                            retrying.remove(transfer.id)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(K.s3).background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
                        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
                        .accessibilityIdentifier("project-transfer-card-" + transfer.id)
                    }
                    if let retryError { Text(retryError).font(K.secondary).foregroundStyle(K.red) }
                }.padding(K.s3)
            }.frame(maxHeight: K.column / 3)
        }
    }

    private func status(_ transfer: ProjectTransfer) -> String {
        switch transfer.state { case .pending: "전달 대기 · 요청 저장됨"; case .delivered: "메인 접수 완료"; case .failed: "전달 실패 · 원본 보존" }
    }
    private func tint(_ transfer: ProjectTransfer) -> Color {
        switch transfer.state { case .pending: K.amber; case .delivered: K.green; case .failed: K.red }
    }
}
