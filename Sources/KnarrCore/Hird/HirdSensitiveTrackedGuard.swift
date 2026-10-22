import Foundation
import Darwin

extension HirdWorkspace {
    /// Never ask diff/add to open tracked credentials. An unchanged HEAD entry may
    /// pass using the original index's stat cache only. Any stale/changed/ambiguous
    /// credential metadata fails closed rather than hashing its contents.
    static func protectSensitiveTracked(at tree: URL, index: URL, stage: URL, root: URL, policy: HirdCapturePolicy) async throws {
        let rows = try await git(["ls-files", "--stage", "-z"], at: tree, index: index, policy: policy, diagnosticRoot: root)
        var expected: [String: String] = [:]
        for row in rows.split(separator: "\0") {
            guard let tab = row.firstIndex(of: "\t") else { throw HirdError.workspace }
            let path = String(row[row.index(after: tab)...])
            if policy.isSensitive(path) { expected[path] = String(row[..<tab]) }
        }
        guard !expected.isEmpty else { return }
        let debug = try await git(["ls-files", "--stage", "--debug", "-z"], at: tree, policy: policy, diagnosticRoot: root)
        var cursor = debug.startIndex, verified: Set<String> = []
        while cursor < debug.endIndex {
            guard let zero = debug[cursor...].firstIndex(of: "\0") else { throw HirdError.workspace }
            let row = debug[cursor..<zero]
            guard let tab = row.firstIndex(of: "\t") else { throw HirdError.workspace }
            let path = String(row[row.index(after: tab)...])
            cursor = debug.index(after: zero)
            var lines: [Substring] = []
            for _ in 0..<5 {
                if let newline = debug[cursor...].firstIndex(of: "\n") {
                    lines.append(debug[cursor..<newline]); cursor = debug.index(after: newline)
                } else { lines.append(debug[cursor...]); cursor = debug.endIndex }
            }
            guard let head = expected[path] else { continue }
            guard String(row[..<tab]) == head, !verified.contains(path) else {
                throw diagnostic(root: root, stage: "capture", kind: "sensitive_metadata", failure: "sensitive_tracked_changed", policy: policy)
            }
            try HirdSecureFile.checkAncestors(tree.appendingPathComponent(path).deletingLastPathComponent())
            var status = stat()
            guard lstat(tree.appendingPathComponent(path).path, &status) == 0 else { throw HirdError.workspace }
            func fields(_ index: Int) -> [Substring] { lines[index].split { $0 == " " || $0 == "\t" || $0 == ":" } }
            let ctime = fields(0), mtime = fields(1), identity = fields(2), size = fields(4)
            guard ctime.count == 3, ctime[0] == "ctime", mtime.count == 3, mtime[0] == "mtime",
                  identity.count == 4, identity[0] == "dev", identity[2] == "ino", size.count == 4, size[0] == "size",
                  Int64(ctime[1]) == Int64(status.st_ctimespec.tv_sec), Int64(ctime[2]) == Int64(status.st_ctimespec.tv_nsec),
                  Int64(mtime[1]) == Int64(status.st_mtimespec.tv_sec), Int64(mtime[2]) == Int64(status.st_mtimespec.tv_nsec),
                  UInt32(identity[1]) == UInt32(truncatingIfNeeded: status.st_dev),
                  UInt32(identity[3]) == UInt32(truncatingIfNeeded: status.st_ino),
                  Int64(size[1]) == status.st_size else {
                throw diagnostic(root: root, stage: "capture", kind: "sensitive_metadata", failure: "sensitive_tracked_stale_stat", policy: policy)
            }
            verified.insert(path)
        }
        guard verified.count == expected.count else { throw HirdError.workspace }
        // Only the private index receives these bits. Git can now inspect ordinary
        // source changes without opening the protected worktree entries.
        try await runGit(["update-index", "--skip-worktree", "--"] + expected.keys.sorted(), at: tree,
            index: index, stage: stage, root: root, kind: "sensitive_exclusions", policy: policy)
    }
}
