import Foundation
import CryptoKit
import Darwin

/// Git metadata stays bounded; patches and artifacts are streamed into immutable run-owned files.
enum HirdWorkspace {
    static func prepare(project: URL, root: URL, previous: PersistedRun?, policy: HirdCapturePolicy? = nil) async throws -> (RunWorkspace, String) {
        let policy = try policy ?? HirdCapturePolicy.bundled()
        try policy.validate()
        do {
            try HirdSecureFile.checkAncestors(root)
            try HirdSecureFile.createDirectory(root)
            if let previous, let result = previous.result, result.commit == nil, result.diffPath == nil, previous.mode != .inspect {
                throw diagnostic(root: root, stage: "prepare", kind: "restore", failure: "missing_code_snapshot", policy: policy)
            }
            let branch = "knarr/hird/" + UUID().uuidString.lowercased()
            let tree = root.appendingPathComponent("worktree")
            let base: String
            if let commit = previous?.result?.commit { base = commit }
            else { base = try await git(["rev-parse", "HEAD"], at: project, policy: policy, diagnosticRoot: root, stage: "prepare") }
            let log = root.appendingPathComponent("prepare-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: log) }
            _ = try await streamGit(["worktree", "add", "-b", branch, tree.path, base], at: project,
                destination: log, root: root, stage: "prepare", kind: "worktree_add", policy: policy)
            if let result = previous?.result { try await restore(result: result, at: tree, policy: policy, diagnosticRoot: root) }
            return (.init(worktreePath: tree.path, branch: branch, ompSessionPath: root.appendingPathComponent("sessions").path), base)
        } catch let error as HirdError {
            if case .workspaceFailure = error { throw error }
            throw diagnostic(root: root, stage: "prepare", kind: "restore", failure: "storage_or_integrity", policy: policy)
        } catch { throw diagnostic(root: root, stage: "prepare", kind: "filesystem", failure: "storage", policy: policy) }
    }

    /// One snapshot attempt; a worktree that changes mid-capture is retried a bounded
    /// number of times before the attempt fails.
    static func capture(workspace: RunWorkspace, root: URL, base: String, verifications: [VerificationRecord], summary: String,
                        reportPath: String? = nil, policy: HirdCapturePolicy? = nil) async throws -> (RunResult, HirdCaptureSnapshot) {
        let policy = try policy ?? HirdCapturePolicy.bundled()
        try policy.validate()
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await captureAttempt(workspace: workspace, root: root, base: base, verifications: verifications,
                    summary: summary, reportPath: reportPath, policy: policy)
            } catch let HirdError.workspaceFailure(record) where record.commandKind == "source_stability" {
                guard attempt < policy.sourceStabilityAttempts, !Task.isCancelled else {
                    throw diagnostic(root: root, stage: "capture", kind: "source_stability", failure: "source_changed", policy: policy)
                }
                if policy.sourceStabilityRetryDelayMilliseconds > 0 {
                    try? await Task.sleep(for: .milliseconds(policy.sourceStabilityRetryDelayMilliseconds))
                }
            }
        }
    }

    private static func captureAttempt(workspace: RunWorkspace, root: URL, base: String, verifications: [VerificationRecord], summary: String,
                                       reportPath: String? = nil, policy: HirdCapturePolicy) async throws -> (RunResult, HirdCaptureSnapshot) {
        let tree = URL(fileURLWithPath: workspace.worktreePath)
        let stage = root.appendingPathComponent(".capture-" + UUID().uuidString)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedTree = tree.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedRoot != resolvedTree, !resolvedRoot.hasPrefix(resolvedTree + "/") else { throw HirdError.workspace }
        var failureKind = "selection"
        var failurePath: URL?
        do {
            try HirdSecureFile.checkAncestors(root)
            try HirdSecureFile.createDirectory(stage)
            defer { try? FileManager.default.removeItem(at: stage) }
            let index = stage.appendingPathComponent("index")
            let commit = try await git(["rev-parse", "HEAD"], at: tree, policy: policy, diagnosticRoot: root, stage: "capture")
            _ = try await prepareCodeIndex(at: tree, index: index, root: root, policy: policy)
            var files = try await sourceSnapshot(at: tree, index: index, base: base, stage: stage, root: root, policy: policy)
            failureKind = "code_patch"
            let patchTemporary = stage.appendingPathComponent("patch")
            let patchHash = try await streamGit(["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", commit, "--"], at: tree,
                index: index, destination: patchTemporary, root: root, stage: "capture", kind: "patch", policy: policy)
            guard patchHash.byteCount <= policy.maximumArtifactBytes else { throw HirdCaptureFailure.quota }
            let patch = root.appendingPathComponent("changes-" + patchHash.sha256 + ".patch")
            try publish(patchTemporary, as: patch, expected: patchHash, policy: policy)
            var artifacts: [HirdArtifact] = [.init(role: .patch, sourcePath: "changes.patch", blobPath: patch.lastPathComponent,
                sha256: patchHash.sha256, byteCount: patchHash.byteCount)]
            var total = patchHash.byteCount
            failureKind = "evidence_selection"
            let tracked = Set(try await pathList(["ls-files", "--cached", "-z"], at: tree, index: index, stage: stage, root: root, policy: policy))
            let selection = try evidenceSelection(at: tree, tracked: tracked, policy: policy)
            for kind in selection.skippedKinds {
                recordDiagnostic(.init(stage: "capture", commandKind: "evidence_selection", exitStatus: nil,
                    timedOut: false, outputLimitExceeded: false, pathReference: nil, failureKind: kind),
                    root: root, name: "evidence-skipped-" + kind)
            }
            let evidence = selection.paths
            var evidenceMetadata: [String: String] = [:]
            for path in evidence {
                guard artifacts.count < policy.maximumArtifactCount else { throw HirdCaptureFailure.quota }
                failureKind = "evidence_copy"
                failurePath = tree.appendingPathComponent(path)
                let sourceMetadata = try fileMetadata(tree.appendingPathComponent(path))
                let temporary = stage.appendingPathComponent(UUID().uuidString)
                let hash = try HirdSecureFile.transfer(tree.appendingPathComponent(path), to: temporary, limit: min(policy.maximumArtifactBytes, policy.maximumTotalArtifactBytes - total))
                total += hash.byteCount; guard total <= policy.maximumTotalArtifactBytes else { throw HirdCaptureFailure.quota }
                guard try fileMetadata(tree.appendingPathComponent(path)) == sourceMetadata else { throw HirdError.workspace }
                evidenceMetadata[path] = sourceMetadata
                let relative = "blobs/" + hash.sha256
                let blob = root.appendingPathComponent(relative)
                try HirdSecureFile.createDirectory(blob.deletingLastPathComponent())
                try publish(temporary, as: blob, expected: hash, policy: policy)
                artifacts.append(.init(role: .evidence, sourcePath: path, blobPath: relative, sha256: hash.sha256, byteCount: hash.byteCount))
                files[path] = "evidence:" + hash.sha256 + ":" + String(hash.byteCount)
            }
            failureKind = "run_evidence"
            failurePath = nil
            try appendRunEvidence(artifacts: &artifacts, root: root, stage: stage, verifications: verifications, reportPath: reportPath, policy: policy)
            try appendSessionArtifacts(artifacts: &artifacts, workspace: workspace, root: root, stage: stage, policy: policy)
            failureKind = "source_stability"
            try await protectSensitiveTracked(at: tree, index: index, stage: stage, root: root, policy: policy)
            try await runGit(["diff", "--quiet", "--no-ext-diff", "--no-textconv", "--"], at: tree, index: index, stage: stage,
                root: root, kind: "source_stability", policy: policy)
            let remaining = try await pathList(["ls-files", "--others", "--exclude-standard", "-z"], at: tree, index: index, stage: stage, root: root, policy: policy)
            guard !remaining.contains(where: { !policy.isSensitive($0) && !policy.isGenerated($0) && !policy.isEvidence($0) }),
                  try evidenceSelection(at: tree, tracked: tracked, policy: policy) == selection else { throw HirdError.workspace }
            for path in evidence { guard try fileMetadata(tree.appendingPathComponent(path)) == evidenceMetadata[path] else { throw HirdError.workspace } }
            guard try await git(["rev-parse", "HEAD"], at: tree, policy: policy, diagnosticRoot: root, stage: "capture") == commit else { throw HirdError.workspace }
            failureKind = "manifest"
            let (manifestURL, metadata) = try saveManifest(artifacts: artifacts, root: root, stage: stage, policy: policy)
            return (.init(worktreePath: tree.path, branch: workspace.branch, commit: commit, diffPath: patch.path,
                summary: summary, verifications: verifications, reportPath: reportPath, artifactManifestPath: manifestURL.path,
                artifactManifestMetadata: metadata), .init(files: files))
        } catch let error as HirdError {
            if case .workspaceFailure = error { throw error }
            throw diagnostic(root: root, stage: "capture", kind: failureKind, failure: "policy_storage_or_integrity", path: failurePath, policy: policy)
        } catch HirdCaptureFailure.quota {
            throw diagnostic(root: root, stage: "capture", kind: failureKind, failure: "artifact_quota", limit: true, path: failurePath, policy: policy)
        } catch { throw diagnostic(root: root, stage: "capture", kind: failureKind, failure: "storage", path: failurePath, policy: policy) }
    }

    /// Code/evidence identity at command completion, without publishing patches,
    /// copying session history, or creating a result manifest. Completion still archives
    /// everything and compares this identity before accepting the result.
    static func verificationSnapshot(workspace: RunWorkspace, root: URL, base: String,
                                     policy: HirdCapturePolicy) async throws -> HirdCaptureSnapshot {
        try policy.validate()
        let tree = URL(fileURLWithPath: workspace.worktreePath)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedTree = tree.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedRoot != resolvedTree, !resolvedRoot.hasPrefix(resolvedTree + "/") else { throw HirdError.workspace }
        let stage = root.appendingPathComponent(".verify-" + UUID().uuidString)
        try HirdSecureFile.createDirectory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let index = stage.appendingPathComponent("index")
        let commit = try await git(["rev-parse", "HEAD"], at: tree, policy: policy, diagnosticRoot: root, stage: "capture")
        _ = try await prepareCodeIndex(at: tree, index: index, root: root, policy: policy)
        var files = try await sourceSnapshot(at: tree, index: index, base: base, stage: stage, root: root, policy: policy)
        let tracked = Set(try await pathList(["ls-files", "--cached", "-z"], at: tree, index: index, stage: stage, root: root, policy: policy))
        let selection = try evidenceSelection(at: tree, tracked: tracked, policy: policy)
        var metadata: [String: String] = [:]
        for path in selection.paths {
            let file = tree.appendingPathComponent(path)
            metadata[path] = try fileMetadata(file)
            let hash = try HirdSecureFile.transfer(file, limit: policy.maximumArtifactBytes)
            files[path] = "evidence:" + hash.sha256 + ":" + String(hash.byteCount)
        }
        try await protectSensitiveTracked(at: tree, index: index, stage: stage, root: root, policy: policy)
        try await runGit(["diff", "--quiet", "--no-ext-diff", "--no-textconv", "--"], at: tree, index: index,
                         stage: stage, root: root, kind: "source_stability", policy: policy)
        let remaining = try await pathList(["ls-files", "--others", "--exclude-standard", "-z"], at: tree,
                                          index: index, stage: stage, root: root, policy: policy)
        guard !remaining.contains(where: { !policy.isSensitive($0) && !policy.isGenerated($0) && !policy.isEvidence($0) }),
              try evidenceSelection(at: tree, tracked: tracked, policy: policy) == selection,
              try await git(["rev-parse", "HEAD"], at: tree, policy: policy, diagnosticRoot: root, stage: "capture") == commit
        else { throw HirdError.workspace }
        for (path, before) in metadata {
            guard try fileMetadata(tree.appendingPathComponent(path)) == before else { throw HirdError.workspace }
        }
        return .init(files: files)
    }

    /// A fresh HEAD-based index: original index bytes and staged choices are never touched.
    @discardableResult static func prepareCodeIndex(at tree: URL, index: URL, root: URL, policy: HirdCapturePolicy? = nil) async throws -> [String] {
        let policy = try policy ?? HirdCapturePolicy.bundled()
        let stage = index.deletingLastPathComponent()
        try HirdSecureFile.checkAncestors(stage)
        try HirdSecureFile.createDirectory(stage)
        try await runGit(["read-tree", "HEAD"], at: tree, index: index, stage: stage, root: root, kind: "read_tree", policy: policy)
        try await protectSensitiveTracked(at: tree, index: index, stage: stage, root: root, policy: policy)
        let dirty = try await pathList(["diff", "--name-only", "-z", "--no-ext-diff", "--no-textconv", "HEAD", "--"], at: tree, index: index, stage: stage, root: root, policy: policy)
        let untracked = try await pathList(["ls-files", "--others", "--exclude-standard", "-z"], at: tree, index: index, stage: stage, root: root, policy: policy)
        guard !dirty.contains(where: policy.isSensitive) else {
            throw diagnostic(root: root, stage: "capture", kind: "selection", failure: "sensitive_tracked_path", policy: policy)
        }
        let paths = Array(Set(dirty + untracked.filter { !policy.isSensitive($0) && !policy.isGenerated($0) && !policy.isEvidence($0) })).sorted()
        guard paths.count <= policy.maximumSelectedPaths else { throw HirdError.workspace }
        var before: [String: String] = [:]
        for path in paths { before[path] = try fileState(tree.appendingPathComponent(path), policy: policy) }
        if !paths.isEmpty {
            let list = stage.appendingPathComponent("paths-" + UUID().uuidString)
            try writePaths(paths, to: list)
            try await runGit(["add", "--all", "--pathspec-from-file=" + list.path, "--pathspec-file-nul"], at: tree,
                index: index, stage: stage, root: root, kind: "stage_code", policy: policy)
        }
        for path in paths { guard before[path] == (try fileState(tree.appendingPathComponent(path), policy: policy)) else { throw HirdError.workspace } }
        return paths
    }

    static func fileMetadata(_ file: URL) throws -> String {
        var status = stat()
        guard lstat(file.path, &status) == 0 else { throw HirdError.workspace }
        return "\(status.st_dev):\(status.st_ino):\(status.st_size):\(status.st_mode):\(status.st_mtimespec.tv_sec):\(status.st_mtimespec.tv_nsec):\(status.st_ctimespec.tv_sec):\(status.st_ctimespec.tv_nsec)"
    }

    static func fingerprint(_ file: URL) throws -> HirdFileFingerprint {
        try HirdSecureFile.transfer(file, limit: .max)
    }

    static func fileState(_ file: URL, policy: HirdCapturePolicy) throws -> String {
        try HirdSecureFile.checkAncestors(file.deletingLastPathComponent())
        var status = stat()
        if lstat(file.path, &status) != 0 {
            guard errno == ENOENT else { throw HirdError.workspace }; return "deleted"
        }
        if (status.st_mode & S_IFMT) == S_IFLNK {
            let parent = try HirdSecureFile.openDirectory(file.deletingLastPathComponent())
            defer { _ = Darwin.close(parent) }
            var target = [UInt8](repeating: 0, count: policy.maximumPathBytes)
            let count = readlinkat(parent, file.lastPathComponent, &target, target.count)
            guard count >= 0, count < target.count else { throw HirdError.workspace }
            var after = stat()
            guard fstatat(parent, file.lastPathComponent, &after, AT_SYMLINK_NOFOLLOW) == 0,
                  status.st_ino == after.st_ino, status.st_size == after.st_size,
                  status.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  status.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw HirdError.workspace }
            var hash = SHA256()
            target.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            return "link:" + HirdSecureFile.hex(hash.finalize())
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw HirdError.workspace }
        let hash = try HirdSecureFile.transfer(file, limit: policy.maximumArtifactBytes)
        return hash.sha256 + ":" + String(hash.byteCount) + ":" + String(status.st_mode & 0o111)
    }

    static func publish(_ temporary: URL, as destination: URL, expected: HirdFileFingerprint, policy: HirdCapturePolicy) throws {
        let sourceParent = try HirdSecureFile.openDirectory(temporary.deletingLastPathComponent())
        defer { _ = Darwin.close(sourceParent) }
        let destinationParent = try HirdSecureFile.openDirectory(destination.deletingLastPathComponent())
        defer { _ = Darwin.close(destinationParent) }
        if linkat(sourceParent, temporary.lastPathComponent, destinationParent, destination.lastPathComponent, 0) != 0 {
            guard errno == EEXIST, try HirdSecureFile.transfer(destination, limit: max(policy.maximumArtifactBytes, policy.maximumManifestBytes)) == expected else { throw HirdError.workspace }
        }
    }

    static func runGit(_ arguments: [String], at tree: URL, index: URL? = nil, stage: URL, root: URL, kind: String, policy: HirdCapturePolicy, operationStage: String = "capture") async throws {
        let output = stage.appendingPathComponent(UUID().uuidString)
        _ = try await streamGit(arguments, at: tree, index: index, destination: output, root: root, stage: operationStage, kind: kind, policy: policy)
    }

    static func writePaths(_ paths: [String], to file: URL) throws {
        let output = try HirdSecureFile.createFile(file); defer { try? output.close() }
        for path in paths { try output.write(contentsOf: Data(path.utf8)); try output.write(contentsOf: Data([0])) }
    }

    static func pathList(_ arguments: [String], at tree: URL, index: URL? = nil, stage: URL, root: URL, policy: HirdCapturePolicy) async throws -> [String] {
        let output = stage.appendingPathComponent(UUID().uuidString)
        _ = try await streamGit(arguments, at: tree, index: index, destination: output, root: root, stage: "capture", kind: "path_selection", policy: policy)
        let paths = try nulRecords(output, maximumBytes: policy.maximumPathBytes, maximumCount: policy.maximumSelectedPaths)
        guard paths.allSatisfy(HirdSecureFile.isRelative) else { throw HirdError.workspace }
        return paths
    }

    static func nulRecords(_ file: URL, maximumBytes: Int, maximumCount: Int) throws -> [String] {
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        var pending = Data(), paths: [String] = []
        while let bytes = try input.read(upToCount: 65_536), !bytes.isEmpty {
            for byte in bytes {
                if byte == 0 {
                    guard let path = String(data: pending, encoding: .utf8), paths.count < maximumCount else { throw HirdError.workspace }
                    paths.append(path); pending.removeAll(keepingCapacity: true)
                } else {
                    guard pending.count < maximumBytes else { throw HirdError.workspace }; pending.append(byte)
                }
            }
        }
        guard pending.isEmpty else { throw HirdError.workspace }
        return paths
    }

    static func sourceSnapshot(at tree: URL, index: URL, base: String, stage: URL, root: URL, policy: HirdCapturePolicy) async throws -> [String: String] {
        let output = stage.appendingPathComponent(UUID().uuidString)
        _ = try await streamGit(["diff", "--cached", "--raw", "--no-renames", "--no-abbrev", "-z", "--no-ext-diff", "--no-textconv", base, "--"], at: tree,
            index: index, destination: output, root: root, stage: "capture", kind: "source_digest", policy: policy)
        let records = try nulRecords(output, maximumBytes: max(policy.maximumPathBytes, 256), maximumCount: policy.maximumSelectedPaths)
        guard records.count.isMultiple(of: 2) else { throw HirdError.workspace }
        var result: [String: String] = [:]
        for offset in stride(from: 0, to: records.count, by: 2) {
            let header = records[offset].split(separator: " ")
            let path = records[offset + 1]
            guard header.count == 5, HirdSecureFile.isRelative(path), !policy.isSensitive(path) else { throw HirdError.workspace }
            result[path] = String(header[1]) + ":" + String(header[3])
        }
        return result
    }

    /// Symlinks and special files inside evidence roots are skipped, never followed or
    /// opened. Only their fixed kind is reported, so a link cannot leak its target.
    static func evidenceSelection(at tree: URL, tracked: Set<String>, policy: HirdCapturePolicy) throws -> HirdEvidenceSelection {
        var paths: [String] = [], skipped: [String] = [], visited = 0, pending = policy.evidenceRoots
        let nameOffset = MemoryLayout<dirent>.offset(of: \.d_name)!
        while let relative = pending.popLast() {
            let url = tree.appendingPathComponent(relative)
            var status = stat()
            if lstat(url.path, &status) != 0 { guard errno == ENOENT else { throw HirdError.workspace }; continue }
            guard (status.st_mode & S_IFMT) == S_IFDIR else { skipped.append(skipKind(status.st_mode)); continue }
            let fd = try HirdSecureFile.openDirectory(url)
            guard let directory = fdopendir(fd) else { _ = Darwin.close(fd); throw HirdError.workspace }
            defer { closedir(directory) }
            while true {
                errno = 0
                guard let entry = readdir(directory) else { guard errno == 0 else { throw HirdError.workspace }; break }
                let bytes = UnsafeRawPointer(entry).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
                guard let name = String(validatingCString: bytes) else { throw HirdError.workspace }
                if name == "." || name == ".." { continue }
                visited += 1; guard visited <= policy.maximumSelectedPaths else { throw HirdCaptureFailure.quota }
                let path = relative + "/" + name
                guard path.utf8.count <= policy.maximumPathBytes, HirdSecureFile.isRelative(path) else { throw HirdError.workspace }
                if policy.isSensitive(path) { continue }
                guard fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw HirdError.workspace }
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    if !policy.isGenerated(path + "/entry") { pending.append(path) }
                case S_IFREG:
                    if !tracked.contains(path) { paths.append(path) }
                default:
                    skipped.append(skipKind(status.st_mode))
                }
            }
        }
        return .init(paths: Array(Set(paths)).sorted(), skippedKinds: skipped.sorted())
    }

    private static func skipKind(_ mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFLNK: "symlink"
        case S_IFIFO: "fifo"
        case S_IFSOCK: "socket"
        case S_IFCHR: "character"
        case S_IFBLK: "block"
        default: "special"
        }
    }
}

public enum HirdError: Error, Sendable, Equatable {
    case workspace, staleRun, conflictingDelivery, modelMismatch, thinkingMismatch, cleanup
    case workspaceFailure(HirdWorkspaceDiagnostic)
    case transportTerminated
    case promptNotCompleted(String)
    case noVerification, unfinishedVerification, noChanges, changedAfterVerification, inspectionModified, inspectionTools, noReport
    case instructions
    case verificationRetriesExhausted(String)
    case continuationRetriesExhausted(Int, String)
    public var reason: String {
        switch self {
        case .workspace: "Hird 작업 사본(Git worktree)을 준비하지 못했어요"
        case .workspaceFailure(let detail): "[workspace_failed] stage=\(detail.stage) command=\(detail.commandKind) exit=\(detail.exitStatus.map(String.init) ?? "none") timeout=\(detail.timedOut) limit=\(detail.outputLimitExceeded) kind=\(detail.failureKind)"
        case .transportTerminated: "[transport_terminated] OMP 연결이 종료되어 응답 완료 여부를 확인하지 못했어요"
        case .staleRun: "이미 끝났거나 다른 실행으로 바뀐 작업이라 결과를 받지 않았어요"
        case .conflictingDelivery: "같은 질문에 서로 다른 답이 전달돼 실행을 멈췄어요"
        case .modelMismatch: "OMP에서 확인한 Hird 모델이 이 실행의 요청 모델과 달라요"
        case .thinkingMismatch: "[thinking_mismatch] OMP에서 확인한 Hird 추론 수준이 요청한 off와 달라요"
        case .inspectionTools: "[inspection_tools] 조사 실행의 읽기 전용 도구 제한을 확인하지 못했어요"
        case .noReport: "[missing_report] 조사 근거를 설명할 최종 보고서가 없어요"
        case .instructions: "[instructions] 사용자 지침 파일을 읽지 못해 실행을 시작하지 않았어요. 설정에서 지침 파일을 확인해 주세요."
        case .cleanup: "Hird 실행이 만든 프로세스를 모두 정리하지 못했어요"
        case .promptNotCompleted(let status): "[prompt_\(status)] OMP가 Hird 응답을 완료하지 못하고 끝냈어요 (status=\(status))"
        case .noVerification: "Hird가 명령 결과나 문서·화면 확인 근거를 남기지 않았어요"
        case .unfinishedVerification: "마지막 검증 명령이 시간 초과나 백그라운드 실행으로 끝나 종료 코드가 없어요"
        case .noChanges: "검증은 실행했지만 요청한 코드 변경이 없어요"
        case .inspectionModified: "[inspection_modified] 읽기 전용 조사에서 소스 변경이 발견됐어요. 변경은 작업본에 보존했어요."
        case .changedAfterVerification: "마지막 검증 뒤에 파일이 다시 바뀌어 검증 결과로 인정하지 않았어요"
        case .verificationRetriesExhausted(let reason): "검증 보정 재요청 상한 2회를 넘겼어요. " + reason
        case .continuationRetriesExhausted(let limit, let reason): "[continuation_exhausted] 자동 이어 가기 상한 \(limit)회를 넘겼어요. " + reason
        }
    }
}
