import AppKit
import Observation
import SwiftUI
import KnarrCore
import UniformTypeIdentifiers

/// Selecting context never submits a message or discards a conversation's draft.
@MainActor enum ProjectConversationRequest {
    @discardableResult static func prepare(store: any KnarrStore, projectID: String, text: String) -> Bool {
        guard let project = store.project(projectID), !project.archived else { return false }
        store.selectProjectConversation(projectID)
        guard store.threads.first(where: { $0.id == store.selectedThreadID })?.projectID == projectID else { return false }
        var draft = store.composerDraft
        draft.text += (draft.text.isEmpty ? "" : "\n\n") + text
        draft.project = projectID
        store.composerDraft = draft
        return true
    }
}

struct ProjectDocumentGroup: Identifiable, Sendable {
    let id: String
    var documents: [ProjectDocument]
}

@MainActor @Observable final class ProjectDocumentsModel {
    private(set) var library: ProjectDocumentLibrary?
    private(set) var groups: [ProjectDocumentGroup] = []
    private(set) var recent: [ProjectDocument] = []
    private(set) var blocks: [MarkdownBlock] = []
    private(set) var selected: ProjectDocument?
    private(set) var loading = false
    var query = ""
    var selectedPath: String?
    private var generation = 0

    func reload(root: URL) async {
        generation += 1
        let request = generation
        loading = true
        let value = await ProjectDocumentLibrary.read(root: root)
        guard !Task.isCancelled, request == generation else { return }
        library = value
        recent = Array(value.documents.prefix(5))
        loading = false
        await search()
        guard !Task.isCancelled, request == generation else { return }
        await select(selectedPath ?? value.documents.first?.relativePath)
    }

    func search() async {
        guard let library else { return }
        let query = query
        let request = generation
        let grouped = await Task.detached(priority: .userInitiated) {
            var grouped: [ProjectDocumentGroup] = []
            var indices: [String: Int] = [:]
            for document in library.search(query) {
                let folder = (document.relativePath as NSString).deletingLastPathComponent
                if let index = indices[folder] { grouped[index].documents.append(document) }
                else {
                    indices[folder] = grouped.count
                    grouped.append(.init(id: folder, documents: [document]))
                }
            }
            return grouped
        }.value
        guard !Task.isCancelled, query == self.query, request == generation else { return }
        groups = grouped
    }

    func select(_ path: String?) async {
        selectedPath = path
        selected = library?.documents.first { $0.relativePath == path }
        blocks = []
        guard let document = selected else { return }
        let request = generation
        let parsed = await Task.detached(priority: .userInitiated) { MarkdownBlocks.parse(document.text) }.value
        guard !Task.isCancelled, selectedPath == document.relativePath, request == generation,
              selected?.text == document.text else { return }
        blocks = parsed
    }
}

struct ProjectDocuments: View {
    let project: ProjectSummary
    @Bindable var model: ProjectDocumentsModel
    let reload: () async -> Void
    let ask: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: K.s3) {
                TextField("이름과 본문 검색", text: $model.query)
                    .textFieldStyle(.roundedBorder).font(K.secondary)
                    .accessibilityIdentifier("project-document-search")
                if model.loading { ProgressView().controlSize(.small) }
                KButton(title: "다시 읽기") { Task { await reload() } }
            }
            .padding(K.s4)
            Divider().overlay(K.line)
            if let problem = model.library?.problem {
                Text(problem).font(K.secondary).foregroundStyle(K.red).padding(K.s4)
            }
            GeometryReader { geometry in
                if geometry.size.width >= K.projectListWidth + K.projectDetailMinimumWidth {
                    HStack(spacing: 0) {
                        list.frame(width: K.projectListWidth)
                        Divider().overlay(K.line)
                        reader
                    }
                } else {
                    VStack(spacing: 0) {
                        list.frame(height: K.documentCompactListHeight)
                        Divider().overlay(K.line)
                        reader
                    }
                }
            }
        }
        .task(id: model.query) { await model.search() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: K.s2) {
                ForEach(model.groups) { group in
                    Text(group.id.isEmpty ? "프로젝트 루트" : group.id)
                        .font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
                        .padding(.top, K.s2)
                    ForEach(group.documents) { document in
                        Button { Task { await model.select(document.relativePath) } } label: {
                            VStack(alignment: .leading, spacing: K.s1) {
                                Text((document.relativePath as NSString).lastPathComponent)
                                    .font(K.secondary.weight(.medium)).foregroundStyle(K.ink).lineLimit(2)
                                Text(document.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(K.caption).foregroundStyle(K.faint)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(K.s2)
                            .background(model.selectedPath == document.relativePath ? K.sunken : .clear,
                                        in: RoundedRectangle(cornerRadius: K.rSmall))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("project-document-" + document.relativePath)
                        .accessibilityAddTraits(model.selectedPath == document.relativePath ? .isSelected : [])
                    }
                }
                if model.groups.isEmpty && !model.loading {
                    Text(model.query.isEmpty ? "Markdown 문서가 없어요" : "검색 결과가 없어요")
                        .font(K.secondary).foregroundStyle(K.faint).padding(.vertical, K.s4)
                }
            }
            .padding(K.s3)
        }
        .background(K.surface)
    }

    @ViewBuilder private var reader: some View {
        if let document = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: K.s2) {
                    Text(document.relativePath).font(K.mono).foregroundStyle(K.ink).textSelection(.enabled)
                    FlowRow(spacing: K.s3) {
                        Text(status(document)).foregroundStyle(document.gitStatus == .clean ? K.muted : K.amber)
                        Text("수정 " + document.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(K.faint)
                    }
                    .font(K.caption)
                    FlowRow(spacing: K.s2) {
                        KButton(title: "Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url(document)]) }
                        KButton(title: "편집기로 열기") { NSWorkspace.shared.open(url(document)) }
                        KButton(title: "경로 복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url(document).path, forType: .string)
                        }
                        KButton(title: "Stallari에게 묻기", enabled: !project.archived) { ask(document.relativePath) }
                    }
                }
                .padding(K.s4)
                Divider().overlay(K.line)
                ScrollView {
                    MarkdownBlocksView(blocks: model.blocks, scale: .body)
                        .equatable().textSelection(.enabled)
                        .frame(maxWidth: K.column, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(K.s5)
                }
                .id(document.relativePath)
                .accessibilityIdentifier("project-document-body")
            }
        } else {
            Text(model.loading ? "문서를 읽는 중" : "문서를 선택해 주세요")
                .font(K.secondary).foregroundStyle(K.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func url(_ document: ProjectDocument) -> URL {
        URL(fileURLWithPath: project.path, isDirectory: true).appendingPathComponent(document.relativePath)
    }
    private func status(_ document: ProjectDocument) -> String {
        switch document.gitStatus {
        case .clean: "커밋됨"
        case .uncommitted: "커밋 안 됨"
        case .new: "새 파일"
        }
    }
}

/// macOS resolves the user's default application; folder actions do not execute a shell command.
enum ProjectFolderActions {
    @MainActor static func terminal(_ path: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
    @MainActor static func editor(_ path: String) {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let editor = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode"]
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        let chosen: URL?
        if let editor {
            chosen = editor
        } else {
            let panel = NSOpenPanel()
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            panel.allowedContentTypes = [.application]
            panel.prompt = "편집기로 열기"
            panel.message = "프로젝트 폴더를 열 편집기를 선택해 주세요"
            chosen = panel.runModal() == .OK ? panel.url : nil
        }
        guard let editor = chosen else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}
