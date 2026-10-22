import SwiftUI
import KnarrCore

struct PreparationItemEditor: View {
    let store: any KnarrStore
    let project: ProjectSummary
    let item: PreparationItem?
    let candidates: [Issue]
    let documents: [ProjectDocument]
    let saved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fields: PreparationItem.Fields
    @State private var sourceID = ""
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var problem: String?
    @State private var busy = false
    @State private var id: String
    @State private var revision: Int
    @State private var initialized = false

    init(store: any KnarrStore, project: ProjectSummary, item: PreparationItem?, candidates: [Issue], documents: [ProjectDocument], saved: @escaping (String) -> Void) {
        self.store = store; self.project = project; self.item = item; self.candidates = candidates; self.documents = documents; self.saved = saved
        _fields = State(initialValue: item?.fields ?? .init())
        _hasDeadline = State(initialValue: item?.fields.deadline != nil)
        _deadline = State(initialValue: item?.fields.deadline ?? .now)
        _id = State(initialValue: item?.id ?? "prep-" + UUID().uuidString.lowercased())
        _revision = State(initialValue: item?.revision ?? 0)
    }
    var body: some View {
        PreparationEditorFrame(title: item == nil ? (candidates.isEmpty ? "공고 추가" : "기존 후보 옮기기") : "공고 수정", busy: busy, problem: problem,
            canSave: !fields.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, cancel: { dismiss() }, save: save) {
            if !candidates.isEmpty {
                Picker("기존 후보", selection: $sourceID) {
                    Text("후보 선택").tag("")
                    ForEach(candidates) { source in Text(source.title).tag(source.id.rawValue) }
                }.onChange(of: sourceID) { _, value in loadSource(value) }
                Text("이전 후보 내용과 대화 기록을 보존해요.").font(K.caption).foregroundStyle(K.muted)
            }
            TextField("회사·기관", text: $fields.organization).accessibilityIdentifier("preparation-organization")
            TextField("공고·직무", text: $fields.title).accessibilityIdentifier("preparation-title")
            HStack(spacing: K.s4) {
                Toggle("마감", isOn: $hasDeadline).fixedSize()
                if hasDeadline { DatePicker("마감 시각", selection: $deadline, displayedComponents: [.date, .hourAndMinute]).labelsHidden() }
                Spacer(minLength: K.s2)
                Toggle("최우선", isOn: $fields.priority).fixedSize()
            }
            TextField("준비 메모", text: $fields.memo, axis: .vertical).lineLimit(2...5)
                .accessibilityIdentifier("preparation-memo")
            PreparationTextEditor(title: "공고 내용", text: $fields.posting)
            Picker("제출 여부", selection: $fields.submission) {
                ForEach(PreparationItem.Submission.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if !documents.isEmpty || !fields.documentPaths.isEmpty {
                DisclosureGroup("연결 문서") {
                    VStack(alignment: .leading, spacing: K.s2) {
                        ForEach(Array(Set(documents.map(\.relativePath) + fields.documentPaths)).sorted(), id: \.self) { path in
                            Toggle(path, isOn: Binding(get: { fields.documentPaths.contains(path) }, set: { on in
                                if on { fields.documentPaths.append(path) } else { fields.documentPaths.removeAll { $0 == path } }
                            }))
                        }
                    }.padding(.top, K.s2)
                }
            }
            if let current = store.preparationItems.first(where: { $0.id == id }), current.revision != revision {
                DisclosureGroup("다른 곳에서 저장한 내용") {
                    VStack(alignment: .leading, spacing: K.s2) {
                        Text(current.heading).font(K.secondary.weight(.semibold))
                        Text(current.fields.memo).font(K.secondary).textSelection(.enabled)
                        PreparationMarkdown(text: current.fields.posting)
                        KButton(title: "입력한 내용으로 다시 저장") { revision = current.revision; save() }
                    }.padding(.top, K.s2)
                }
            }
        }.onAppear {
            guard !initialized else { return }; initialized = true
            if let first = candidates.first { sourceID = first.id.rawValue; loadSource(sourceID) }
        }
    }
    private func loadSource(_ id: String) {
        guard let source = candidates.first(where: { $0.id.rawValue == id }) else { return }
        fields = .init(title: source.title, memo: source.detail, posting: source.proposal?.instruction ?? source.detail)
        hasDeadline = false
    }
    private func save() {
        guard !busy else { return }
        busy = true; problem = nil
        fields.deadline = hasDeadline ? deadline : nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let value = try await store.savePreparation(id: id, projectID: project.id, fields: fields,
                    expectedRevision: revision, sourceIssueID: item?.sourceIssueID ?? (sourceID.isEmpty ? nil : Issue.ID(sourceID)))
                saved(value.id); dismiss()
            } catch { problem = preparationProblem(error) }
        }
    }
}

struct PreparationDraftEditor: View {
    let store: any KnarrStore
    let item: PreparationItem
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String
    @State private var kind: PreparationItem.Draft.Kind = .draft
    @State private var problem: String?
    @State private var busy = false
    @State private var revision: Int
    let documentID: String
    init(store: any KnarrStore, item: PreparationItem, draft: PreparationItem.Draft?) {
        self.store = store; self.item = item
        documentID = draft?.documentID ?? UUID().uuidString.lowercased()
        _title = State(initialValue: draft?.title ?? "")
        _text = State(initialValue: draft?.text ?? "")
        _revision = State(initialValue: item.revision)
    }
    var body: some View {
        PreparationEditorFrame(title: "작성본 저장", busy: busy, problem: problem,
            canSave: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            cancel: { dismiss() }, save: save) {
            Text(item.heading).font(K.secondary).foregroundStyle(K.muted)
            TextField("작성본 제목", text: $title).accessibilityIdentifier("preparation-draft-title")
            Picker("종류", selection: $kind) {
                ForEach(PreparationItem.Draft.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            PreparationTextEditor(title: "내용", text: $text)
            if kind == .submitted { Text("실제로 제출한 내용만 제출본으로 저장해 주세요.").font(K.caption).foregroundStyle(K.muted) }
            if let current = store.preparationItems.first(where: { $0.id == item.id }), current.revision != revision {
                Text("다른 곳에서 자료가 추가됐어요. 입력한 내용은 새 버전으로 남길 수 있어요.").font(K.secondary).foregroundStyle(K.muted)
                KButton(title: "최신 기록 뒤에 저장") { revision = current.revision; save() }
            }
        }
    }
    private func save() {
        guard !busy else { return }; busy = true; problem = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await store.savePreparationDraft(itemID: item.id, projectID: item.projectID, expectedRevision: revision,
                    documentID: documentID, title: title, text: text, kind: kind)
                dismiss()
            } catch { problem = preparationProblem(error) }
        }
    }
}

struct PreparationRecordEditor: View {
    let store: any KnarrStore
    let item: PreparationItem
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var submission = ""
    @State private var problem: String?
    @State private var busy = false
    @State private var revision: Int
    init(store: any KnarrStore, item: PreparationItem) { self.store = store; self.item = item; _revision = State(initialValue: item.revision) }
    var body: some View {
        PreparationEditorFrame(title: "진행 기록", busy: busy, problem: problem,
            canSave: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, cancel: { dismiss() }, save: save) {
            Text(item.heading).font(K.secondary).foregroundStyle(K.muted)
            PreparationTextEditor(title: "진행 내용·결과", text: $text)
            Picker("제출 여부", selection: $submission) {
                Text("변경 없음").tag("")
                ForEach(PreparationItem.Submission.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
            if let current = store.preparationItems.first(where: { $0.id == item.id }), current.revision != revision {
                Text("새 기록이 저장됐어요. 입력한 내용은 이어서 남길 수 있어요.").font(K.secondary).foregroundStyle(K.muted)
                KButton(title: "최신 기록 뒤에 저장") { revision = current.revision; save() }
            }
        }
    }
    private func save() {
        guard !busy else { return }; busy = true; problem = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await store.addPreparationRecord(itemID: item.id, projectID: item.projectID, expectedRevision: revision,
                    text: text, submission: PreparationItem.Submission(rawValue: submission))
                dismiss()
            } catch { problem = preparationProblem(error) }
        }
    }
}

private struct PreparationEditorFrame<Content: View>: View {
    let title: String
    let busy: Bool
    let problem: String?
    let canSave: Bool
    let cancel: () -> Void
    let save: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: K.s4) {
            Text(title).font(K.title)
            ScrollView {
                VStack(alignment: .leading, spacing: K.s4) { content() }
                    .font(K.secondary).textFieldStyle(.roundedBorder)
                    .disabled(busy).padding(.vertical, K.s1)
            }
            if let problem { Text(problem).font(K.secondary).foregroundStyle(K.red).textSelection(.enabled) }
            HStack(spacing: K.s3) {
                Spacer(minLength: K.s2)
                Button("취소", action: cancel).keyboardShortcut(.cancelAction).disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Button("저장", action: save).disabled(!canSave || busy)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("preparation-save")
            }.font(K.secondary)
        }.padding(K.s5).frame(width: K.preparationEditorWidth, height: K.preparationEditorHeight)
            .background(K.surface).interactiveDismissDisabled(busy)
    }
}

private struct PreparationTextEditor: View {
    let title: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: K.s2) {
            Text(title).font(K.caption).foregroundStyle(K.muted)
            TextEditor(text: $text).font(K.body).scrollContentBackground(.hidden)
                .padding(K.s2).frame(minHeight: K.preparationTextEditorHeight)
                .background(K.canvas, in: RoundedRectangle(cornerRadius: K.rSmall))
                .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.lineStrong))
                .accessibilityLabel(title)
        }
    }
}

private func preparationProblem(_ error: any Error) -> String {
    guard let failure = error as? PersistenceError else { return error.localizedDescription }
    return failure.sqliteCode == nil ? failure.message : "저장하지 못했어요. 입력한 내용은 남아 있어요. 다시 저장해 주세요."
}
