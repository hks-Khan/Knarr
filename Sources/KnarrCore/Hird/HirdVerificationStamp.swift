import Foundation
import Darwin

extension HirdWorkspace {
    /// Reuse a content snapshot only while both its selected files and Git interpretation
    /// remain unchanged. This reads metadata and bounded Git inventories without rehashing source/evidence contents.
    /// Unsupported external filters/gitlinks fall back to full verification; completion always
    /// captures in full. The original user index is neither read for selection nor modified.
    static func verificationStamp(workspace: RunWorkspace, policy: HirdCapturePolicy) async throws -> [String: String] {
        let tree = URL(fileURLWithPath: workspace.worktreePath)
        let root = tree.deletingLastPathComponent()
        let stage = root.appendingPathComponent(".verification-stamp-" + UUID().uuidString)
        try HirdSecureFile.createDirectory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let tracked = Set(try await pathList(["ls-tree", "-r", "--name-only", "-z", "HEAD"],
            at: tree, stage: stage, root: root, policy: policy))
        // A nonexistent private index lets Git evaluate ignore rules independently of the
        // user's staging. Union with HEAD reproduces capture's read-tree HEAD selection.
        let visible = try await pathList(["ls-files", "--others", "--exclude-standard", "-z"], at: tree,
            index: stage.appendingPathComponent("empty-index"), stage: stage, root: root, policy: policy)
        let untracked = Set(visible.filter { !tracked.contains($0) && !policy.isSensitive($0) && !policy.isGenerated($0) && !policy.isEvidence($0) })
        let evidence = try evidenceSelection(at: tree, tracked: tracked, policy: policy).paths
        let selected = tracked.union(untracked).union(evidence)
        guard selected.count <= policy.maximumSelectedPaths else { throw HirdError.workspace }
        var result: [String: String] = [:]
        for path in selected {
            guard !policy.isSensitive(path) else { throw HirdError.workspace }
            let file = tree.appendingPathComponent(path)
            var status = stat()
            let exists = lstat(file.path, &status) == 0
            guard exists || (errno == ENOENT && tracked.contains(path)) else { throw HirdError.workspace }
            // Gitlinks and index-fallback attributes need full Git capture semantics.
            guard !exists || (status.st_mode & S_IFMT) != S_IFDIR,
                  exists || file.lastPathComponent != ".gitattributes" else { throw HirdError.workspace }
            let kind = tracked.contains(path) ? "tracked" : untracked.contains(path) ? "untracked" : "evidence"
            result[kind + "\0" + path] = exists ? try fileMetadata(file) : "missing"
        }
        let config = try await streamGit(["-c", "knarr.verification=1", "config", "--null", "--get-regexp", "^(knarr\\.verification|core\\.|filter\\.)"],
            at: tree, destination: stage.appendingPathComponent("config"), root: root, stage: "verification", kind: "config", policy: policy)
        guard config.byteCount <= policy.maximumMetadataBytes else { throw HirdError.workspace }
        result["\0config"] = config.sha256

        // Effective attributes include repository info/attributes and global attributes.
        // Bound argv bytes; large repositories use more batches without exceeding ARG_MAX.
        var batches: [[String]] = [], batch: [String] = [], bytes = 0
        for path in tracked.union(untracked).sorted() {
            let size = path.utf8.count + 8
            if bytes + size > 60_000 && !batch.isEmpty { batches.append(batch); batch = []; bytes = 0 }
            batch.append(path); bytes += size
        }
        if !batch.isEmpty { batches.append(batch) }
        for (index, paths) in batches.enumerated() {
            let output = stage.appendingPathComponent("attributes-\(index)")
            let attributes = try await streamGit(["check-attr", "-z", "--all", "--"] + paths,
                at: tree, index: stage.appendingPathComponent("empty-index"), destination: output, root: root, stage: "verification", kind: "attributes", policy: policy)
            guard attributes.byteCount <= policy.maximumMetadataBytes else { throw HirdError.workspace }
            let records = try nulRecords(output, maximumBytes: policy.maximumPathBytes, maximumCount: policy.maximumSelectedPaths * 64)
            guard records.count.isMultiple(of: 3) else { throw HirdError.workspace }
            for offset in stride(from: 0, to: records.count, by: 3) {
                // A filter may execute an independently changing program outside this tree.
                if records[offset + 1] == "filter" { throw HirdError.workspace }
            }
            result["\0attributes:\(index)"] = attributes.sha256
        }
        return result
    }
}
