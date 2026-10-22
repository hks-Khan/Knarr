import SwiftUI
import KnarrCore

/// Shared frame for the rail's windows: title, subtitle, close, content.
private struct SheetFrame<Content: View>: View {
    let title: String
    let subtitle: String
    var width: CGFloat = 560
    var height: CGFloat = 500
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(K.title)
                    Text(subtitle).font(K.secondary).foregroundStyle(K.muted)
                }
                Spacer()
                KButton(title: "닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider().overlay(K.line)
            content
        }
        .frame(width: width, height: height)
        .background(K.surface)
        .foregroundStyle(K.ink)
    }
}

/// The same minimal permission guidance in Settings and the visual QA renderer.
public struct DesktopNotificationSettings: View {
    let status: DesktopNotificationStatus
    public init(status: DesktopNotificationStatus) { self.status = status }
    public var body: some View {
        VStack(alignment: .leading, spacing: K.s2) {
            Text("macOS 알림").font(K.body.weight(.semibold))
            Text(status.message).font(K.secondary).foregroundStyle(K.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(K.ink)
    }
}

/// Auto install switch and its one-line state. Wording comes from the caller's policy file.
public struct AutoInstallSettings: View {
    let policy: AutoInstallPolicy
    let enabled: Bool
    let status: String?
    let setEnabled: (Bool) -> Void
    public init(policy: AutoInstallPolicy, enabled: Bool, status: String?, setEnabled: @escaping (Bool) -> Void) {
        self.policy = policy; self.enabled = enabled; self.status = status; self.setEnabled = setEnabled
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: K.s2) {
            Toggle(policy.title, isOn: Binding(get: { enabled }, set: { setEnabled($0) }))
                .font(K.body.weight(.semibold))
                .toggleStyle(.switch)
                .controlSize(.small)
            if let status, !status.isEmpty {
                Text(status).font(K.secondary).foregroundStyle(policy.isFailureLine(status) ? K.red : K.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(K.ink)
    }
}

/// Response preferences and work-copy storage. Model controls live in the composer.
public struct SettingsSheet: View {
    let store: any KnarrStore
    /// Snapshot-only override so the reviewer can see every section without scrolling.
    private let previewHeight: CGFloat?
    public init(store: any KnarrStore, previewHeight: CGFloat? = nil) {
        self.store = store; self.previewHeight = previewHeight
    }
    @State private var rulesDraft = ""
    @State private var instructionID: String?
    @State private var instructionDraft = ""
    @State private var instructionStatus = ""

    public var body: some View {
        SheetFrame(title: "설정", subtitle: "응답 지침과 작업본 저장 공간", height: previewHeight ?? 620) {
            ScrollView {
                VStack(alignment: .leading, spacing: K.s5) {
                    DesktopNotificationSettings(status: store.desktopNotificationStatus)
                    AutoInstallSettings(policy: store.autoInstallPolicy,
                        enabled: store.autoInstallEnabled, status: store.autoInstallStatus,
                        setEnabled: { store.setAutoInstall($0) })
                    if let connection = store.hiveConnection {
                        HiveConnectionSettings(
                            connection: connection,
                            refresh: { try await store.refreshHiveProvider() },
                            verify: { await store.verifyHiveConnection() }
                        )
                    }
                    if let path = store.responseRulesPath {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("응답 지침").font(K.body.weight(.semibold))
                            Text(path).font(K.mono).textSelection(.enabled)
                            Text("사용자 소유 Markdown입니다. 저장하거나 외부 편집하면 다음 요청에 반영합니다. 보안·도구 권한·이슈 승인 규칙은 바뀌지 않습니다.")
                                .font(K.secondary).foregroundStyle(K.muted)
                            TextEditor(text: $rulesDraft)
                                .font(K.mono).frame(height: 160)
                                .accessibilityLabel("응답 지침 편집")
                            HStack {
                                KButton(title: "다시 읽기") { store.reloadResponseRules() }
                                KButton(title: "저장", style: .primary) { store.saveResponseRules(rulesDraft) }
                            }
                        }
                    }

                    if !store.instructionSources.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("지침 파일").font(K.body.weight(.semibold))
                            Text("공통·Stallari·Hird·프로젝트 순서로 적용해요. AGENTS.md는 대화·실행 시작 때, RULES.md는 매 요청과 매 Hird 실행에 들어가요. 다음 요청부터 반영되고 도구 권한·승인 규칙은 바뀌지 않아요.")
                                .font(K.secondary).foregroundStyle(K.muted).fixedSize(horizontal: false, vertical: true)
                            Picker("", selection: Binding(get: { instructionID ?? store.instructionSources.first?.id ?? "" },
                                                          set: { selectInstruction($0) })) {
                                ForEach(store.instructionSources) { source in
                                    Text(source.title).tag(source.id)
                                }
                            }
                            .labelsHidden()
                            if let source = selectedInstruction {
                                Text(source.path).font(K.mono).textSelection(.enabled)
                                TextEditor(text: $instructionDraft)
                                    .font(K.mono).frame(height: 180)
                                    .accessibilityLabel("지침 파일 편집")
                                HStack {
                                    KButton(title: "다시 읽기") { store.reloadInstructionSources(); selectInstruction(source.id) }
                                    KButton(title: "저장", style: .primary) {
                                        Task {
                                            do {
                                                _ = try await store.saveInstructionSource(role: source.role, kind: source.kind,
                                                    projectID: source.projectID, text: instructionDraft, expectedHash: source.version)
                                                instructionStatus = "저장했어요. 다음 요청부터 반영돼요."
                                            } catch {
                                                instructionStatus = error.localizedDescription
                                                store.reloadInstructionSources(); selectInstruction(source.id)
                                            }
                                        }
                                    }
                                }
                                if !instructionStatus.isEmpty {
                                    Text(instructionStatus).font(K.secondary).foregroundStyle(K.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("작업본 저장 공간").font(K.body.weight(.semibold))
                        Text("Hird는 이슈마다 별도 작업본에서 일해요. 원본에 반영한 작업본은 자동으로 지워요. 아래 버튼은 반영했거나, 다시 맡겨서 대체됐거나, 멈춘 이슈의 작업본을 지워요. 확인을 기다리는 결과는 남겨요. 브랜치는 그대로 둬요.")
                            .font(K.secondary).foregroundStyle(K.muted).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text(store.storageBytes.map { Bytes.text($0) } ?? "계산 중")
                                .font(K.title).monospacedDigit()
                            Spacer()
                            KButton(title: "끝난 작업본 정리", style: .primary) { store.cleanFinishedWorkspaces() }
                        }
                    }
                }
                .padding(20)
            }
        }
        .onAppear {
            store.reloadResponseRules(); rulesDraft = store.responseRulesText
            store.reloadInstructionSources(); selectInstruction(instructionID ?? store.instructionSources.first?.id)
        }
        .onChange(of: store.responseRulesText) { _, text in rulesDraft = text }
    }

    private var selectedInstruction: InstructionSource? {
        guard let instructionID else { return nil }
        return store.instructionSources.first { $0.id == instructionID }
    }

    /// Selecting another file never carries the previous draft across.
    private func selectInstruction(_ id: String?) {
        guard let id, let source = store.instructionSources.first(where: { $0.id == id }) else {
            instructionID = nil; instructionDraft = ""; return
        }
        instructionID = source.id
        instructionDraft = source.text
        instructionStatus = ""
    }


}


/// 대화 기록 검색: find a message and jump to it.
struct SearchSheet: View {
    let store: any KnarrStore
    let jump: (UUID) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(title: "대화 기록 검색", subtitle: "내 메시지와 Stallari 답변에서 찾아요", width: 620, height: 520) {
            VStack(spacing: 0) {
                TextField("찾을 말", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                Divider().overlay(K.line)
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Spacer()
                } else if results.isEmpty {
                    Text("찾는 말이 없어요").font(K.secondary).foregroundStyle(K.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(results, id: \.item.id) { hit in
                                Button { jump(hit.item.id); dismiss() } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(hit.who) · \(hit.item.at.formatted(date: .abbreviated, time: .shortened))")
                                            .font(K.caption).foregroundStyle(K.faint)
                                        Text(hit.snippet).font(K.secondary).lineLimit(2).multilineTextAlignment(.leading)
                                    }
                                    .padding(.horizontal, 20).padding(.vertical, 9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider().overlay(K.line).padding(.leading, 20)
                            }
                        }
                    }
                }
            }
        }
    }

    private var results: [(item: ChatItem, who: String, snippet: String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return store.chat.reversed().compactMap { item in
            let (who, text): (String, String)
            switch item.kind {
            case .user(let t): (who, text) = ("나", t)
            case .stallari(let t, _): (who, text) = ("Stallari", t)
            default: return nil
            }
            guard let range = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
            let plain = text[start..<end]
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "|", with: " ")
                .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            let snippet = (start > text.startIndex ? "…" : "") + plain + (end < text.endIndex ? "…" : "")
            return (item, who, snippet)
        }
    }
}
