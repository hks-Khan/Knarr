import Foundation

public struct ProjectMergeResult: Identifiable, Sendable, Hashable {
    public let id: String
    public let issueID: Issue.ID
    public let title: String
    public let commitCount: Int
    public let changedFileCount: Int
    public let judgement: String

    public init(id: String, issueID: Issue.ID, title: String, commitCount: Int, changedFileCount: Int, judgement: String) {
        self.id = id
        self.issueID = issueID
        self.title = title
        self.commitCount = commitCount
        self.changedFileCount = changedFileCount
        self.judgement = judgement
    }
}

/// Read-only comparison of saved Hird commits with the project's local main branch. Never merges or fetches.
public struct ProjectMergeResults: Sendable {
    public let results: [ProjectMergeResult]
    public let problem: String?

    public init(results: [ProjectMergeResult], problem: String? = nil) {
        self.results = results
        self.problem = problem
    }

    public static func read(root: URL, issues: [Issue]) async -> Self {
        await read(root: root, issues: issues, runs: [])
    }

    /// The caller scopes issues and durable runs to the selected project. Historical snapshots are not on Issue.
    public static func read(root: URL, issues: [Issue], runs: [PersistedRun]) async -> Self {
        await Task.detached(priority: .userInitiated) {
            await load(root: root, issues: issues, runs: runs)
        }.value
    }

    private struct Candidate {
        let issue: Issue
        let result: RunResult
        let judgement: String
    }

    private static func load(root: URL, issues: [Issue], runs: [PersistedRun]) async -> Self {
        let commonDirectory: String
        do {
            commonDirectory = try await HirdWorkspace.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root)
        } catch { return .init(results: [], problem: "프로젝트 Git 저장소를 읽지 못했어요") }
        do {
            _ = try await HirdWorkspace.git(["rev-parse", "--verify", "refs/heads/main^{commit}"], at: root)
        } catch { return .init(results: [], problem: "main 브랜치가 없어 합칠 결과를 비교하지 못했어요") }

        var candidates: [Candidate] = []
        for issue in issues {
            let ownRuns = runs.filter { $0.issueID == issue.id }.sorted {
                $0.startedAt == $1.startedAt ? $0.id.rawValue < $1.id.rawValue : $0.startedAt > $1.startedAt
            }
            for run in ownRuns {
                var history = run.resultHistory
                if let result = run.result, !history.contains(result) { history.append(result) }
                for result in history.reversed() {
                    candidates.append(.init(issue: issue, result: result, judgement: judgement(issue: issue, run: run, result: result)))
                }
            }
            if let result = issue.latestResult {
                candidates.append(.init(issue: issue, result: result, judgement: judgement(issue: issue, run: nil, result: result)))
            }
        }

        var results: [ProjectMergeResult] = []
        var resolved: [(candidate: Candidate, commit: String)] = []
        var problems: [String] = []
        var seen = Set<String>()
        var workspaceDirectories: [String: String] = [:]
        for candidate in candidates {
            let result = candidate.result
            // A worktree from another repository is not a result for this project, even when an identical
            // commit happens to have been fetched here. Missing cleaned-up worktrees need no content read.
            if FileManager.default.fileExists(atPath: result.worktreePath) {
                let directory: String
                if let cached = workspaceDirectories[result.worktreePath] { directory = cached }
                else {
                    guard let read = try? await HirdWorkspace.git(["rev-parse", "--path-format=absolute", "--git-common-dir"],
                        at: URL(fileURLWithPath: result.worktreePath, isDirectory: true)) else {
                        problems.append("\(candidate.issue.title): Hird 작업 폴더의 저장소를 확인하지 못했어요")
                        continue
                    }
                    workspaceDirectories[result.worktreePath] = read
                    directory = read
                }
                guard URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL ==
                    URL(fileURLWithPath: commonDirectory).resolvingSymlinksInPath().standardizedFileURL else { continue }
            }
            guard let savedCommit = result.commit, !savedCommit.isEmpty else {
                problems.append("\(candidate.issue.title): 저장된 Hird 결과 커밋이 없어요")
                continue
            }
            guard savedCommit.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                problems.append("\(candidate.issue.title): 저장된 Hird 결과 커밋이 올바르지 않아요")
                continue
            }
            do {
                let commit = try await HirdWorkspace.git(["rev-parse", "--verify", "--end-of-options", savedCommit + "^{commit}"], at: root)
                let id = candidate.issue.id.rawValue + ":" + commit
                guard seen.insert(id).inserted else { continue }
                resolved.append((candidate, commit))
            } catch {
                problems.append("\(candidate.issue.title): Hird 결과 커밋을 main과 비교하지 못했어요")
            }
        }
        // Only independent saved tips are useful rows. A newer result already carries every
        // commit in its saved ancestors; unrelated branches must remain independently visible.
        let byIssue = Dictionary(grouping: resolved, by: { $0.candidate.issue.id })
        var tipIDs = Set<String>()
        for (issueID, saved) in byIssue {
            do {
                let tips: [String]
                if saved.count == 1 { tips = [saved[0].commit] }
                else {
                    let text = try await HirdWorkspace.git(["merge-base", "--independent"] + saved.map(\.commit), at: root)
                    tips = text.split(separator: "\n").map(String.init)
                }
                for tip in tips { tipIDs.insert(issueID.rawValue + ":" + tip) }
            } catch {
                problems.append("\(saved[0].candidate.issue.title): Hird 결과 커밋의 포함 관계를 읽지 못했어요")
            }
        }
        for saved in resolved {
            let candidate = saved.candidate
            let commit = saved.commit
            let id = candidate.issue.id.rawValue + ":" + commit
            guard tipIDs.contains(id) else { continue }
            do {
                let countText = try await HirdWorkspace.git(["rev-list", "--count", "refs/heads/main.." + commit, "--"], at: root)
                guard let commitCount = Int(countText) else { throw HirdError.workspace }
                guard commitCount > 0 else { continue }
                let paths = try await HirdWorkspace.git([
                    "diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", "--find-renames",
                    "refs/heads/main..." + commit, "--"
                ], at: root)
                results.append(.init(id: id, issueID: candidate.issue.id, title: candidate.issue.title,
                                     commitCount: commitCount, changedFileCount: paths.split(separator: "\0").count,
                                     judgement: candidate.judgement))
            } catch {
                problems.append("\(candidate.issue.title): Hird 결과 커밋을 main과 비교하지 못했어요")
            }
        }
        // Preserve issue/run order while collapsing repeated failures from multiple saved snapshots.
        var reported = Set<String>()
        let uniqueProblems = problems.filter { reported.insert($0).inserted }
        return .init(results: results, problem: uniqueProblems.isEmpty ? nil : uniqueProblems.joined(separator: "\n"))
    }

    private static func judgement(issue: Issue, run: PersistedRun?, result: RunResult) -> String {
        if let run {
            guard run.result?.commit == result.commit else { return "중간 결과 · 미완료" }
            if let evidence = run.acceptanceEvidence, !evidence.isEmpty {
                if evidence.allSatisfy({ $0.state == .met }) { return "완료 판정" }
                if evidence.contains(where: { $0.state == .unmet }) { return "미완료 판정" }
            }
            switch run.state {
            case .working, .waitingOnHuman: return "미완료 · 작업 중"
            case .failed, .cancelled, .interrupted: return "미완료 · 실행 종료"
            case .succeeded:
                if issue.latestResult?.commit == result.commit, issue.state == .done { return "완료 판정" }
                return "Hird 실행 완료 · 판정 대기"
            }
        }
        switch issue.state {
        case .done: return "완료 판정"
        case .failed, .rejected: return "미완료 판정"
        case .running, .needsInput, .awaitingApproval: return "판정 대기"
        }
    }
}
