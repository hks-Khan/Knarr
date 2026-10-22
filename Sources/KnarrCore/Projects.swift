import Foundation

/// How a project wants its work done and judged. Stored with the project in Knarr's database;
/// the repository's own AGENTS.md is read from the folder, never copied here.
public struct ProjectSettings: Codable, Sendable, Hashable {
    /// What "확인하고 원본에 반영" does with a confirmed result.
    public enum ResultMode: String, Codable, Sendable, Hashable, CaseIterable {
        /// Merge the Hird branch into the project's current branch.
        case merge
        /// Commit on the Hird branch and leave merging to the person.
        case branch
    }

    public enum WorkspaceStyle: String, Codable, Sendable, Hashable, CaseIterable {
        case development, preparation
        public var label: String { self == .development ? "개발형" : "준비·아카이브형" }
    }
    public var workspaceStyle: WorkspaceStyle

    /// Commands whose output Stallari asks Hird for as evidence.
    public var verification: [VerificationCommand]
    /// Added to every Issue's completion criteria in this project.
    public var criteria: [String]
    /// Notes between the person and Stallari that do not belong in the repository.
    public var memo: String
    public var resultMode: ResultMode
    /// Hird runs working in this project at once; 0 means unlimited.
    public var maxHirds: Int
    /// `provider/id` for new Hird runs here; nil leaves the choice to Stallari.
    public var hirdModel: String?
    public var hirdThinking: String
    /// Index into the project color palette.
    public var color: Int

    /// Numeric steps offered by the UI, followed by unlimited. Not an admission cap.
    public static let hirdRange = 1...32

    public init(verification: [VerificationCommand] = [], criteria: [String] = [], memo: String = "",
                resultMode: ResultMode = .merge, maxHirds: Int = 2, hirdModel: String? = nil, hirdThinking: String = "xhigh", color: Int = 0, workspaceStyle: WorkspaceStyle = .development) {
        self.workspaceStyle = workspaceStyle
        self.verification = verification; self.criteria = criteria; self.memo = memo
        self.resultMode = resultMode; self.maxHirds = maxHirds; self.hirdModel = hirdModel; self.hirdThinking = hirdThinking; self.color = color
    }

    // Every field may be missing in older rows.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProjectSettings()
        workspaceStyle = try c.decodeIfPresent(WorkspaceStyle.self, forKey: .workspaceStyle) ?? d.workspaceStyle
        verification = try c.decodeIfPresent([VerificationCommand].self, forKey: .verification) ?? d.verification
        criteria = try c.decodeIfPresent([String].self, forKey: .criteria) ?? d.criteria
        memo = try c.decodeIfPresent(String.self, forKey: .memo) ?? d.memo
        resultMode = try c.decodeIfPresent(ResultMode.self, forKey: .resultMode) ?? d.resultMode
        maxHirds = try c.decodeIfPresent(Int.self, forKey: .maxHirds) ?? d.maxHirds
        hirdModel = try c.decodeIfPresent(String.self, forKey: .hirdModel).map(HiveProviderRuntime.currentModelIdentifier)
        hirdThinking = try c.decodeIfPresent(String.self, forKey: .hirdThinking) ?? d.hirdThinking
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? d.color
    }

    public func allowsAdditionalHird(activeCount: Int) -> Bool {
        maxHirds == 0 || activeCount < maxHirds
    }

    /// Settings with blank rows dropped and invalid negative limits corrected, as they are saved.
    public var cleaned: ProjectSettings {
        var s = self
        s.verification = verification.map { var v = $0; v.name = v.name.trimmingCharacters(in: .whitespaces); v.command = v.command.trimmingCharacters(in: .whitespaces); return v }
            .filter { !$0.command.isEmpty }
        var seen: Set<String> = []
        s.criteria = criteria.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        s.memo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        s.maxHirds = maxHirds == 0 ? 0 : max(1, maxHirds)
        if s.hirdModel?.isEmpty == true { s.hirdModel = nil }
        return s
    }
}

public struct VerificationCommand: Codable, Sendable, Hashable {
    public enum Timing: String, Codable, Sendable, Hashable, CaseIterable {
        case always, codeChanged, screenChanged, onRequest
        public var label: String {
            switch self {
            case .always: "항상"
            case .codeChanged: "코드가 바뀔 때"
            case .screenChanged: "화면 코드가 바뀔 때"
            case .onRequest: "요청할 때만"
            }
        }
        /// How Stallari reads it.
        public var english: String {
            switch self {
            case .always: "always"
            case .codeChanged: "when source code changed"
            case .screenChanged: "when UI code changed"
            case .onRequest: "only when asked"
            }
        }
    }

    public var name: String
    public var command: String
    public var timing: Timing

    public init(name: String, command: String, timing: Timing = .always) {
        self.name = name; self.command = command; self.timing = timing
    }
}

/// The project folder as Git sees it, read once when the project is opened.
public struct ProjectInspection: Sendable, Hashable {
    public struct FileChange: Sendable, Hashable {
        /// Porcelain status: "M", "A", "D", "R", "??" and the like.
        public var code: String
        public var path: String
        public init(code: String, path: String) { self.code = code; self.path = path }
    }

    public struct Commit: Sendable, Hashable {
        public var hash: String
        public var subject: String
        public var date: Date
        public init(hash: String, subject: String, date: Date) { self.hash = hash; self.subject = subject; self.date = date }
    }

    /// The repository's AGENTS.md at the folder root.
    public struct AgentsFile: Sendable, Hashable {
        public var text: String
        /// The file differs from its last commit.
        public var uncommitted: Bool
        public init(text: String, uncommitted: Bool) { self.text = text; self.uncommitted = uncommitted }
    }

    public var readAt: Date
    /// nil when the folder is fine; otherwise why nothing else could be read.
    public var problem: String?
    /// nil on a detached HEAD.
    public var branch: String?
    /// Commits not yet pushed / not yet pulled; nil without an upstream branch.
    public var ahead: Int?
    public var behind: Int?
    public var changes: [FileChange]
    public var commits: [Commit]
    public var agents: AgentsFile?

    public init(readAt: Date = .now, problem: String? = nil, branch: String? = nil, ahead: Int? = nil, behind: Int? = nil,
                changes: [FileChange] = [], commits: [Commit] = [], agents: AgentsFile? = nil) {
        self.readAt = readAt; self.problem = problem; self.branch = branch; self.ahead = ahead; self.behind = behind
        self.changes = changes; self.commits = commits; self.agents = agents
    }
}

public enum ProjectGitError: Error, Sendable, Hashable, LocalizedError {
    case changedOnDisk
    case notRepository
    case commitFailed

    public var errorDescription: String? {
        switch self {
        case .changedOnDisk: "AGENTS.md가 그사이 바뀌었어요. 다시 읽은 뒤 고쳐 주세요"
        case .notRepository: "프로젝트 폴더가 Git 저장소가 아니에요"
        case .commitFailed: "AGENTS.md는 저장했지만 커밋하지 못했어요. 저장소 상태를 확인해 주세요"
        }
    }
}
