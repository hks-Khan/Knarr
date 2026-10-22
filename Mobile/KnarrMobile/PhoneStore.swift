import CloudKit
import KnarrSync
import Observation
import SwiftUI

/// The phone's link to Knarr on the Mac: fetches what the Mac wrote and sends requests back.
@MainActor @Observable
final class PhoneStore {
    enum Connection: Equatable {
        case starting
        case ready
        case unavailable(String)
        case failed(String)
    }

    /// A message that could not be sent, kept so the person can load it back or retry.
    struct FailedDraft: Equatable {
        var text: String
        var project: String?
        var thread: String?
        var reason: String
        var attachments: [MobileAttachment] = []
        var request: MobileRequest?
    }

    let model = MobileClientModel()
    let isSample: Bool
    private(set) var connection: Connection = .starting
    private(set) var isRefreshing = false
    private(set) var isLoadingHistory = false
    /// Set when a notification is tapped; the list opens that Issue.
    var openIssue: String?
    /// Set when a notification without an Issue (a Stallari reply) is tapped.
    var openChat = false
    var startOnChat = false
    /// Where the app is, so a deep link can pick the right surface.
    var openSection: NavigationSection?
    /// Sample launches only: a message to scroll to, to check the screen away from the bottom.
    var sampleJump: String?
    var sampleQuery: String?
    var sampleConfirm = false
    /// Sample launches only: the conversation and pane a screenshot should open.
    var sampleThread: String?
    var sampleSettings = false
    var sampleScreen: String?

    /// Sample launches only: act as if the Mac applied every pending request, to show the confirmation.
    func sampleApplyPending() {
        announce(model.apply(saved: [], deleted: model.pendingRequests.map { MobileRecord.request($0).recordName }))
    }
    var activityListRequest = UUID()
    var sendError: String?
    var failedDraft: FailedDraft?
    /// Short confirmation once the Mac applied something sent from the phone.
    private(set) var feedback: String?

    @ObservationIgnored private var engine: CloudSyncEngine?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var uploading: Set<String> = []
    @ObservationIgnored private var feedbackClear: Task<Void, Never>?
    @ObservationIgnored private var activities: LiveActivityController?
    @ObservationIgnored private let defaults: UserDefaults
    static let inboxKey = "knarr.inbox"
    static let seenAlertsKey = "knarr.alerts.seen"
    static let savedAtKey = "knarr.lastSaved"

    init(sample: Bool, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSample = sample
        if sample {
            model.apply(saved: SampleRecords.all, deleted: [])
            model.lastChangedAt = .now.addingTimeInterval(-40)
            connection = .ready
        } else {
            restoreInbox()
        }
    }

    // MARK: Alerts

    /// The Mac deletes alerts after six hours; the phone keeps them for a week with read state.
    private func restoreInbox() {
        guard let data = defaults.data(forKey: Self.inboxKey),
              let stored = try? JSONDecoder().decode(MobileAlertInbox.Stored.self, from: data) else { return }
        model.apply(saved: stored.alerts.map(MobileRecord.alert), deleted: [])
        model.markAlertsRead(Set(stored.read))
    }

    private func saveInbox() {
        guard let data = try? JSONEncoder().encode(model.inbox.stored) else { return }
        defaults.set(data, forKey: Self.inboxKey)
    }

    func markAlertsRead() {
        model.markAllAlertsRead()
        saveInbox()
    }

    func markAlertRead(_ id: String) {
        model.markAlertRead(id)
        saveInbox()
    }

    // MARK: Connection

    /// One line for the sidebar and the iPhone banner: whether the Mac is on, and how fresh the data is.
    var connectionLine: (symbol: String, text: String, color: Color) {
        switch connection {
        case .starting: return ("arrow.triangle.2.circlepath", "iCloud에 연결하는 중", Palette.faint)
        case .unavailable(let why), .failed(let why): return ("exclamationmark.icloud", why, Palette.red)
        case .ready:
            if model.status?.macRunning == false {
                return ("desktopcomputer.trianglebadge.exclamationmark", "Mac 연결 끊김 · 요청은 켜지면 처리돼요", Palette.amber)
            }
            guard let at = model.lastChangedAt else { return ("checkmark.icloud", "Mac 연결됨", Palette.green) }
            return ("checkmark.icloud", "Mac 연결됨 · \(ConnectionBanner.ago(at, now: .now))", Palette.green)
        }
    }

    // MARK: Live Activity

    func startActivityObservation() {
        guard activities == nil else { return }
        let controller = LiveActivityController(sample: isSample)
        activities = controller
        controller.start { [weak self] device in
            guard let engine = self?.engine else { return false }
            do { try await engine.upload(saving: [.activityDevice(device)], deleting: []); return true }
            catch { return false } // A missing new schema must not break the existing phone connection.
        }
    }

    func refreshActivity() async {
        await activities?.update(issues: Array(model.issues.values), questions: Array(model.questions.values),
                                 remoteEnabled: model.status?.liveActivityRemoteEnabled == true)
    }

    func becameActive() async {
        if isSample { await refreshActivity() }
        else { await refresh(); await activities?.publishCurrentDevice() }
    }

    func handleActivityURL(_ url: URL) {
        guard url.scheme == "knarr" else { return }
        #if DEBUG
        if isSample, url.host == "activity-demo", let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value {
            applyActivityScenario(state)
            Task { await refreshActivity() }
            return
        }
        #endif
        guard url.host == "activity" else { return }
        activityListRequest = UUID()
        openIssue = CloudWire.issueID(in: url)
        openSection = .issues
    }

    #if DEBUG
    func applyActivityScenario(_ state: String) {
        let baseline = Date().addingTimeInterval(-720)
        var records = SampleRecords.all.filter { record in
            if case .issue(let t) = record { return t.id == "s1" || (["multiple", "question", "completed"].contains(state) && t.id == "s3") }
            if case .question = record { return state == "question" }
            return record.kind == .project || record.kind == .status
        }
        records = records.map { record in
            guard case .issue(var issue) = record else { return record }
            issue.startedAt = baseline; issue.updatedAt = baseline
            if state == "completed" { issue.state = .done; issue.group = .finished }
            return .issue(issue)
        }
        model.removeAll(); model.apply(saved: records, deleted: [])
    }
    #endif

    func start() async {
        guard !isSample, engine == nil else { return }
        let engine = CloudSyncEngine(role: "phone")
        self.engine = engine
        do {
            let status = try await engine.accountStatus()
            guard status == .available else {
                connection = .unavailable(status == .noAccount ? "iPhone에 iCloud 로그인이 필요해요" : "iCloud를 지금 쓸 수 없어요")
                self.engine = nil
                return
            }
            try await engine.subscribePhone()
            // The in-memory model is empty after relaunch. A saved delta cursor alone cannot
            // restore it, and an empty partial fetch must never end an ongoing Live Activity.
            await engine.resetChangeToken()
            await refresh()
            await activities?.publishCurrentDevice()
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        guard let engine else { return }
        if isRefreshing { refreshAgain = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            do {
                let fetched = try await engine.fetchChanges()
                announce(model.apply(saved: fetched.saved, deleted: fetched.deleted))
                note(fetched.latestChange)
                connection = .ready
                saveInbox()
                await refreshActivity()
            } catch {
                connection = .failed(error.localizedDescription)
                return
            }
        } while refreshAgain
    }

    /// Pull to refresh: refetch the whole zone and swap it in only once it arrived, so the list never goes blank.
    func reload() async {
        guard let engine, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            await engine.resetChangeToken()
            let fetched = try await engine.fetchChanges()
            // Alerts that already left CloudKit stay in the phone's own inbox.
            let saved = fetched.saved.filter { if case .alert = $0 { false } else { true } }
            announce(model.replaceAll(with: saved, uploading: uploading))
            announce(model.apply(saved: fetched.saved, deleted: []))
            note(fetched.latestChange)
            connection = .ready
            saveInbox()
            await refreshActivity()
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    // MARK: Sending

    /// New clients name the destination even for the main conversation.
    /// The same request and photos survive upload failure so a retry cannot change its destination.
    func send(text: String, project: String?, thread: String?, attachments: [MobileAttachment] = []) {
        let target = thread ?? ConversationID.main
        let kind = MobileRequest.Kind.threadMessage(text: text, thread: target, project: project,
                                                    attachments: attachments.isEmpty ? nil : attachments)
        enqueue(kind, usesThread: true,
                fallback: FailedDraft(text: text, project: project, thread: target, reason: "", attachments: attachments))
    }

    func retryFailedDraft() {
        guard let failed = failedDraft else { return }
        failedDraft = nil
        let kind = failed.request?.kind ?? .threadMessage(text: failed.text, thread: failed.thread ?? ConversationID.main,
                                                          project: failed.project,
                                                          attachments: failed.attachments.isEmpty ? nil : failed.attachments)
        enqueue(kind, usesThread: true, fallback: failed, existingRequest: failed.request)
    }

    func send(_ kind: MobileRequest.Kind) {
        if case .message(let text, _) = kind {
            enqueue(kind, usesThread: false, fallback: FailedDraft(text: text, project: nil, thread: nil, reason: ""))
            return
        }
        enqueue(kind, usesThread: false, fallback: nil)
    }

    /// Asks the Mac for one page of older messages in a conversation.
    func loadOlder(thread: String, before: Date?) {
        guard !isSample, let before, model.canLoadOlder(thread: thread), !isLoadingHistory else { return }
        let request = model.makeRequest(.loadOlder(thread: thread, before: before))
        model.apply(saved: [.request(request)], deleted: [])
        isLoadingHistory = true
        uploading.insert(request.id)
        Task {
            defer { uploading.remove(request.id); isLoadingHistory = false }
            do { try await engine?.upload(saving: [.request(request)], deleting: []) }
            catch {
                model.forget(request: request.id)
                sendError = "이전 기록을 요청하지 못했어요: \(error.localizedDescription)"
            }
        }
    }

    private func enqueue(_ kind: MobileRequest.Kind, usesThread: Bool, fallback: FailedDraft?, existingRequest: MobileRequest? = nil) {
        let request = existingRequest ?? model.makeRequest(kind)
        // The phone shows its own bubble immediately, including the pictures, until the Mac answers.
        model.apply(saved: [.request(request)], deleted: [])
        if isSample { return }
        uploading.insert(request.id)
        Task {
            defer { uploading.remove(request.id) }
            do {
                guard let engine else {
                    throw NSError(domain: "Knarr.Phone", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "iCloud 연결 후 다시 시도해 주세요"])
                }
                try await engine.upload(saving: [.request(request)], deleting: [])
            } catch {
                model.forget(request: request.id)
                let reason = error.localizedDescription
                if var failed = fallback, usesThread || !reason.isEmpty {
                    failed.reason = reason
                    failed.request = request
                    failedDraft = failed
                }
                sendError = "Mac에 보내지 못했어요: \(reason)"
            }
        }
    }

    /// Withdraw a request the Mac has not applied yet. If the Mac already took it, this changes nothing there.
    func cancel(_ request: MobileRequest) {
        model.forget(request: request.id)
        if isSample { return }
        Task { try? await engine?.upload(saving: [], deleting: [MobileRecord.request(request).recordName]) }
    }

    private func note(_ latest: Date?) {
        if let at = latest { model.lastChangedAt = max(model.lastChangedAt ?? at, at) }
    }

    private func announce(_ applied: [MobileRequest]) {
        guard let last = applied.last else { return }
        if let failure = model.proposalResults.values.first(where: { $0.requestID == last.id })?.requestFailure {
            sendError = failure
            feedback = nil
        } else {
            feedback = applied.count > 1 ? "Mac이 요청 \(applied.count)개를 처리했어요" : Self.describe(last.kind)
        }
        feedbackClear?.cancel()
        feedbackClear = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { feedback = nil }
        }
    }

    static func describe(_ kind: MobileRequest.Kind) -> String {
        switch kind {
        case .message: return "Mac이 메시지를 Stallari에게 전했어요"
        case .threadMessage(_, let thread, _, let attachments):
            let where_ = thread == ConversationID.main ? "Stallari" : "그 대화"
            return attachments?.isEmpty == false ? "Mac이 사진을 \(where_)에게 전했어요" : "Mac이 메시지를 \(where_)에게 전했어요"
        case .loadOlder: return "Mac이 이전 기록을 보냈어요"
        case .answer: return "Mac이 답변을 전했어요"
        case .cancelQuestion: return "Mac이 질문을 닫았어요"
        case .steer: return "Mac이 Hird에게 전했어요"
        case .action(_, let action): return "Mac이 실행했어요 · \(actionTitle(action))"
        case .approveProposal(_, let version): return "Mac이 제안 v\(version) 승인 요청을 처리했어요"
        case .requestProposalChanges(_, let version, _): return "Mac이 제안 v\(version) 수정 요청을 처리했어요"
        case .rejectProposal(_, let version, _): return "Mac이 제안 v\(version) 거절 요청을 처리했어요"
        }
    }

    static func actionTitle(_ action: MobileAction) -> String {
        switch action {
        case .confirmResult: "확인하고 원본에 반영"
        case .requestChanges: "다시 손봐줘"
        case .resolvedInput: "외부 작업 끝냈어요 · 이어서"
        case .stop: "멈추기"
        case .resume: "다시 시작"
        }
    }

    /// One line for a request still waiting for the Mac.
    func summary(of request: MobileRequest) -> String {
        switch request.kind {
        case .message(let text, _): return "메시지 · \(text)"
        case .threadMessage(let text, let thread, _, let attachments):
            let name = model.threadByID[thread]?.name ?? thread
            let files = attachments?.isEmpty == false ? " · 사진 \(attachments!.count)장" : ""
            return "대화 \(name) · \(text)\(files)"
        case .loadOlder(let thread, _): return "이전 기록 · \(model.threadByID[thread]?.name ?? thread)"
        case .answer(let q, let options, let text):
            let prompt = model.questions[q]?.prompt ?? "질문"
            return "답변 · \(prompt) → \((options + [text].compactMap { $0 }).joined(separator: ", "))"
        case .cancelQuestion(let q): return "질문 닫기 · \(model.questions[q]?.prompt ?? "")"
        case .steer(let t, let text): return "Hird에게 · \(model.issues[t]?.title ?? "") · \(text)"
        case .action(let t, let action): return "\(Self.actionTitle(action)) · \(model.issues[t]?.title ?? "")"
        case .approveProposal(let t, let version): return "제안 v\(version) 승인 · \(model.issues[t]?.title ?? "")"
        case .requestProposalChanges(let t, let version, let note): return "제안 v\(version) 수정 요청 · \(model.issues[t]?.title ?? "") · \(note)"
        case .rejectProposal(let t, let version, let note): return "제안 v\(version) 거절 · \(model.issues[t]?.title ?? "") · \(note)"
        }
    }
}

/// The surfaces the app can show; a deep link or a sidebar tap names one.
enum NavigationSection: Hashable {
    case dashboard
    case issues
    case alerts
    case settings
}
