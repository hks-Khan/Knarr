import AppKit
import SwiftUI
import KnarrCore

/// The existing project shell stays intact; this is the preparation overview's content.
struct ProjectPreparationOverview: View {
    let store: any KnarrStore
    let project: ProjectSummary
    let documents: [ProjectDocument]
    let documentChoices: [ProjectDocument]
    let openDocument: (String) -> Void
    let showDocuments: () -> Void
    @State private var selected: String?
    @State private var editor: PreparationEditorRequest?
    @State private var tab = PreparationDetailTab.posting
    @State private var selectedDraftID: String?
    @State private var writingHistory: [PreparationWritingEntry] = []

    private var items: [PreparationItem] { store.preparationItems(inProject: project.id) }
    private var chosen: PreparationItem? { items.first { $0.id == selected } ?? items.first }
    private var candidates: [Issue] {
        store.executionIssues(inProject: project.id).filter { $0.state == .awaitingApproval && $0.hirds.isEmpty && $0.archivedAt == nil }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: K.s5) {
            ProjectCard(title: "지원 현황", subtitle: deadlineHint, accessory: {
                HStack(spacing: K.s2) {
                    if !candidates.isEmpty {
                        KButton(title: "기존 후보 옮기기", enabled: !project.archived) { editor = .init(kind: .importCandidate) }
                    }
                    KButton(title: "공고 추가", enabled: !project.archived) { editor = .init(kind: .item(nil)) }
                        .accessibilityIdentifier("preparation-add")
                }
            }) {
                if items.isEmpty {
                    Text("공고를 추가하거나 기존 후보를 옮겨 준비를 이어가세요.")
                        .font(K.secondary).foregroundStyle(K.muted).padding(K.s4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ViewThatFits(in: .horizontal) {
                        table.frame(minWidth: K.preparationTableMinimumWidth)
                        compactList
                    }
                }
            }
            if let item = chosen {
                PreparationDetail(item: item, tab: $tab, draftID: $selectedDraftID, editable: !project.archived, openDocument: openDocument,
                    edit: { editor = .init(kind: .item(item)) },
                    newDraft: { editor = .init(kind: .draft(item, $0)) },
                    newRecord: { editor = .init(kind: .record(item)) })
                    .id(item.id)
            }
            ProjectCard(title: "작성 기록") {
                VStack(alignment: .leading, spacing: K.s3) {
                    if writingHistory.isEmpty { Text("아직 저장한 작성본이 없어요.").font(K.secondary).foregroundStyle(K.faint) }
                    ForEach(writingHistory) { entry in
                        Button {
                            choose(entry.itemID); selectedDraftID = entry.draft.id; tab = .drafts
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: K.s3) {
                                VStack(alignment: .leading, spacing: K.s1) {
                                    Text(entry.heading).font(K.caption).foregroundStyle(K.muted)
                                    Text(entry.draft.title + " · v\(entry.draft.version) · " + entry.draft.kind.label).font(K.secondary).foregroundStyle(K.ink)
                                }
                                Spacer(minLength: K.s2)
                                Text(entry.draft.savedAt.formatted(date: .abbreviated, time: .shortened)).font(K.caption).foregroundStyle(K.faint)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, K.s4).padding(.bottom, K.s4)
            }
            ProjectCard(title: "최근 문서", accessory: { KButton(title: "전체 보기", action: showDocuments) }) {
                VStack(alignment: .leading, spacing: K.s3) {
                    if documents.isEmpty { Text("저장된 Markdown 문서가 없어요.").font(K.secondary).foregroundStyle(K.faint) }
                    ForEach(documents) { document in
                        Button { openDocument(document.relativePath) } label: {
                            HStack(spacing: K.s3) {
                                Image(systemName: "doc.text").foregroundStyle(K.faint)
                                Text(document.relativePath).font(K.secondary).foregroundStyle(K.ink).lineLimit(2)
                                Spacer(minLength: K.s2)
                                Text(document.modifiedAt.formatted(date: .abbreviated, time: .shortened)).font(K.caption).foregroundStyle(K.faint)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, K.s4).padding(.bottom, K.s4)
            }
            ProjectCard(title: "프로젝트 폴더") {
                HStack(spacing: K.s2) {
                    KButton(title: "Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path, isDirectory: true)) }
                    KButton(title: "터미널") { ProjectFolderActions.terminal(project.path) }
                    KButton(title: "편집기") { ProjectFolderActions.editor(project.path) }
                }.padding(.horizontal, K.s4).padding(.bottom, K.s4)
            }
        }
        .frame(maxWidth: K.preparationOverviewMaximumWidth, alignment: .leading)
        .task(id: items) {
            writingHistory = PreparationWritingEntry.recent(items)
            if selected == nil { selected = store.selectedPreparationID(inProject: project.id) ?? items.first?.id }
            if let chosen { store.selectPreparation(chosen.id, inProject: project.id) }
        }
        .sheet(item: $editor) { request in
            switch request.kind {
            case .item(let item):
                PreparationItemEditor(store: store, project: project, item: item, candidates: [], documents: documentChoices) { selected = $0 }
            case .importCandidate:
                PreparationItemEditor(store: store, project: project, item: nil, candidates: candidates, documents: documentChoices) { selected = $0 }
            case .draft(let item, let draft): PreparationDraftEditor(store: store, item: item, draft: draft)
            case .record(let item): PreparationRecordEditor(store: store, item: item)
            }
        }
    }
    private var deadlineHint: String {
        let zone = TimeZone.current.identifier == "Asia/Seoul" ? "KST" : (TimeZone.current.abbreviation() ?? TimeZone.current.identifier)
        return "마감 \(zone)" + (items.allSatisfy { $0.fields.submission == .unconfirmed } ? " · 제출 여부 미확인" : "")
    }
    private func choose(_ id: String) { if selected != id { selectedDraftID = nil }; selected = id; store.selectPreparation(id, inProject: project.id) }
    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: K.s3) {
                Text("회사").frame(width: K.preparationOrganizationWidth, alignment: .leading)
                Text("공고·직무").frame(maxWidth: .infinity, alignment: .leading)
                Text("마감").frame(width: K.preparationDeadlineWidth, alignment: .leading)
                Text("준비 메모").frame(maxWidth: .infinity, alignment: .leading)
            }.font(K.caption.weight(.semibold)).foregroundStyle(K.muted).padding(.horizontal, K.s4).padding(.vertical, K.s2)
            Divider().overlay(K.lineStrong)
            ForEach(items) { item in
                Button { choose(item.id) } label: {
                    HStack(alignment: .top, spacing: K.s3) {
                        organization(item).frame(width: K.preparationOrganizationWidth, alignment: .leading)
                        Text(item.fields.title).frame(maxWidth: .infinity, alignment: .leading)
                        deadline(item).frame(width: K.preparationDeadlineWidth, alignment: .leading)
                        VStack(alignment: .leading, spacing: K.s1) {
                            Text(item.fields.memo.isEmpty ? "메모 없음" : item.fields.memo).foregroundStyle(item.fields.memo.isEmpty ? K.faint : K.muted)
                            if item.fields.submission != .unconfirmed { Text(item.fields.submission.label).font(K.caption).foregroundStyle(K.muted) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.font(K.secondary).foregroundStyle(K.ink).padding(.horizontal, K.s4).padding(.vertical, K.s3)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .background(chosen?.id == item.id ? K.sunken : .clear)
                }.buttonStyle(.plain).accessibilityIdentifier("preparation-row-" + item.id)
                    .accessibilityAddTraits(chosen?.id == item.id ? .isSelected : [])
                if item.id != items.last?.id { Divider().overlay(K.line) }
            }
        }.padding(.bottom, K.s2)
    }
    private var compactList: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                Button { choose(item.id) } label: {
                    VStack(alignment: .leading, spacing: K.s2) {
                        HStack { organization(item); Spacer(minLength: K.s2); deadline(item) }
                        Text(item.fields.title).font(K.secondary.weight(.medium)).foregroundStyle(K.ink)
                        if !item.fields.memo.isEmpty { Text(item.fields.memo).font(K.secondary).foregroundStyle(K.muted) }
                    }.padding(K.s4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .background(chosen?.id == item.id ? K.sunken : .clear)
                }.buttonStyle(.plain).accessibilityIdentifier("preparation-row-" + item.id)
                if item.id != items.last?.id { Divider().overlay(K.line) }
            }
        }
    }
    private func organization(_ item: PreparationItem) -> some View {
        VStack(alignment: .leading, spacing: K.s1) {
            Text(item.fields.organization.isEmpty ? "—" : item.fields.organization).font(K.secondary.weight(.semibold)).foregroundStyle(K.ink)
            if item.fields.priority { Text("최우선").font(K.caption).foregroundStyle(K.muted) }
        }
    }
    private func deadline(_ item: PreparationItem) -> some View {
        Text(item.fields.deadlineLabel())
            .font(K.secondary).foregroundStyle(K.muted).monospacedDigit().fixedSize(horizontal: false, vertical: true)
    }
}

enum PreparationDetailTab: String, CaseIterable { case posting = "공고", drafts = "작성본", records = "진행 기록" }
struct PreparationEditorRequest: Identifiable {
    enum Kind { case item(PreparationItem?), importCandidate, draft(PreparationItem, PreparationItem.Draft?), record(PreparationItem) }
    let id = UUID()
    let kind: Kind
}
private struct PreparationWritingEntry: Identifiable {
    let itemID: String
    let heading: String
    let draft: PreparationItem.Draft
    var id: String { draft.id }
    static func recent(_ items: [PreparationItem]) -> [Self] {
        Array(items.flatMap { item in item.drafts.map { Self(itemID: item.id, heading: item.heading, draft: $0) } }
            .sorted { $0.draft.savedAt > $1.draft.savedAt }.prefix(8))
    }
}

private struct PreparationDetail: View {
    let item: PreparationItem
    @Binding var tab: PreparationDetailTab
    @Binding var draftID: String?
    let editable: Bool
    let openDocument: (String) -> Void
    let edit: () -> Void
    let newDraft: (PreparationItem.Draft?) -> Void
    let newRecord: () -> Void
    private var draft: PreparationItem.Draft? { item.drafts.first { $0.id == draftID } ?? item.drafts.last }
    var body: some View {
        ProjectCard(title: item.heading, accessory: { KButton(title: "공고 수정", enabled: editable, action: edit) }) {
            VStack(alignment: .leading, spacing: K.s4) {
                HStack(spacing: K.s4) {
                    ForEach(PreparationDetailTab.allCases, id: \.self) { value in
                        Button { tab = value } label: {
                            Text(value.rawValue).font(K.secondary.weight(tab == value ? .semibold : .regular))
                                .foregroundStyle(tab == value ? K.ink : K.muted).padding(.vertical, K.s2)
                                .overlay(alignment: .bottom) { Rectangle().fill(tab == value ? K.ink : .clear).frame(height: K.projectResizeGuideWidth) }
                        }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? .isSelected : [])
                            .accessibilityIdentifier("preparation-tab-" + value.rawValue)
                    }
                }
                switch tab {
                case .posting: posting
                case .drafts: drafts
                case .records: records
                }
            }.padding(.horizontal, K.s4).padding(.bottom, K.s4)
        }
    }
    private var posting: some View {
        VStack(alignment: .leading, spacing: K.s3) {
            Text(item.fields.submission.label).font(K.secondary).foregroundStyle(K.muted)
            if !item.fields.memo.isEmpty { Text(item.fields.memo).font(K.secondary).foregroundStyle(K.ink).textSelection(.enabled) }
            if !item.fields.posting.isEmpty { PreparationMarkdown(text: item.fields.posting) }
            if !item.fields.documentPaths.isEmpty {
                Divider().overlay(K.line)
                ForEach(item.fields.documentPaths, id: \.self) { path in
                    Button { openDocument(path) } label: { Label(path, systemImage: "doc.text").font(K.secondary) }.buttonStyle(.link)
                }
            }
            if let source = item.sourceIssue {
                DisclosureGroup("이전 후보 기록") {
                    VStack(alignment: .leading, spacing: K.s3) {
                        Text(source.title).font(K.secondary.weight(.semibold)).textSelection(.enabled)
                        if !source.detail.isEmpty { Text(source.detail).font(K.secondary).textSelection(.enabled) }
                        PreparationMarkdown(text: source.proposal?.instruction ?? "")
                        ForEach(Array(source.acceptance.enumerated()), id: \.offset) { _, criterion in
                            Text("• " + criterion.text).font(K.secondary).textSelection(.enabled)
                        }
                    }.padding(.top, K.s3)
                }.font(K.secondary).foregroundStyle(K.muted)
            }
        }
    }
    private var drafts: some View {
        VStack(alignment: .leading, spacing: K.s3) {
            HStack(spacing: K.s2) {
                if !item.drafts.isEmpty {
                    Picker("저장된 작성본", selection: Binding(get: { draft?.id ?? "" }, set: { draftID = $0 })) {
                        ForEach(item.drafts.reversed()) { saved in
                            Text(saved.title + " · v\(saved.version) · " + saved.kind.label).tag(saved.id)
                        }
                    }.labelsHidden().accessibilityLabel("저장된 작성본")
                }
                Spacer(minLength: K.s2)
                KButton(title: "새 작성본", enabled: editable) { newDraft(nil) }
                if let draft { KButton(title: "새 버전", enabled: editable) { newDraft(draft) } }
            }
            if let draft {
                Text(draft.savedAt.formatted(date: .abbreviated, time: .shortened)).font(K.caption).foregroundStyle(K.faint)
                PreparationMarkdown(text: draft.text)
            } else { Text("아직 저장한 작성본이 없어요.").font(K.secondary).foregroundStyle(K.faint) }
        }
    }
    private var records: some View {
        VStack(alignment: .leading, spacing: K.s3) {
            HStack { Text(item.fields.submission.label).font(K.secondary).foregroundStyle(K.muted); Spacer(); KButton(title: "기록 추가", enabled: editable, action: newRecord) }
            if item.records.isEmpty { Text("아직 남긴 진행 기록이 없어요.").font(K.secondary).foregroundStyle(K.faint) }
            ForEach(item.records.reversed()) { record in
                VStack(alignment: .leading, spacing: K.s2) {
                    Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened)).font(K.caption).foregroundStyle(K.faint)
                    Text(record.text).font(K.secondary).foregroundStyle(K.ink).textSelection(.enabled)
                    if let submission = record.submission { Text(submission.label).font(K.caption).foregroundStyle(K.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if record.id != item.records.first?.id { Divider().overlay(K.line) }
            }
        }
    }
}

/// Parse only when the saved content changes, not on each layout or live chat update.
struct PreparationMarkdown: View {
    let text: String
    @State private var blocks: [MarkdownBlock] = []
    var body: some View {
        MarkdownBlocksView(blocks: blocks, scale: .body).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: text) { blocks = MarkdownBlocks.parse(text) }
    }
}
