import Foundation

// What Knarr on the Mac and Knarr on the iPhone share through the person's private CloudKit
// database. The Mac writes issues, questions, messages, projects, alerts and its status; the
// phone writes requests, which the Mac applies and then deletes.

public enum MobileLimits {
    /// Characters kept from one long text so a record stays far below CloudKit's 1 MB limit.
    public static let text = 6_000
    /// One image the phone sends with a message. All three limits are checked on both ends.
    public static let attachmentCount = 3
    public static let attachmentBytes = 8_000_000
    /// Messages the Mac always keeps on the phone, per conversation thread: the same recent window
    /// the app has always uploaded, now applied to each conversation rather than one merged list.
    public static let recentPerThread = 150
    /// Older messages sent per `loadOlder` page.
    public static let historyPage = 50
    /// Older messages the phone keeps per thread; the oldest pages are dropped.
    public static let historyPerThread = 400
    /// Older messages the Mac leaves in CloudKit per thread before deleting the oldest pages.
    public static let historyOnMac = 150
    /// Screen captures attached to one Issue; each is a downscaled JPEG.
    public static let captureCount = 4
}

public enum MobileZone {
    public static let name = "Knarr"
    public static let container = "iCloud.com.kyen.knarr"
}

public struct MobileIssue: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable { case awaitingApproval, rejected, running, needsInput, failed, done }
    /// Which list the phone shows the Issue in, decided on the Mac exactly like its panel.
    public enum Group: String, Codable, Sendable, CaseIterable {
        case mine, working, stopped, finished
        public var title: String {
            switch self {
            case .mine: "내가 할 것"
            case .working: "Hird 일하는 중"
            case .stopped: "멈춘 것"
            case .finished: "끝난 것"
            }
        }
    }
    public struct Criterion: Codable, Sendable, Hashable {
        public enum State: String, Codable, Sendable { case pending, met, unmet }
        public var text: String
        public var state: State
        /// What Stallari judged from, clipped.
        public var evidence: String?
        public init(text: String, state: State, evidence: String? = nil) { self.text = text; self.state = state; self.evidence = evidence }
    }
    /// One Hird's plan, without the per-tool activity that changes every few seconds.
    public struct Run: Codable, Sendable, Hashable {
        public enum Status: String, Codable, Sendable { case working, waiting, failed, done }
        public struct Step: Codable, Sendable, Hashable {
            public enum State: String, Codable, Sendable { case done, active, pending, waiting, blocked, failed }
            public var title: String
            public var state: State
            public init(title: String, state: State) { self.title = title; self.state = state }
        }
        public var name: String
        public var role: String
        public var status: Status
        public var steps: [Step]
        /// One line of what the run is doing now: the tool call in flight (`HirdProgress` basis),
        /// else the next unfinished plan step. A plain string, so a Mac-side activity line can feed it.
        public var activity: String?
        /// The five change stages; `stage` is the one in progress, 1-based.
        public var stages: [Step]?
        public var stage: Int?
        public var startedAt: Date?
        /// Counts of saved checks that passed, failed, or are still running.
        public var checksPassed: Int?
        public var checksFailed: Int?
        public init(name: String, role: String, status: Status, steps: [Step], activity: String? = nil,
                    stages: [Step]? = nil, stage: Int? = nil, startedAt: Date? = nil,
                    checksPassed: Int? = nil, checksFailed: Int? = nil) {
            self.name = name; self.role = role; self.status = status; self.steps = steps
            self.activity = activity; self.stages = stages; self.stage = stage; self.startedAt = startedAt
            self.checksPassed = checksPassed; self.checksFailed = checksFailed
        }
    }
    public struct Event: Codable, Sendable, Hashable {
        public var at: Date
        public var actor: String
        public var text: String
        public init(at: Date, actor: String, text: String) { self.at = at; self.actor = actor; self.text = text }
    }

    /// Added inside payload only; old phones ignore it and still decode the legacy state.
    public enum ProposalState: String, Codable, Sendable { case awaitingApproval, rejected }
    public struct Proposal: Codable, Sendable, Hashable {
        public var version: Int
        public var title: String
        public var criteria: [String]
        public var instruction: String
        public var model: String
        public var thinking: String?
        public var mode: String
        public init(version: Int, title: String, criteria: [String], instruction: String, model: String, thinking: String?, mode: String) {
            self.version = version; self.title = title; self.criteria = criteria; self.instruction = instruction
            self.model = model; self.thinking = thinking; self.mode = mode
        }
    }
    public var proposalState: ProposalState?
    public var proposal: Proposal?
    public var proposalReviewNote: String?
    public var id: String
    public var title: String
    public var project: String
    public var state: State
    public var group: Group
    /// The Mac card's presentation state key (`IssueStatus.key`); nil in records written before it travelled.
    public var status: String?
    public var headline: String
    public var detail: String
    public var criteria: [Criterion]
    /// e.g. "2/4 · 테스트 실행"
    public var progress: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var runs: [Run]
    /// Newest first, at most `MobileProjection.eventLimit`.
    public var events: [Event]
    /// What happened when the confirmed result was brought into the original project.
    public var application: String?
    /// The conversation this Issue was discussed in; nil in records written before threads travelled.
    public var thread: String?
    /// The run's final report, clipped; nil when there is none.
    public var report: String?
    /// Command and exit code of the run's saved checks, newest first.
    public var verifications: [Verification]?
    /// Downscaled screen captures of the run, bytes read from CKAsset fields.
    public var captures: [MobileCapture]?

    public struct Verification: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var command: String
        /// nil when the command did not finish; never a pass.
        public var exitCode: Int?
        public var at: Date
        public var summary: String?
        public init(id: String, command: String, exitCode: Int?, at: Date, summary: String? = nil) {
            self.id = id; self.command = command; self.exitCode = exitCode; self.at = at; self.summary = summary
        }
    }

    public init(id: String, title: String, project: String, state: State, group: Group, headline: String, detail: String,
                criteria: [Criterion], progress: String?, startedAt: Date, updatedAt: Date,
                runs: [Run] = [], events: [Event] = [], application: String? = nil,
                proposal: Proposal? = nil, proposalReviewNote: String? = nil,
                report: String? = nil, verifications: [Verification]? = nil, captures: [MobileCapture]? = nil,
                thread: String? = nil, status: String? = nil) {
        self.id = id; self.title = title; self.project = project; self.state = state; self.group = group
        self.status = status
        self.headline = headline; self.detail = detail; self.criteria = criteria; self.progress = progress
        self.startedAt = startedAt; self.updatedAt = updatedAt
        self.runs = runs; self.events = events; self.application = application
        self.report = report; self.verifications = verifications; self.captures = captures; self.thread = thread
        // Legacy wire records may claim running without any live execution. Normalize in memory only.
        if state == .running, !runs.contains(where: { $0.status == .working || $0.status == .waiting }) {
            self.state = .failed; self.group = .stopped
            self.headline = runs.isEmpty ? "실행 없음 · 다시 제안 필요" : "실행 종료 · 판정 필요"
            self.progress = nil
        }
        self.proposalState = state == .awaitingApproval ? .awaitingApproval : state == .rejected ? .rejected : nil
        self.proposal = proposal; self.proposalReviewNote = proposalReviewNote
    }

    enum CodingKeys: String, CodingKey {
        case id, title, project, state, group, headline, detail, criteria, progress, startedAt, updatedAt, runs, events, application
        case proposalState, proposal, proposalReviewNote, report, verifications, captures, thread, status
    }

    // Records written before runs and events existed still decode.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), title: c.decode(String.self, forKey: .title),
                      project: c.decode(String.self, forKey: .project), state: c.decode(State.self, forKey: .state),
                      group: c.decode(Group.self, forKey: .group), headline: c.decode(String.self, forKey: .headline),
                      detail: c.decode(String.self, forKey: .detail), criteria: c.decode([Criterion].self, forKey: .criteria),
                      progress: c.decodeIfPresent(String.self, forKey: .progress), startedAt: c.decode(Date.self, forKey: .startedAt),
                      updatedAt: c.decode(Date.self, forKey: .updatedAt),
                      runs: c.decodeIfPresent([Run].self, forKey: .runs) ?? [],
                      events: c.decodeIfPresent([Event].self, forKey: .events) ?? [],
                      application: c.decodeIfPresent(String.self, forKey: .application),
                      proposal: c.decodeIfPresent(Proposal.self, forKey: .proposal),
                      proposalReviewNote: c.decodeIfPresent(String.self, forKey: .proposalReviewNote),
                      report: c.decodeIfPresent(String.self, forKey: .report),
                      verifications: c.decodeIfPresent([Verification].self, forKey: .verifications),
                      captures: c.decodeIfPresent([MobileCapture].self, forKey: .captures),
                      thread: c.decodeIfPresent(String.self, forKey: .thread),
                      status: c.decodeIfPresent(String.self, forKey: .status))
        proposalState = try c.decodeIfPresent(ProposalState.self, forKey: .proposalState) ?? proposalState
        if let proposalState { state = proposalState == .awaitingApproval ? .awaitingApproval : .rejected }
    }
}

/// One conversation the Mac keeps: the main Stallari thread, a project thread, or an Issue thread.
/// Only the title, ownership and latest timing travel; the messages themselves are `MobileMessage`s.
public struct MobileThread: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case main, project, issue }
    public var id: String
    public var name: String
    public var kind: Kind
    public var project: String?
    public var issue: String?
    /// nil when the conversation has no messages yet.
    public var lastMessageAt: Date?
    /// A Hird is working or Stallari is answering in this conversation.
    public var working: Bool
    /// How many messages the Mac has for this conversation; the phone pages older ones on request.
    public var messageCount: Int
    public init(id: String, name: String, kind: Kind, project: String? = nil, issue: String? = nil,
                lastMessageAt: Date? = nil, working: Bool = false, messageCount: Int = 0) {
        self.id = id; self.name = name; self.kind = kind; self.project = project; self.issue = issue
        self.lastMessageAt = lastMessageAt; self.working = working; self.messageCount = messageCount
    }
}

/// A picture the phone sends with a message. The bytes travel as a CKAsset field on the request
/// record, never inside the JSON payload; `data` is filled in at the CloudKit boundary.
public struct MobileAttachment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var type: String
    public var byteCount: Int
    public var data: Data?
    public init(id: String = UUID().uuidString, name: String, type: String, byteCount: Int, data: Data? = nil) {
        self.id = id; self.name = name; self.type = type; self.byteCount = byteCount; self.data = data
    }

    enum CodingKeys: String, CodingKey { case id, name, type, byteCount }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  type: try c.decode(String.self, forKey: .type), byteCount: try c.decode(Int.self, forKey: .byteCount))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type); try c.encode(byteCount, forKey: .byteCount)
    }

    /// The extension the Mac writes the received bytes under.
    public var fileExtension: String {
        switch type.lowercased() {
        case "image/png": "png"
        case "image/heic": "heic"
        case "image/webp": "webp"
        default: "jpg"
        }
    }
}

/// One downscaled screen capture of a finished run, read from its CKAsset field.
public struct MobileCapture: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var caption: String
    public var width: Int
    public var height: Int
    public var data: Data?
    public init(id: String, caption: String, width: Int, height: Int, data: Data? = nil) {
        self.id = id; self.caption = caption; self.width = width; self.height = height; self.data = data
    }

    enum CodingKeys: String, CodingKey { case id, caption, width, height }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), caption: try c.decode(String.self, forKey: .caption),
                  width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(caption, forKey: .caption)
        try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
    }
}

public struct MobileQuestion: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable { case pending, answered, cancelled }
    public var id: String
    public var issue: String
    public var asker: String
    public var prompt: String
    public var options: [String]
    public var allowsMultiple: Bool
    public var state: State
    /// What was decided, for answered questions.
    public var answer: String?
    public var askedAt: Date

    public init(id: String, issue: String, asker: String, prompt: String, options: [String], allowsMultiple: Bool,
                state: State, answer: String?, askedAt: Date) {
        self.id = id; self.issue = issue; self.asker = asker; self.prompt = prompt; self.options = options
        self.allowsMultiple = allowsMultiple; self.state = state; self.answer = answer; self.askedAt = askedAt
    }
}

public struct MobileReport: Codable, Sendable, Hashable {
    public var title: String
    public var lines: [String]
    public var state: String
    public var error: String?
    public init(title: String, lines: [String], state: String, error: String? = nil) {
        self.title = title; self.lines = lines; self.state = state; self.error = error
    }
}

public struct MobileMessage: Codable, Sendable, Hashable, Identifiable {
    /// `issue`: a card for a Issue Stallari started (text is its title). `question`: a question card (text is the prompt).
    /// `autoCheck`: Stallari's routine checks, summary on the first line. `report`: a generated work report card.
    public enum Role: String, Codable, Sendable { case user, stallari, notice, issue, question, autoCheck, report }
    /// Progress the provider reported for this row, kept apart from the answer text. Carries the same
    /// values the Mac's transcript uses, so both screens group the records identically.
    public struct Activity: Codable, Sendable, Hashable {
        /// `reasoning` or `tool`, exactly as the Mac recorded it; never guessed from the text.
        public var kind: String
        public var title: String
        public var state: String
        /// The Mac's status wording for `state`, e.g. `진행 중`.
        public var label: String
        public var startedAt: Date
        public var updatedAt: Date
        public init(kind: String, title: String, state: String, label: String, startedAt: Date, updatedAt: Date) {
            self.kind = kind; self.title = title; self.state = state; self.label = label
            self.startedAt = startedAt; self.updatedAt = updatedAt
        }
    }
    public var id: String
    public var at: Date
    public var role: Role
    public var text: String
    public var project: String?
    /// The Issue a card or notice belongs to.
    public var issue: String?
    /// The question a question card shows.
    public var question: String?
    /// A work report card's lines and state; nil for every other role.
    public var report: MobileReport?
    /// Progress reported for this row; nil for ordinary messages and for rows written before it travelled.
    public var activity: Activity?
    /// The conversation this message belongs to; nil in records written before threads travelled.
    public var thread: String?
    /// Files shown beside the text, only for messages the person sent from the phone.
    public var attachments: [MobileAttachment]?
    public init(id: String, at: Date, role: Role, text: String, project: String?, issue: String? = nil, question: String? = nil,
                thread: String? = nil, attachments: [MobileAttachment]? = nil, report: MobileReport? = nil,
                activity: Activity? = nil) {
        self.id = id; self.at = at; self.role = role; self.text = text; self.project = project; self.issue = issue
        self.question = question; self.thread = thread; self.attachments = attachments; self.report = report
        self.activity = activity
    }
}

public struct MobileProject: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var openIssues: Int
    public init(id: String, name: String, openIssues: Int) { self.id = id; self.name = name; self.openIssues = openIssues }
}

/// The phone's buttons, mirroring `IssueAction` on the Mac.
public enum MobileAction: String, Codable, Sendable, CaseIterable {
    case confirmResult, requestChanges, resolvedInput, stop, resume
}

public struct MobileRequest: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: Codable, Sendable, Hashable {
        case message(text: String, project: String?)
        /// A message for one conversation, optionally with pictures. Older Macs do not decode this
        /// kind, so they leave it unapplied instead of sending it to the wrong conversation.
        case threadMessage(text: String, thread: String, project: String?, attachments: [MobileAttachment]?)
        /// Asks the Mac to send one page of messages older than `before` for a conversation.
        case loadOlder(thread: String, before: Date)
        case answer(question: String, options: [String], text: String?)
        case cancelQuestion(String)
        case action(issue: String, action: MobileAction)
        case steer(issue: String, text: String)
        case approveProposal(issue: String, version: Int)
        case requestProposalChanges(issue: String, version: Int, note: String)
        case rejectProposal(issue: String, version: Int, note: String)

        public var proposalIssue: String? {
            switch self {
            case .approveProposal(let issue, _), .requestProposalChanges(let issue, _, _), .rejectProposal(let issue, _, _): issue
            default: nil
            }
        }

        /// The conversation a message request is headed for, when it names one.
        public var thread: String? {
            switch self {
            case .threadMessage(_, let thread, _, _), .loadOlder(let thread, _): thread
            default: nil
            }
        }

        public var attachments: [MobileAttachment] {
            switch self {
            case .threadMessage(_, _, _, let attachments): attachments ?? []
            default: []
            }
        }


    }
    public var id: String
    public var createdAt: Date
    public var kind: Kind
    public init(id: String, createdAt: Date, kind: Kind) { self.id = id; self.createdAt = createdAt; self.kind = kind }
}

/// Written once per event worth a push; the phone's subscription turns each new one into a notification.
public struct MobileAlert: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var title: String
    public var body: String
    public var issue: String?
    public var requestID: String?
    public var requestFailure: String?
    public init(id: String, createdAt: Date, title: String, body: String, issue: String?,
                requestID: String? = nil, requestFailure: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.title = title; self.body = body; self.issue = issue
        self.requestID = requestID; self.requestFailure = requestFailure
    }
}

public struct MobileStatus: Codable, Sendable, Hashable {
    public var isResponding: Bool
    public var engine: String
    /// False once Knarr on the Mac quit normally; nil in older records.
    public var macRunning: Bool?
    public var liveActivityRemoteEnabled: Bool?
    public init(isResponding: Bool, engine: String, macRunning: Bool? = nil, liveActivityRemoteEnabled: Bool? = nil) {
        self.isResponding = isResponding; self.engine = engine; self.macRunning = macRunning
        self.liveActivityRemoteEnabled = liveActivityRemoteEnabled
    }
}

public enum MobileRecord: Sendable, Hashable {
    case issue(MobileIssue)
    case question(MobileQuestion)
    case message(MobileMessage)
    case project(MobileProject)
    case request(MobileRequest)
    case alert(MobileAlert)
    case status(MobileStatus)
    case activityDevice(MobileActivityDevice)
    case thread(MobileThread)

    public enum Kind: String, Sendable, CaseIterable {
        case issue = "Issue", question = "Question", message = "Message", project = "Project"
        case request = "Request", alert = "Alert", status = "Status", activityDevice = "ActivityDevice"
        case thread = "Thread"
        /// Requests belong to the phone and alerts are one-off events, so a Mac snapshot never deletes them.
        public var isSnapshot: Bool { self != .request && self != .alert && self != .activityDevice }
    }

    public var kind: Kind {
        switch self {
        case .issue: .issue
        case .question: .question
        case .message: .message
        case .project: .project
        case .request: .request
        case .alert: .alert
        case .status: .status
        case .activityDevice: .activityDevice
        case .thread: .thread
        }
    }

    public var recordName: String {
        switch self {
        case .issue(let v): "thing-\(v.id)"
        case .question(let v): "question-\(v.id)"
        case .message(let v): "message-\(v.id)"
        case .project(let v): "project-\(v.id)"
        case .request(let v): "request-\(v.id)"
        case .alert(let v): "alert-\(v.id)"
        case .status: "status"
        case .activityDevice(let v): "activityDevice-\(v.id)"
        case .thread(let v): "thread-\(v.id)"
        }
    }
}

extension String {
    /// Keeps at most `limit` characters, marking a cut with "…".
    public func clipped(to limit: Int = MobileLimits.text) -> String {
        count > limit ? String(prefix(limit)) + "…" : self
    }
}
