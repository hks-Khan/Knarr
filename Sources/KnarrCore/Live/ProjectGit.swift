import Foundation

/// Reads a project folder for the project screen and saves its AGENTS.md.
/// Short Git metadata commands only, run when the person opens or saves; nothing polls.
enum ProjectGit {
    static let agentsFile = "AGENTS.md"

    static func inspect(_ folder: URL) async -> ProjectInspection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .init(problem: "폴더가 없어요")
        }
        guard (try? await git(["rev-parse", "--is-inside-work-tree"], at: folder)) == "true" else {
            return .init(problem: "Git 저장소가 아니에요")
        }
        guard let status = try? await git(["status", "--porcelain=v1", "--branch", "--untracked-files=normal"], at: folder) else {
            return .init(problem: "저장소 상태를 읽지 못했어요")
        }
        let parsed = parseStatus(status)
        // An empty repository has no log; that is not a problem.
        let log = (try? await git(["log", "-n", "5", "--format=%h%x1f%s%x1f%ct"], at: folder)) ?? ""
        let commits: [ProjectInspection.Commit] = log.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let seconds = TimeInterval(parts[2]) else { return nil }
            return .init(hash: parts[0], subject: parts[1], date: Date(timeIntervalSince1970: seconds))
        }
        let agentsURL = folder.appendingPathComponent(agentsFile)
        let agents = (try? String(contentsOf: agentsURL, encoding: .utf8)).map {
            ProjectInspection.AgentsFile(text: $0, uncommitted: parsed.changes.contains { $0.path == agentsFile })
        }
        return .init(branch: parsed.branch, ahead: parsed.ahead, behind: parsed.behind,
                     changes: parsed.changes, commits: commits, agents: agents)
    }

    /// `git status --porcelain=v1 --branch` output.
    static func parseStatus(_ text: String) -> (branch: String?, ahead: Int?, behind: Int?, changes: [ProjectInspection.FileChange]) {
        var branch: String?, ahead: Int?, behind: Int?
        var changes: [ProjectInspection.FileChange] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("## ") {
                var header = String(line.dropFirst(3))
                if header.hasPrefix("No commits yet on ") { header = String(header.dropFirst("No commits yet on ".count)) }
                if header.hasPrefix("HEAD (no branch)") { continue }
                var tracking: String?
                if let bracket = header.range(of: " [") {
                    tracking = String(header[bracket.upperBound...].dropLast())
                    header = String(header[..<bracket.lowerBound])
                }
                if let dots = header.range(of: "...") {
                    branch = String(header[..<dots.lowerBound])
                    ahead = 0; behind = 0
                    for part in (tracking ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        let words = part.split(separator: " ")
                        guard words.count == 2, let n = Int(words[1]) else { continue }
                        if words[0] == "ahead" { ahead = n } else if words[0] == "behind" { behind = n }
                    }
                } else {
                    branch = header
                }
                continue
            }
            guard line.count > 3 else { continue }
            let code = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count > 1 { path = String(path.dropFirst().dropLast()) }
            changes.append(.init(code: code, path: path))
        }
        return (branch, ahead, behind, changes)
    }

    /// Writes AGENTS.md and commits that one file, so new Hird work copies (made from commits) read it.
    /// Other staged or unstaged work in the folder is left exactly as it was.
    /// - Parameter expected: the text read before editing, nil when the file did not exist.
    static func saveAgents(_ folder: URL, text: String, expected: String?) async throws {
        guard (try? await git(["rev-parse", "--is-inside-work-tree"], at: folder)) == "true" else { throw ProjectGitError.notRepository }
        let url = folder.appendingPathComponent(agentsFile)
        let current = try? String(contentsOf: url, encoding: .utf8)
        guard current == expected else { throw ProjectGitError.changedOnDisk }
        let body = text.hasSuffix("\n") ? text : text + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        do {
            _ = try await git(["add", "--", agentsFile], at: folder)
            // Nothing differs from HEAD: no empty commit.
            if (try? await git(["diff", "--cached", "--quiet", "HEAD", "--", agentsFile], at: folder)) != nil { return }
            _ = try await git(["commit", "-q", "--only", "-m", "Update AGENTS.md", "--", agentsFile], at: folder)
        } catch { throw ProjectGitError.commitFailed }
    }

    private static func git(_ arguments: [String], at folder: URL) async throws -> String {
        try await HirdWorkspace.git(arguments, at: folder)
    }
}
