import KnarrSync
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One conversation with Stallari: bubbles, Markdown answers, Issue and question cards, and a composer
/// that can send pictures. The middle column on iPad and the Stallari tab on iPhone use the same view.
struct ChatView: View {
    @Bindable var store: PhoneStore
    @Environment(\.isEnabled) private var isEnabled
    /// nil shows every conversation merged, as the iPhone tab always has. A value shows one conversation.
    var thread: String?
    var title: String = "Stallari"
    /// The iPad column already names the conversation in its own header.
    var compactHeader = false

    @State private var draft = ""
    @State private var project: String?
    @State private var query = ""
    @State private var atBottom = true
    @State private var unseen = 0
    @State private var jumpTarget: String?
    @State private var highlighted: String?
    @State private var attachments: [MobileAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var choosingPhotos = false
    @State private var attachmentError: String?
    @FocusState private var focused: Bool
    @FocusState private var searchFieldFocused: Bool
    @State private var searching = false
    @State private var webJump = 0
    @State private var previewData: Data?

    private var conversation: String? { thread }

    private var messages: [MobileMessage] {
        thread.map { store.model.messages(in: $0) } ?? store.model.messages
    }

    private var pendingMessages: [MobileRequest] {
        store.model.pendingRequests.filter {
            switch $0.kind {
            case .threadMessage(let _, let target, _, _): thread.map { $0 == target } ?? true
            case .message: thread.map { $0 == ConversationID.main } ?? true
            default: false
            }
        }
    }

    private var canLoadOlder: Bool {
        guard let thread else { return false }
        return store.model.canLoadOlder(thread: thread)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !compactHeader { ConnectionBanner(store: store).padding(.horizontal, 16).padding(.vertical, 6) }
            if canLoadOlder { LoadOlderRow(store: store, thread: thread!) }
            if messages.isEmpty && pendingMessages.isEmpty {
                Text("대화 없음").font(.footnote).foregroundStyle(Palette.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MobileChatWebView(store: store, thread: thread, messages: messages,
                                  issues: Array(store.model.issues.values), questions: Array(store.model.questions.values),
                                  pending: pendingMessages, responding: store.model.status?.isResponding == true,
                                  target: jumpTarget, jump: webJump, edit: edit,
                                  preview: { previewData = $0 }, reached: { jumpTarget = nil },
                                  following: { atBottom = $0; if $0 { unseen = 0 } })
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !atBottom {
                Button(unseen > 0 ? "새 메시지 \(unseen) · 최신으로" : "최신으로") {
                    jumpTarget = nil; webJump += 1; atBottom = true; unseen = 0
                }
                .font(.caption.weight(.medium)).buttonStyle(.bordered)
                .background(Palette.page).padding(12)
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { focused = false; searchFieldFocused = false }
        }
        .onChange(of: messages.last?.id) { _, _ in if !atBottom { unseen += 1 } }
        .sheet(isPresented: Binding(get: { previewData != nil }, set: { if !$0 { previewData = nil } })) {
            NavigationStack {
                if let data = previewData, let image = UIImage(data: data) {
                    ScrollView([.horizontal, .vertical]) { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 1000) }
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { previewData = nil } } }
                }
            }
        }
        .task {
            if let sample = store.sampleQuery { query = sample; store.sampleQuery = nil }
            if let jump = store.sampleJump {
                try? await Task.sleep(for: .seconds(1))
                jumpTarget = jump
                store.sampleJump = nil
            }
        }
        .overlay { if !query.isEmpty { searchResults } }
        .overlay(alignment: .top) { if searching { searchBar } }
        .toolbar { ToolbarItemGroup(placement: .topBarTrailing) {
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("새로고침").disabled(store.isRefreshing)
            Button { searching.toggle(); if !searching { query = "" } } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("대화 검색")
        } }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .background(Palette.page)
        .background(shortcuts)
    }

    static let bottom = "bottom"

    /// Hardware keyboard shortcuts that work wherever the conversation is visible.
    /// ⌘↩ sends, ⌘N starts a new request, ⌘F searches, ⌘⇧O pages in older messages.
    private var shortcuts: some View {
        Group {
            Button("") { searching = true; query = ""; searchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { focused = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("") { if let thread { store.loadOlder(thread: thread, before: store.model.oldestMessage(in: thread)) } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!canLoadOlder)
        }
        .hidden()
        .accessibilityHidden(true)
    }

    /// ⌘F on a hardware keyboard. iOS 17 cannot focus the system search field from code,
    /// so the shortcut opens an inline field over the conversation instead.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.faint)
            TextField("대화 검색", text: $query)
                .focused($searchFieldFocused)
                .submitLabel(.search)
            Button("닫기") { searching = false; query = ""; searchFieldFocused = false }
                .font(.footnote)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
        .padding(.horizontal, 16).padding(.top, 8)
    }

    // MARK: Rows

    enum Row: Identifiable {
        case day(String)
        case message(MobileMessage)
        var id: String {
            switch self {
            case .day(let label): "day-\(label)"
            case .message(let m): m.id
            }
        }
    }

    private var rows: [Row] {
        var out: [Row] = []
        var lastDay: Date?
        let calendar = Calendar.current
        for message in messages {
            let day = calendar.startOfDay(for: message.at)
            if day != lastDay { out.append(.day(Self.dayLabel(day))); lastDay = day }
            out.append(.message(message))
        }
        return out
    }

    static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "오늘" }
        if calendar.isDateInYesterday(day) { return "어제" }
        return day.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ko_KR")))
    }

    // MARK: Search

    private var searchResults: some View {
        let matches = messages.filter { $0.text.localizedCaseInsensitiveContains(query) }.reversed()
        return List {
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            ForEach(Array(matches)) { message in
                Button {
                    query = ""
                    jumpTarget = message.id
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(MessageRow.who(message.role)).font(.caption.weight(.semibold))
                            Spacer()
                            Text(message.at, format: .dateTime.month().day().hour().minute()).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        Text(Self.snippet(message.text, around: query)).font(.callout).lineLimit(3)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .background(Palette.page)
    }

    /// The matching part of a long message, with Markdown marks removed.
    static func snippet(_ text: String, around query: String) -> String {
        let plain = text
            .replacingOccurrences(of: #"(?m)^\s*(?:[-*+]\s+\[[ xX]\]|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*\|?[\s:|-]+\|?\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[`*_#>|]|\[![A-Z]+\]-?"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let range = plain.range(of: query, options: .caseInsensitive) else { return String(plain.prefix(120)) }
        let start = plain.index(range.lowerBound, offsetBy: -40, limitedBy: plain.startIndex) ?? plain.startIndex
        return (start == plain.startIndex ? "" : "…") + String(plain[start...].prefix(140))
    }

    // MARK: Composer

    private func edit(_ text: String) {
        draft = text
        focused = true
    }

    private var bodyText: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !bodyText.isEmpty || !attachments.isEmpty }

    private func send() {
        guard canSend else { return }
        store.send(text: bodyText, project: project, thread: thread ?? ConversationID.main, attachments: attachments)
        draft = ""; attachments = []; webJump += 1
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let failed = store.failedDraft, (failed.thread ?? ConversationID.main) == (thread ?? ConversationID.main) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("보내지 못했어요").font(.footnote.weight(.semibold))
                        Text(failed.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("불러오기") { draft = failed.text; project = failed.project; attachments = failed.attachments; store.failedDraft = nil; focused = true }
                        .font(.footnote)
                    Button("다시 시도") { store.retryFailedDraft() }
                        .font(.footnote.weight(.semibold))
                }
                .padding(10)
                .background(Palette.redSoft, in: RoundedRectangle(cornerRadius: 12))
            }
            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Palette.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !attachments.isEmpty { attachmentStrip }
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .bottom, spacing: 4) {
                    Menu {
                        Button("사진 첨부") { choosingPhotos = true }
                        Button("파일 첨부") { importing = true }
                    } label: {
                        Image(systemName: "paperclip").font(.system(size: 15))
                            .foregroundStyle(Palette.muted).frame(width: 40, height: 40)
                    }
                    .disabled(attachments.count >= MobileLimits.attachmentCount)
                    .accessibilityLabel("첨부")
                    TextField("메시지 입력", text: $draft, axis: .vertical)
                        .font(.system(size: UIDevice.current.userInterfaceIdiom == .pad ? 14 : 16))
                        .lineLimit(1...8).focused($focused).padding(.vertical, 10)
                    Menu {
                        Button("모든 프로젝트") { project = nil }
                        ForEach(store.model.projects) { p in Button(p.name) { project = p.id } }
                    } label: {
                        Text(store.model.projects.first { $0.id == project }?.name ?? "모든 프로젝트")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
                            .padding(.horizontal, 10).frame(height: 40)
                    }
                    .accessibilityLabel("보낼 프로젝트: \(store.model.projects.first { $0.id == project }?.name ?? "모든 프로젝트")")
                }
                .background(Palette.page, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.lineStrong))
                Button(action: send) {
                    Text("전송").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                        .frame(minWidth: 52, minHeight: 42)
                        .background(Palette.accent.opacity(canSend ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("보내기").accessibilityHint("⌘↩")
            }
            .photosPicker(isPresented: $choosingPhotos, selection: $photoItems,
                          maxSelectionCount: max(1, MobileLimits.attachmentCount - attachments.count), matching: .images)
            .onChange(of: photoItems) { _, items in Task { await loadPhotos(items) } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                Task { await loadFiles(result) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Palette.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let data = attachment.data, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            RoundedRectangle(cornerRadius: 10).fill(Palette.beige)
                                .frame(width: 64, height: 64)
                                .overlay(Image(systemName: "photo").foregroundStyle(Palette.faint))
                        }
                        Button { attachments.removeAll { $0.id == attachment.id } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16)).foregroundStyle(Palette.ink, Palette.card)
                        }
                        .padding(3)
                        .accessibilityLabel("첨부 삭제")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        defer { photoItems = [] }
        for item in items {
            guard attachments.count < MobileLimits.attachmentCount else { break }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                attachmentError = "사진을 읽지 못했어요"; continue
            }
            appendAttachment(data: data, name: "사진 \(attachments.count + 1).jpg", type: "image/jpeg")
        }
    }

    private func loadFiles(_ result: Result<[URL], any Error>) async {
        guard case .success(let urls) = result else { attachmentError = "파일을 읽지 못했어요"; return }
        for url in urls {
            guard attachments.count < MobileLimits.attachmentCount else { break }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { attachmentError = "파일을 읽지 못했어요"; continue }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
            appendAttachment(data: data, name: url.lastPathComponent, type: type)
        }
    }

    /// Pictures are shrunk before they leave the phone: CloudKit assets and the Mac's message
    /// pipeline both stay within one bounded size, and the request stays well below its limits.
    private func appendAttachment(data: Data, name: String, type: String) {
        attachmentError = nil
        guard let shrunk = AttachmentShrinker.shrink(data, type: type) else {
            attachmentError = "사진으로 읽을 수 없는 파일이에요"; return
        }
        guard shrunk.count <= MobileLimits.attachmentBytes else {
            attachmentError = "사진 한 장은 8MB까지 보낼 수 있어요"; return
        }
        attachments.append(MobileAttachment(name: name, type: "image/jpeg", byteCount: shrunk.count, data: shrunk))
    }
}

/// Phone-side image preparation: downscale to a readable screenshot size and re-encode as JPEG.
enum AttachmentShrinker {
    static let maxEdge: CGFloat = 2048

    static func shrink(_ data: Data, type: String) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

struct LoadOlderRow: View {
    let store: PhoneStore
    let thread: String

    var body: some View {
        HStack {
            Spacer()
            Button {
                store.loadOlder(thread: thread, before: store.model.oldestMessage(in: thread))
            } label: {
                Label(store.isLoadingHistory ? "이전 기록을 받는 중" : "이전 기록 더 보기", systemImage: "clock.arrow.circlepath")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Palette.beige, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(store.isLoadingHistory)
            Spacer()
        }
        .accessibilityHint("Mac에 저장된 더 오래된 메시지를 불러와요")
    }
}

/// One conversation entry: the person's bubble, Stallari's Markdown, a notice, or a card for an Issue or question.
struct MessageRow: View {
    let store: PhoneStore
    let message: MobileMessage
    var thread: String?
    let edit: (String) -> Void
    @State private var copied = false
    @State private var expanded = false

    static func who(_ role: MobileMessage.Role) -> String {
        switch role {
        case .user: "나"
        case .stallari: "Stallari"
        case .notice: "알림"
        case .issue: "이슈"
        case .question: "질문"
        case .autoCheck: "자동 확인"
        case .report: "작업 보고"
        }
    }

    var body: some View {
        switch message.role {
        case .user: user
        case .stallari: stallari
        case .notice: notice
        case .issue: issueCard
        case .question: questionCard
        case .autoCheck: autoCheck
        case .report: reportCard
        }
    }

    private var time: some View {
        Text(message.at, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(Palette.faint)
    }

    private var user: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 5) {
                if let files = message.attachments, !files.isEmpty { attachmentStrip(files) }
                if !message.text.isEmpty {
                    Text(message.text)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .foregroundStyle(Palette.ink)
                        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .contextMenu {
                            Button { copy() } label: { Label("복사", systemImage: "doc.on.doc") }
                            Button { edit(message.text) } label: { Label("수정해서 다시 보내기", systemImage: "pencil") }
                        }
                }
                time
            }
        }
    }

    @ViewBuilder private func attachmentStrip(_ files: [MobileAttachment]) -> some View {
        HStack(spacing: 6) {
            ForEach(files) { file in
                if let data = file.data, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 120, height: 90).clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Label(file.name, systemImage: "photo")
                        .font(.caption2).padding(8)
                        .background(Palette.beige, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var stallari: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.caption2).foregroundStyle(Palette.accent)
                Text(message.project ?? "Stallari").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            }
            MarkdownView(text: message.text)
                .contextMenu { Button { copy() } label: { Label("복사", systemImage: "doc.on.doc") } }
            HStack(spacing: 12) {
                time
                Button { copy() } label: {
                    Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2).foregroundStyle(copied ? Palette.green : Palette.faint)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("답변 복사")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message.text, systemImage: "bell").font(.footnote).foregroundStyle(Palette.muted)
            if let issue = message.issue { openButton(issue) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.beige, in: RoundedRectangle(cornerRadius: 12))
    }

    private var issueCard: some View {
        let live = message.issue.flatMap { store.model.issues[$0] }
        return Button { if let id = message.issue { store.openIssue = id } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: live.map { Palette.symbol($0.state) } ?? "checklist")
                    .foregroundStyle(live.map { Palette.color($0.state) } ?? Palette.faint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("이슈를 만들었어요").font(.caption).foregroundStyle(Palette.faint)
                    Text(live?.title ?? message.text).font(.callout.weight(.semibold)).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                    if let live {
                        Text([Palette.label(live.state), live.progress].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.faint)
            }
            .padding(12)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(message.issue == nil)
        .hoverEffect(.highlight)
    }

    private var questionCard: some View {
        let question = message.question.flatMap { store.model.questions[$0] }
        return VStack(alignment: .leading, spacing: 6) {
            Label(question.map { "\($0.asker)의 질문" } ?? "질문", systemImage: "questionmark.bubble.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(Palette.amber)
            Text(message.text).font(.callout).foregroundStyle(Palette.ink)
            switch question?.state {
            case .answered?: Label("답함 · \(question?.answer ?? "")", systemImage: "checkmark").font(.caption).foregroundStyle(Palette.green)
            case .cancelled?: Label("닫음", systemImage: "xmark").font(.caption).foregroundStyle(Palette.faint)
            default: if let issue = message.issue { openButton(issue, title: "답하러 가기") }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: 12))
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("작업 보고", systemImage: "doc.text").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
            Text(message.report?.title ?? message.text).font(.callout.weight(.semibold)).foregroundStyle(Palette.ink)
            ForEach(Array((message.report?.lines ?? []).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(Palette.muted)
            }
            if let error = message.report?.error {
                Text(error).font(.caption).foregroundStyle(Palette.amber)
            }
            Text("상세 보고서는 맥의 기록 탭에서 열 수 있어요").font(.caption2).foregroundStyle(Palette.faint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 1))
    }

    private var autoCheck: some View {
        let lines = message.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(Palette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label(lines.first ?? "", systemImage: "checkmark.seal").font(.caption).foregroundStyle(Palette.muted)
        }
        .tint(Palette.faint)
    }

    private func openButton(_ issue: String, title: String = "이슈 열기") -> some View {
        Button { store.openIssue = issue } label: {
            Label(title, systemImage: "arrow.right.circle").font(.footnote.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .tint(Palette.accent)
    }

    private func copy() {
        UIPasteboard.general.string = message.text
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

struct PendingBubble: View {
    let text: String
    var attachmentCount: Int = 0
    let cancel: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    if attachmentCount > 0 {
                        Label("사진 \(attachmentCount)", systemImage: "photo").font(.caption)
                    }
                    if !text.isEmpty { Text(text) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Palette.accentSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.accent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contextMenu {
                    Button { UIPasteboard.general.string = text } label: { Label("복사", systemImage: "doc.on.doc") }
                    Button(role: .destructive, action: cancel) { Label("보내기 취소", systemImage: "xmark") }
                }
                Label("Mac에 전달 대기", systemImage: "paperplane").font(.caption2).foregroundStyle(Palette.amber)
            }
        }
    }
}
