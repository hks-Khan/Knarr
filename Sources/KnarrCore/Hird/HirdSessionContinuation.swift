import Foundation

/// Fork the bound journal and numeric tool payloads; never copy child journals.
struct HirdSessionContinuation {
    let arguments: [String]
    let header: String

    static func prepare(previous: PersistedRun?, workspace: RunWorkspace, model: String, capturePolicy: HirdCapturePolicy) async throws -> Self {
        guard let previous else { return .init(arguments: [], header: "") }
        guard let sessionPath = workspace.ompSessionPath else { throw HirdError.workspace }
        let destination = URL(fileURLWithPath: sessionPath)
        let copied: URL?
        do { copied = try copySession(previous: previous, destination: destination, cwd: workspace.worktreePath, policy: capturePolicy) }
        catch {
            if let failure = error as? HirdError, case .workspaceFailure = failure { throw failure }
            let quota = error is HirdCaptureFailure
            throw HirdWorkspace.diagnostic(root: destination.deletingLastPathComponent(), stage: "prepare",
                kind: "session_artifacts", failure: quota ? "artifact_quota" : "storage_or_integrity",
                limit: quota, policy: capturePolicy)
        }
        let priorPath = previous.workspace?.worktreePath ?? previous.result?.worktreePath ?? "unknown"
        let unmet = (previous.acceptanceEvidence ?? []).filter { $0.state != .met }
        var parts = ["""
            # Hird 실행 인계
            이전 실행: \(previous.id.rawValue) (mode: \(previous.mode?.rawValue ?? "change"))
            작업 사본 경로 변경: \(priorPath) → \(workspace.worktreePath)
            이전 작업 사본 경로는 더 이상 쓰지 말 것. 작업 사본 안의 절대 경로만 새 작업 사본 기준으로 해석한다. 검증 로그·보고서·manifest의 실행 소유 원본 참조는 그대로 유지한다.
            도구와 정책은 이번 실행 모드의 overlay와 아래 지시만 따른다. 이전 모드의 권한은 이어받지 않는다.
            이전 실행 상태: \(previous.state.rawValue)
            실패·중단 사유: \(previous.stopReason ?? "저장된 사유 없음")
            ## 이전 판정의 미충족 조건과 사유
            """]
        if unmet.isEmpty {
            parts.append(previous.acceptanceEvidence == nil ? "이전 판정 근거가 저장되지 않았음. 아래 결과와 이번 완료 조건을 기준으로 확인한다." : "저장된 미충족 조건 없음.")
        } else {
            parts += unmet.map { "- \($0.text): \($0.evidence.isEmpty ? "판정 근거 없음" : $0.evidence)" }
        }
        if let manifest = previous.result?.artifactManifestPath {
            parts.append("이전 검증 artifact manifest: \(manifest). 코드 patch와 필요한 작업 사본 evidence를 복원했으며, 이전 검증의 exit code는 그대로 보존한다.")
        }
        if copied == nil { parts.append(await fallback(previous, workspace: workspace)) }
        else { parts.append("이전 OMP 대화와 숫자 artifact:// 도구 출력의 관측 접두사를 복사한 세션에서 이어받는다. 이 payload는 완료가 확인된 전체 출력이라는 뜻이 아니다. 원본은 보존한다. 하위 에이전트 대화·보고서는 복사하지 않았으므로 이전 agent://·history:// 참조를 이번 세션의 같은 ID로 해석할 수 없다. 필요한 검증 근거는 보존 manifest와 이전 결과를 사용한다.") }
        parts.append("## 이번 지시\n")
        // CLI model selection bypasses restoration of an old, potentially unavailable model.
        // The adapter still verifies the observed model against this run's request.
        return .init(arguments: copied.map { ["--resume", $0.path, "--model", model] } ?? [], header: parts.joined(separator: "\n") + "\n")
    }

    private static func copySession(previous: PersistedRun, destination: URL, cwd: String, policy: HirdCapturePolicy) throws -> URL? {
        guard let path = previous.workspace?.ompSessionPath else { return nil }
        let source = URL(fileURLWithPath: path)
        guard !policy.isSensitive(source.path) else { throw HirdError.workspace }
        try HirdSecureFile.checkAncestors(source)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let candidates: [URL]
        if isDirectory.boolValue {
            guard let files = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return nil }
            candidates = files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        } else { candidates = [source] }
        for file in candidates {
            guard !policy.isSensitive(file.path), FileManager.default.isReadableFile(atPath: file.path),
                  var bytes = try? HirdSecureFile.read(file, limit: policy.maximumArtifactBytes),
                  let (range, originalHeader) = sessionHeader(in: bytes),
                  let id = originalHeader["id"] as? String, !id.isEmpty,
                  previous.ompSessionID == nil || previous.ompSessionID == id else { continue }
            // --resume follows a still-accessible recorded cwd, even when the process launches elsewhere.
            // Rewrite only the COPY's header; preserve every conversation entry byte for byte.
            var header = originalHeader
            header["cwd"] = cwd
            header.removeValue(forKey: "additionalDirectories")
            bytes.replaceSubrange(range, with: try JSONSerialization.data(withJSONObject: header, options: .sortedKeys))
            let copy = destination.appendingPathComponent(file.lastPathComponent)
            try HirdWorkspace.copySessionArtifacts(sourceJournal: file, destinationJournal: copy, policy: policy)
            try bytes.write(to: copy, options: .withoutOverwriting)
            return copy
        }
        return nil
    }

    /// v3 may have a fixed-width title slot before the header. No transcript parsing is needed.
    private static func sessionHeader(in bytes: Data) -> (Range<Data.Index>, [String: Any])? {
        var start = bytes.startIndex
        for _ in 0..<2 {
            guard start < bytes.endIndex else { return nil }
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
            guard let record = (try? JSONSerialization.jsonObject(with: bytes.subdata(in: start..<end))) as? [String: Any] else { return nil }
            if record["type"] as? String == "session" { return (start..<end, record) }
            guard record["type"] as? String == "title", end < bytes.endIndex else { return nil }
            start = end + 1
        }
        return nil
    }

    private static func fallback(_ previous: PersistedRun, workspace: RunWorkspace) async -> String {
        guard let result = previous.result else { return "이전 세션을 찾거나 읽을 수 없어 새 세션으로 시작한다. 저장된 결과 없음." }
        var parts = ["""
            이전 실행에 맞는 읽을 수 있는 세션이 없어 새 세션으로 시작한다.
            ## 이전 결과 인계 요약
            결과 요약: \(result.summary)
            """]
        if let report = result.reportPath, let text = try? String(contentsOfFile: report, encoding: .utf8) {
            // Bounded excerpt, not another model call. Preserve the report's concluding evidence.
            parts.append("이전 report 요약 (마지막 최대 12000자):\n" + String(text.suffix(12_000)))
        } else { parts.append("이전 report: 없거나 읽을 수 없음") }
        // The saved patch is only HEAD's uncommitted tail. Include committed changes too,
        // using the preserved branch's creation base and the newly reconstructed worktree.
        let tree = URL(fileURLWithPath: workspace.worktreePath)
        if let branch = previous.workspace?.branch ?? result.branch,
           let reflog = try? await HirdWorkspace.git(["reflog", "show", "--format=%H", branch, "--"], at: tree),
           let base = reflog.split(separator: "\n").last,
           let names = try? await HirdWorkspace.git(["diff", "--name-only", "-z", String(base), "--"], at: tree) {
            let files = names.split(separator: "\0").map(String.init)
            parts.append("이전 결과에서 바뀐 파일 (커밋과 저장된 diff 포함):\n" + (files.isEmpty ? "변경 파일 없음" : files.map { "- " + $0 }.joined(separator: "\n")))
        } else if let diff = result.diffPath,
                  let stats = try? await HirdWorkspace.git(["apply", "--numstat", "-z", "--", diff], at: tree) {
            // Ask Git for bounded metadata instead of loading a potentially large binary patch.
            let files = stats.split(separator: "\0").compactMap { row in
                row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).last.map(String.init)
            }
            parts.append("이전 결과에서 바뀐 파일:\n" + (files.isEmpty ? "저장된 diff에 변경 파일 없음" : files.map { "- " + $0 }.joined(separator: "\n")))
        } else { parts.append("이전 변경 파일: 저장된 diff가 없거나 읽을 수 없음") }
        parts.append("## 이전 검증 근거")
        parts += result.verifications.map {
            "- \($0.command.joined(separator: " ")) — \($0.isInspection ? "문서·화면 확인" : "exit code: " + ($0.exitCode.map(String.init) ?? "unknown")) — \($0.summary)"
        }
        if result.verifications.isEmpty { parts.append("저장된 검증 명령 없음") }
        return parts.joined(separator: "\n")
    }
}
