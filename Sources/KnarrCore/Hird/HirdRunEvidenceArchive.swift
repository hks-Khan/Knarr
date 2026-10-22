import Foundation

extension HirdWorkspace {
    /// Independent of Git/worktree readability, so a failed capture never drops the
    /// latest checks or report. Existing code/evidence blobs remain immutable.
    static func preserveRunEvidence(previous: RunResult?, workspace: RunWorkspace, root: URL,
                                    verifications: [VerificationRecord], summary: String, reportPath: String?,
                                    policy: HirdCapturePolicy? = nil) throws -> RunResult {
        let policy = try policy ?? HirdCapturePolicy.bundled()
        let stage = root.appendingPathComponent(".archive-" + UUID().uuidString)
        do {
            try HirdSecureFile.checkAncestors(root)
            try HirdSecureFile.createDirectory(stage)
            defer { try? FileManager.default.removeItem(at: stage) }
            var artifacts: [HirdArtifact] = []
            var diffPath = previous?.diffPath
            if let previous, let path = previous.artifactManifestPath {
                let manifest = try loadManifest(for: previous)
                let manifestURL = URL(fileURLWithPath: path)
                for artifact in manifest.artifacts {
                    let source = manifestURL.deletingLastPathComponent().appendingPathComponent(artifact.blobPath)
                    let destination = root.appendingPathComponent(artifact.blobPath)
                    if source.standardizedFileURL != destination.standardizedFileURL {
                        try HirdSecureFile.createDirectory(destination.deletingLastPathComponent())
                        let temporary = stage.appendingPathComponent(UUID().uuidString)
                        let hash = try HirdSecureFile.transfer(source, to: temporary, limit: policy.maximumArtifactBytes)
                        guard hash.sha256 == artifact.sha256, hash.byteCount == artifact.byteCount else { throw HirdError.workspace }
                        try publish(temporary, as: destination, expected: hash, policy: policy)
                    }
                    if artifact.role == .patch { diffPath = destination.path }
                    artifacts.append(artifact)
                }
            } else if let path = previous?.diffPath {
                let source = URL(fileURLWithPath: path), temporary = stage.appendingPathComponent("legacy-patch")
                guard source.pathExtension == "patch", !policy.isSensitive(source.path) else { throw HirdError.workspace }
                let hash = try HirdSecureFile.transfer(source, to: temporary, limit: policy.maximumArtifactBytes)
                let destination = root.appendingPathComponent("changes-" + hash.sha256 + ".patch")
                try publish(temporary, as: destination, expected: hash, policy: policy)
                diffPath = destination.path
                artifacts.append(.init(role: .patch, sourcePath: "changes.patch", blobPath: destination.lastPathComponent, sha256: hash.sha256, byteCount: hash.byteCount))
            }
            try appendSessionArtifacts(artifacts: &artifacts, workspace: workspace, root: root, stage: stage, policy: policy)
            try appendRunEvidence(artifacts: &artifacts, root: root, stage: stage, verifications: verifications, reportPath: reportPath, policy: policy)
            let (manifestURL, metadata) = try saveManifest(artifacts: artifacts, root: root, stage: stage, policy: policy)
            return .init(worktreePath: workspace.worktreePath, branch: workspace.branch, commit: previous?.commit, diffPath: diffPath,
                summary: summary, verifications: verifications, reportPath: reportPath,
                artifactManifestPath: manifestURL.path, artifactManifestMetadata: metadata)
        } catch let error as HirdError {
            if case .workspaceFailure = error { throw error }
            throw diagnostic(root: root, stage: "archive", kind: "run_evidence", failure: "policy_storage_or_integrity", policy: policy)
        } catch HirdCaptureFailure.quota {
            throw diagnostic(root: root, stage: "archive", kind: "run_evidence", failure: "artifact_quota", limit: true, policy: policy)
        } catch { throw diagnostic(root: root, stage: "archive", kind: "run_evidence", failure: "storage", policy: policy) }
    }

    static func appendRunEvidence(artifacts: inout [HirdArtifact], root: URL, stage: URL,
                                  verifications: [VerificationRecord], reportPath: String?, policy: HirdCapturePolicy) throws {
        var references = verifications.map { ($0.logPath, HirdArtifactRole.verification) }
        for verification in verifications {
            references.append(contentsOf: (verification.attachmentPaths ?? []).map { ($0, .verification) })
        }
        if let reportPath { references.append((reportPath, .report)) }
        let prefix = root.standardizedFileURL.path + "/"
        for (path, role) in references {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path.hasPrefix(prefix) else { throw HirdError.workspace }
            let relative = String(url.path.dropFirst(prefix.count))
            guard HirdSecureFile.isRelative(relative), !policy.isSensitive(relative) else { throw HirdError.workspace }
            if let existing = artifacts.first(where: { $0.role == role && $0.sourcePath == relative }) {
                let current = try HirdSecureFile.transfer(url, limit: policy.maximumArtifactBytes)
                guard current.sha256 == existing.sha256, current.byteCount == existing.byteCount else { throw HirdError.workspace }
                continue
            }
            let temporary = stage.appendingPathComponent(UUID().uuidString)
            let total = try artifactBytes(artifacts, policy: policy)
            guard artifacts.count < policy.maximumArtifactCount else { throw HirdCaptureFailure.quota }
            let hash = try HirdSecureFile.transfer(url, to: temporary, limit: min(policy.maximumArtifactBytes, policy.maximumTotalArtifactBytes - total))
            let blobPath = "blobs/" + hash.sha256
            let blob = root.appendingPathComponent(blobPath)
            try HirdSecureFile.createDirectory(blob.deletingLastPathComponent())
            try publish(temporary, as: blob, expected: hash, policy: policy)
            artifacts.append(.init(role: role, sourcePath: relative, blobPath: blobPath, sha256: hash.sha256, byteCount: hash.byteCount))
        }
    }

    static func artifactBytes(_ artifacts: [HirdArtifact], policy: HirdCapturePolicy) throws -> Int64 {
        var total: Int64 = 0
        guard artifacts.count <= policy.maximumArtifactCount else { throw HirdCaptureFailure.quota }
        for artifact in artifacts {
            guard artifact.byteCount >= 0, artifact.byteCount <= policy.maximumArtifactBytes,
                  artifact.byteCount <= policy.maximumTotalArtifactBytes - total else { throw HirdCaptureFailure.quota }
            total += artifact.byteCount
        }
        return total
    }

    static func saveManifest(artifacts: [HirdArtifact], root: URL, stage: URL, policy: HirdCapturePolicy) throws -> (URL, HirdArtifactManifestMetadata) {
        let total = try artifactBytes(artifacts, policy: policy)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(HirdArtifactManifest(artifacts: artifacts, policy: policy))
        guard Int64(bytes.count) <= policy.maximumManifestBytes else { throw HirdCaptureFailure.quota }
        let temporary = stage.appendingPathComponent("manifest-" + UUID().uuidString)
        try HirdSecureFile.write(bytes, to: temporary)
        let hash = try fingerprint(temporary)
        let url = root.appendingPathComponent("artifacts-" + hash.sha256 + ".json")
        try publish(temporary, as: url, expected: hash, policy: policy)
        return (url, .init(sha256: hash.sha256, artifactCount: artifacts.count, totalBytes: total))
    }
}
