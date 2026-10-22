import Foundation

/// Hird work copies are full Git worktrees (build output included), so they add up fast.
/// A copy goes once nothing can still need it: its result was merged, a later run replaced it,
/// or the run stopped. Branches and patches stay, so any result can be rebuilt.
public enum WorkspaceCleanup {
    public enum Problem: Error, Sendable { case outsideResults }

    /// Copies still needed: running runs, the latest result of a Issue waiting for confirmation,
    /// and the latest result of a Issue whose merge was refused (it is retried from the copy).
    public static func removable(runs: [PersistedRun], issues: [Issue]) -> [RunWorkspace] {
        let byID = Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let latest = Dictionary(runs.map { ($0.issueID, $0.id) }, uniquingKeysWith: { _, b in b })
        return runs.compactMap { run in
            guard run.state.isTerminal, let workspace = run.workspace else { return nil }
            if let issue = byID[run.issueID], latest[run.issueID] == run.id {
                if issue.state == .done && !issue.confirmed { return nil }
                if case .blocked = issue.application { return nil }
            }
            return workspace
        }
    }

    /// Removes one work copy through Git so the project's worktree list stays right.
    /// Refuses anything outside `resultsRoot`. Returns the bytes freed.
    @discardableResult
    public static func remove(_ workspace: RunWorkspace, project: URL, resultsRoot: URL) async throws -> Int64 {
        let path = URL(fileURLWithPath: workspace.worktreePath).standardizedFileURL.resolvingSymlinksInPath().path
        let root = resultsRoot.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/") else { throw Problem.outsideResults }
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let size = bytes(at: URL(fileURLWithPath: path))
        do { _ = try await HirdWorkspace.git(["worktree", "remove", "--force", path], at: project) }
        catch {
            try? FileManager.default.removeItem(atPath: path)
            _ = try? await HirdWorkspace.git(["worktree", "prune"], at: project)
        }
        return FileManager.default.fileExists(atPath: path) ? 0 : size
    }

    public static func bytes(at url: URL) -> Int64 {
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in items {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

/// Sizes as numbers ("0 KB", "1.8 GB"), never the formatter's localized words.
public enum Bytes {
    public static func text(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }
}
