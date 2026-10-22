import Foundation

/// Brings a confirmed Hird result into the original project: commit the judged change on the
/// Hird branch, then merge that branch into the project's current branch with a merge commit.
/// Anything unexpected leaves the original untouched and says why.
public enum ResultApplier {
    public enum Problem: Error, Sendable, Hashable {
        case missingResult
        case uncommittedChanges
        case detachedHead
        case changedSinceJudgement
        case conflict
        case gitFailed

        public var message: String {
            switch self {
            case .missingResult: "Hird 작업 폴더나 브랜치를 찾지 못했어요"
            case .uncommittedChanges: "원본에 커밋하지 않은 변경이 있어서 반영하지 않았어요. 정리한 뒤 다시 반영해 주세요"
            case .detachedHead: "원본이 브랜치가 아닌 특정 커밋에 있어서 반영하지 않았어요"
            case .changedSinceJudgement: "판정한 뒤 Hird 작업 폴더가 바뀌어서 반영하지 않았어요"
            case .conflict: "원본과 충돌이 나서 합치기를 취소했어요. 원본은 그대로예요"
            case .gitFailed: "git 명령이 실패해서 반영하지 않았어요"
            }
        }
    }

    public struct Applied: Sendable, Hashable {
        public let branch: String
        public let commit: String
    }


    /// Read-only inclusion check against committed HEAD, never the user's staged or working changes.
    public static func included(_ result: RunResult, application: ResultApplication?, in project: URL) async -> Applied? {
        guard let branch = try? await git(["symbolic-ref", "--short", "HEAD"], at: project) else { return nil }
        let commit: String?
        switch application {
        case .applied(_, let value), .kept(_, let value): commit = value
        default:
            if result.artifactManifestPath != nil || result.artifactManifestMetadata != nil {
                guard (try? HirdWorkspace.loadManifest(for: result)) != nil else { return nil }
            }
            if let patch = result.diffPath {
                let url = URL(fileURLWithPath: patch)
                guard let policy = try? HirdCapturePolicy.bundled(), url.pathExtension == "patch",
                      !policy.isSensitive(url.path), let fingerprint = try? HirdWorkspace.fingerprint(url) else { return nil }
                if fingerprint.byteCount > 0 {
                    return await includesPatch(url, branch: branch, in: project)
                }
            }
            commit = result.commit
        }
        guard let commit, !commit.isEmpty else { return nil }
        if (try? await git(["merge-base", "--is-ancestor", commit, "HEAD"], at: project)) != nil {
            return .init(branch: branch, commit: commit)
        }
        // A cherry-pick has a different SHA. Check the saved commit's actual patch
        // against HEAD without reading or changing the user's real index.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-inclusion-" + UUID().uuidString)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: directory) }
        let patch = directory.appendingPathComponent("commit.patch")
        guard let policy = try? HirdCapturePolicy.bundled(),
              let fingerprint = try? await HirdWorkspace.streamGit(
                ["show", "--format=", "--binary", "--no-ext-diff", "--no-textconv", commit, "--"],
                at: project, destination: patch, root: directory, stage: "inclusion", kind: "show", policy: policy),
              fingerprint.byteCount > 0 else { return nil }
        return await includesPatch(patch, branch: branch, in: project)
    }

    private static func includesPatch(_ patch: URL, branch: String, in project: URL) async -> Applied? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-inclusion-" + UUID().uuidString)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index")
        guard let policy = try? HirdCapturePolicy.bundled(),
              (try? await HirdWorkspace.git(["read-tree", "HEAD"], at: project, index: index)) != nil,
              (try? await HirdWorkspace.streamGit(["apply", "--reverse", "--check", "--cached", "--", patch.path],
                at: project, index: index, destination: directory.appendingPathComponent("reverse-check"),
                root: directory, stage: "inclusion", kind: "apply_reverse_check", policy: policy)) != nil,
              let head = try? await git(["rev-parse", "HEAD"], at: project) else { return nil }
        return .init(branch: branch, commit: head)
    }
    /// - Parameter merge: false commits on the Hird branch only and returns that branch; the original is not touched.
    public static func apply(_ result: RunResult, toProject project: URL, title: String, merge: Bool = true) async throws -> Applied {
        guard let branch = result.branch, !branch.isEmpty, let patchPath = result.diffPath,
              FileManager.default.fileExists(atPath: result.worktreePath) else { throw Problem.missingResult }
        let tree = URL(fileURLWithPath: result.worktreePath, isDirectory: true)

        var current = ""
        if merge {
            // The original must be on a branch with nothing uncommitted in tracked files.
            guard try await git(["status", "--porcelain", "--untracked-files=no"], at: project).isEmpty else { throw Problem.uncommittedChanges }
            guard let name = try? await git(["symbolic-ref", "--short", "HEAD"], at: project), !name.isEmpty else { throw Problem.detachedHead }
            current = name
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-apply-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index")
        let patch = directory.appendingPathComponent("current.patch")
        let policy: HirdCapturePolicy
        if result.artifactManifestPath != nil || result.artifactManifestMetadata != nil {
            do { policy = try HirdWorkspace.loadManifest(for: result).policy }
            catch { throw Problem.changedSinceJudgement }
        } else { policy = try HirdCapturePolicy.bundled() }
        let judgedURL = URL(fileURLWithPath: patchPath)
        guard judgedURL.pathExtension == "patch", !policy.isSensitive(judgedURL.path) else { throw Problem.changedSinceJudgement }
        let paths = try await HirdWorkspace.prepareCodeIndex(at: tree, index: index, root: directory, policy: policy)
        let now = try await HirdWorkspace.streamGit(
            ["diff", "--binary", "--cached", "--no-ext-diff", "--no-textconv", "HEAD", "--"],
            at: tree, index: index, destination: patch, root: directory, stage: "apply", kind: "diff", policy: policy)
        let judged = try HirdWorkspace.fingerprint(judgedURL)
        if now.byteCount == 0 {
            // A prior application committed the saved tail. A reverted tail is not that result.
            if judged.byteCount > 0 {
                guard await includesPatch(URL(fileURLWithPath: patchPath), branch: branch, in: tree) != nil else { throw Problem.changedSinceJudgement }
            }
            if !merge { return .init(branch: branch, commit: try await git(["rev-parse", "HEAD"], at: tree)) }
            if (try? await git(["merge-base", "--is-ancestor", branch, "HEAD"], at: project)) != nil {
                return .init(branch: current, commit: try await git(["rev-parse", "HEAD"], at: project))
            }
        } else {
            guard now == judged else { throw Problem.changedSinceJudgement }
            _ = try await HirdWorkspace.git(["-c", "user.name=Knarr Hird", "-c", "user.email=hird@knarr.local",
                "commit", "-q", "--no-verify", "-m", "Hird: " + title], at: tree, index: index)
            // Do not stage or reset unrelated cache/evidence entries in the worktree's real index.
            let pathspec = directory.appendingPathComponent("code-paths")
            FileManager.default.createFile(atPath: pathspec.path, contents: nil)
            let output = try FileHandle(forWritingTo: pathspec)
            do {
                for path in paths {
                    try output.write(contentsOf: Data(path.utf8))
                    try output.write(contentsOf: [UInt8(0)])
                }
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            if !paths.isEmpty {
                _ = try await git(["reset", "--quiet", "HEAD", "--pathspec-from-file=" + pathspec.path, "--pathspec-file-nul"], at: tree)
            }
        }
        if !merge { return .init(branch: branch, commit: try await git(["rev-parse", "HEAD"], at: tree)) }

        do {
            _ = try await git(["merge", "--no-ff", "--no-edit", "-m", "Knarr: " + title, branch], at: project)
        } catch {
            _ = try? await git(["merge", "--abort"], at: project)
            throw Problem.conflict
        }
        return .init(branch: current, commit: try await git(["rev-parse", "HEAD"], at: project))
    }

    private static func git(_ arguments: [String], at directory: URL) async throws -> String {
        do { return try await HirdWorkspace.git(arguments, at: directory) } catch { throw Problem.gitFailed }
    }
}
