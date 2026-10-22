import Foundation
import CryptoKit
import Darwin

extension HirdWorkspace {
    static func loadManifest(for result: RunResult) throws -> HirdArtifactManifest {
        guard let path = result.artifactManifestPath, let metadata = result.artifactManifestMetadata else { throw HirdError.workspace }
        let url = URL(fileURLWithPath: path)
        let defaults = try HirdCapturePolicy.bundled()
        guard url.lastPathComponent == "artifacts-" + metadata.sha256 + ".json", !defaults.isSensitive(url.path) else { throw HirdError.workspace }
        let bytes = try HirdSecureFile.read(url, limit: defaults.maximumManifestBytes)
        guard HirdSecureFile.hex(SHA256.hash(data: bytes)) == metadata.sha256 else { throw HirdError.workspace }
        let manifest = try JSONDecoder().decode(HirdArtifactManifest.self, from: bytes)
        try manifest.policy.validate()
        guard manifest.artifacts.count <= manifest.policy.maximumArtifactCount,
              manifest.artifacts.filter({ $0.role == .patch }).count == (result.diffPath == nil ? 0 : 1),
              Set(manifest.artifacts.map { $0.role.rawValue + ":" + $0.sourcePath }).count == manifest.artifacts.count else { throw HirdError.workspace }
        var total: Int64 = 0
        for artifact in manifest.artifacts {
            guard HirdSecureFile.isRelative(artifact.sourcePath), HirdSecureFile.isRelative(artifact.blobPath),
                  artifact.role == .sessionArtifact || artifact.captureKind == nil,
                  artifact.sha256.count == SHA256.byteCount * 2,
                  artifact.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  artifact.byteCount >= 0, artifact.byteCount <= manifest.policy.maximumArtifactBytes,
                  artifact.byteCount <= manifest.policy.maximumTotalArtifactBytes - total else { throw HirdError.workspace }
            total += artifact.byteCount
            switch artifact.role {
            case .patch:
                guard artifact.sourcePath == "changes.patch", artifact.blobPath == "changes-" + artifact.sha256 + ".patch",
                      result.diffPath == url.deletingLastPathComponent().appendingPathComponent(artifact.blobPath).path else { throw HirdError.workspace }
            case .evidence:
                guard manifest.policy.isEvidence(artifact.sourcePath), !manifest.policy.isSensitive(artifact.sourcePath),
                      artifact.blobPath == "blobs/" + artifact.sha256 else { throw HirdError.workspace }
            case .verification, .report:
                guard !manifest.policy.isSensitive(artifact.sourcePath), artifact.blobPath == "blobs/" + artifact.sha256 else { throw HirdError.workspace }
            case .sessionArtifact:
                try validateSessionArtifact(artifact, policy: manifest.policy)
            }
        }
        guard metadata.artifactCount == manifest.artifacts.count, metadata.totalBytes == total else { throw HirdError.workspace }
        for artifact in manifest.artifacts { try verifyArtifact(artifact, manifestURL: url, policy: manifest.policy) }
        return manifest
    }

    static func verifyArtifact(_ artifact: HirdArtifact, manifestURL: URL, policy: HirdCapturePolicy? = nil) throws {
        let policy = try policy ?? HirdCapturePolicy.bundled()
        let expected = artifact.role == .patch ? "changes-" + artifact.sha256 + ".patch" : "blobs/" + artifact.sha256
        guard HirdSecureFile.isRelative(artifact.blobPath), artifact.blobPath == expected,
              !policy.isSensitive(manifestURL.path), artifact.byteCount >= 0 else { throw HirdError.workspace }
        let file = manifestURL.deletingLastPathComponent().appendingPathComponent(artifact.blobPath)
        let actual = try HirdSecureFile.transfer(file, limit: artifact.byteCount)
        guard actual.sha256 == artifact.sha256, actual.byteCount == artifact.byteCount else { throw HirdError.workspace }
    }

    static func restore(result: RunResult, at tree: URL, policy: HirdCapturePolicy? = nil, diagnosticRoot: URL? = nil) async throws {
        let policy = try policy ?? HirdCapturePolicy.bundled()
        let root = diagnosticRoot ?? URL(fileURLWithPath: result.artifactManifestPath ?? result.diffPath ?? tree.deletingLastPathComponent().appendingPathComponent("restore").path).deletingLastPathComponent()
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("hird-restore-" + UUID().uuidString)
        do {
            try HirdSecureFile.createDirectory(stage)
            defer { try? FileManager.default.removeItem(at: stage) }
            var artifacts: [HirdArtifact] = []
            var manifestURL: URL?
            var artifactPolicy = policy
            if let path = result.artifactManifestPath {
                manifestURL = URL(fileURLWithPath: path)
                let manifest = try loadManifest(for: result)
                artifacts = manifest.artifacts; artifactPolicy = manifest.policy
                try validateSessionArtifactTargets(artifacts: artifacts, manifestURL: URL(fileURLWithPath: path),
                    destinationRoot: tree.deletingLastPathComponent(), policy: artifactPolicy)
            }
            // A named legacy patch must exist, even when it is empty. Missing is not a clean result.
            if let path = result.diffPath {
                let patch = URL(fileURLWithPath: path)
                guard patch.pathExtension == "patch", !policy.isSensitive(patch.path) else { throw HirdError.workspace }
                let stagedPatch = stage.appendingPathComponent("verified.patch")
                let hash = try HirdSecureFile.transfer(patch, to: stagedPatch, limit: artifactPolicy.maximumArtifactBytes)
                if let recorded = artifacts.first(where: { $0.role == .patch }) {
                    guard hash.sha256 == recorded.sha256, hash.byteCount == recorded.byteCount else { throw HirdError.workspace }
                }
                if hash.byteCount > 0 {
                    // Validate all destinations before applying anything; git itself rejects unsafe patch paths.
                    try await runGit(["apply", "--check", "--binary", stagedPatch.path], at: tree, stage: stage, root: root, kind: "restore_patch_check", policy: policy, operationStage: "prepare")
                }
                for artifact in artifacts where artifact.role == .evidence {
                    try HirdSecureFile.checkAncestors(tree.appendingPathComponent(artifact.sourcePath).deletingLastPathComponent())
                }
                if hash.byteCount > 0 {
                    try await runGit(["apply", "--binary", stagedPatch.path], at: tree, stage: stage, root: root, kind: "restore_patch", policy: policy, operationStage: "prepare")
                }
            }
            if let manifestURL {
                for artifact in artifacts where artifact.role == .evidence {
                    let blob = manifestURL.deletingLastPathComponent().appendingPathComponent(artifact.blobPath)
                    try restoreEvidence(blob: blob, artifact: artifact, tree: tree, policy: artifactPolicy)
                }
                try restoreSessionArtifacts(artifacts: artifacts, manifestURL: manifestURL,
                    destinationRoot: tree.deletingLastPathComponent(), policy: artifactPolicy)
            }
        } catch let error as HirdError {
            if case .workspaceFailure = error { throw error }
            throw diagnostic(root: root, stage: "prepare", kind: "restore", failure: "missing_or_unsafe_artifact", policy: policy)
        } catch { throw diagnostic(root: root, stage: "prepare", kind: "restore", failure: "storage", policy: policy) }
    }

    private static func restoreEvidence(blob: URL, artifact: HirdArtifact, tree: URL, policy: HirdCapturePolicy) throws {
        guard HirdSecureFile.isRelative(artifact.sourcePath), policy.isEvidence(artifact.sourcePath), !policy.isSensitive(artifact.sourcePath) else { throw HirdError.workspace }
        let components = artifact.sourcePath.split(separator: "/")
        var parent = try HirdSecureFile.openDirectory(tree)
        defer { _ = Darwin.close(parent) }
        for component in components.dropLast() {
            if mkdirat(parent, String(component), S_IRWXU) != 0, errno != EEXIST { throw HirdError.workspace }
            let next = openat(parent, String(component), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw HirdError.workspace }
            _ = Darwin.close(parent); parent = next
        }
        let name = String(components.last!)
        let temporary = ".hird-restore-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw HirdError.workspace }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close(); _ = unlinkat(parent, temporary, 0) }
        let source = try HirdSecureFile.openRead(root: blob.deletingLastPathComponent(), path: blob.lastPathComponent)
        defer { _ = Darwin.close(source) }
        var hash = SHA256(), total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw HirdError.workspace }
            if count == 0 { break }
            total += Int64(count); guard total <= artifact.byteCount else { throw HirdError.workspace }
            try buffer.withUnsafeBytes { raw in
                let bytes = UnsafeRawBufferPointer(rebasing: raw[..<count])
                hash.update(bufferPointer: bytes)
                var offset = 0
                while offset < count {
                    let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw HirdError.workspace }
                    offset += written
                }
            }
        }
        guard total == artifact.byteCount, HirdSecureFile.hex(hash.finalize()) == artifact.sha256 else { throw HirdError.workspace }
        try output.synchronize()
        if linkat(parent, temporary, parent, name, 0) != 0 {
            guard errno == EEXIST else { throw HirdError.workspace }
            let existing = tree.appendingPathComponent(artifact.sourcePath)
            guard try HirdSecureFile.transfer(existing, limit: artifact.byteCount) == HirdFileFingerprint(sha256: artifact.sha256, byteCount: artifact.byteCount) else { throw HirdError.workspace }
        }
    }
}
