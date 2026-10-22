import Foundation
import CryptoKit

/// Small responses with explicit cursors; historical snapshots stay in storage.
enum StallariReadback {
    static func issue(_ issue: Issue) throws -> OMPJSON {
        var value = issue
        value.events = []; value.hirds = []; value.detail = String(value.detail.prefix(4000))
        // Only the tool readback is compacted; durable evidence and UI snapshots stay intact.
        value.latestResult = nil
        value.proposalHistory = value.proposalHistory ?? value.proposal.map { [$0] }
        guard case .object(var fields) = try JSONDecoder().decode(OMPJSON.self, from: JSONEncoder().encode(value)) else {
            throw StallariError.invalidArguments
        }
        if let result = issue.latestResult {
            fields["latestResult"] = .object([
                "summary": .string(String(result.summary.prefix(2000))),
                "worktreePath": .string(result.worktreePath),
                "branch": result.branch.map(OMPJSON.string) ?? .null,
                "commit": result.commit.map(OMPJSON.string) ?? .null,
                "diffPath": result.diffPath.map(OMPJSON.string) ?? .null,
                "reportAvailable": .bool(result.reportPath != nil),
                "artifactManifestPath": result.artifactManifestPath.map(OMPJSON.string) ?? .null,
                "verificationCount": .number(Double(result.verifications.count))
            ])
        }
        fields["progress"] = progress(IssueCards.progress(for: issue))
        return .object(fields)
    }
    static func number(_ a: OMPJSON, _ key: String, default fallback: Int, maximum: Int) throws -> Int {
        guard let value = a[key] else { return fallback }
        guard let n = value.integer, n >= 0, n <= maximum else { throw StallariError.invalidArguments }
        return n
    }
    static func run(_ r: PersistedRun) -> OMPJSON {
        let result = r.result
        return .object([
            "runID": .string(r.id.rawValue), "issueID": .string(r.issueID.rawValue), "projectID": .string(r.projectID),
            "state": .string(r.state.rawValue), "mode": .string(r.mode?.rawValue ?? "legacy"),
            "requestedModel": r.requestedModel.map(OMPJSON.string) ?? .null,
            "observedModel": r.observedModel.map(OMPJSON.string) ?? .null,
            "requestedThinking": r.requestedThinking.map(OMPJSON.string) ?? .null,
            "observedThinking": r.observedThinking.map(OMPJSON.string) ?? .null,
            "cancellationRequestedAt": r.cancellationRequestedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
            "processEndedAt": r.processEndedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
            "cleanupVerified": .bool(r.processEndedAt != nil),
            "ompSessionID": r.ompSessionID.map(OMPJSON.string) ?? .null,
            "currentCommand": r.hird.currentCommand.map { .string(String($0.prefix(2000))) } ?? .null,
            "runtimeResources": r.hird.runtimeResources.map { resources in .object([
                "contextFiles": .array(resources.contextFiles.map(OMPJSON.string)),
                "skills": .array(resources.skills.map(OMPJSON.string)),
                "extensionCommands": .array(resources.extensionCommands.map(OMPJSON.string)),
                "trustedExtensions": .array(resources.trustedExtensions.map(OMPJSON.string)),
                "externalExtensionsDisabled": .bool(resources.externalExtensionsDisabled)
            ]) } ?? .null,
            "lspRecords": .array((r.hird.lspRecords ?? []).suffix(20).map { record in .object([
                "action": .string(record.action), "server": record.server.map(OMPJSON.string) ?? .null,
                "succeeded": .bool(record.succeeded), "logPath": .string(record.logPath)
            ]) }),
            "stopReason": r.stopReason.map(OMPJSON.string) ?? .null,
            "startedAt": .number(r.startedAt.timeIntervalSince1970), "endedAt": r.endedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
            "worktreePath": (r.workspace?.worktreePath ?? result?.worktreePath).map(OMPJSON.string) ?? .null,
            "resultSummary": result.map { .string(String($0.summary.prefix(2000))) } ?? .null,
            "commit": result?.commit.map(OMPJSON.string) ?? .null,
            "reportAvailable": .bool(result?.reportPath != nil),
            "verificationCount": .number(Double(result?.verifications.count ?? 0)),
            "savedSnapshotCount": .number(Double(r.savedResultCount ?? r.resultHistory.count)),
            "progress": progress(r.stageProgress)
        ])
    }
    /// The fields a follow-up page still needs: identity, version and counts, without the full run.
    static func runHeader(_ r: PersistedRun) -> OMPJSON {
        .object([
            "runID": .string(r.id.rawValue), "issueID": .string(r.issueID.rawValue),
            "state": .string(r.state.rawValue), "resultVersion": .string(StallariReview.version(of: r.result)),
            "verificationCount": .number(Double(r.result?.verifications.count ?? 0)),
            "reportAvailable": .bool(r.result?.reportPath != nil)
        ])
    }
    /// All read APIs and issue cards project the same saved reports, or the legacy command inference.
    static func progress(_ p: HirdProgress) -> OMPJSON {
        let current = p.reportedStageIndex.map { p.plannedStages[$0 - 1] }
        let stages: [OMPJSON] = p.plannedStages.map { stage in
            .object([
                "key": .string(stage.id), "title": .string(stage.title), "state": .string(stage.state.rawValue),
                "evidence": .string(stage.evidence), "criterion": stage.criterion.map { .number(Double($0)) } ?? .null,
                "verified": stage.verified.map(OMPJSON.bool) ?? .null,
                "confirmation": .string(stage.verified.map { $0 ? "verified" : "unverified" } ?? "notReported"),
                "note": stage.note.map(OMPJSON.string) ?? .null
            ])
        }
        return .object([
            "stageIndex": p.reportedStageIndex.map { .number(Double($0)) } ?? .null,
            "stageCount": .number(Double(p.plannedStages.count)),
            "stage": current.map { .string($0.id) } ?? .null,
            "stageTitle": current.map { .string($0.title) } ?? .null,
            "reportedCompleteCount": .number(Double(p.reportedCompleteCount)),
            "state": .string(p.condition.rawValue), "stages": .array(stages),
            "planChanges": .array(p.planChanges.map {
                .object(["at": .number($0.at.timeIntervalSince1970), "reason": .string($0.reason),
                         "titles": .array($0.titles.map(OMPJSON.string))])
            }),
            "basis": p.basis.map { .string(String($0.prefix(2000))) } ?? .null,
            "checks": .object(["passed": .number(Double(p.checks.passed)), "failed": .number(Double(p.checks.failed)),
                               "running": .number(Double(p.checks.running))])
        ])
    }

    // MARK: - Check eligibility

    /// One record's usable status, using exactly the rules `judge_issue` enforces.
    struct CheckFacts {
        enum Status: String { case passed, failed, unknown }
        let record: VerificationRecord
        let status: Status
        /// A met criterion may cite this record.
        let usableAsProof: Bool
        /// A code the model can correct without guessing.
        let reason: String?
    }

    static func facts(_ record: VerificationRecord) -> CheckFacts {
        if record.isInspection {
            // Exactly the judge's rule: no exit code, an ordered time range, and a file whose
            // complete UTF-8 text is non-blank. Nothing here is sampled, so the list cannot
            // advertise a different eligibility than judge_issue enforces.
            let complete = record.exitCode == nil && record.finishedAt >= record.startedAt && !record.logPath.isEmpty
            let readable = hasVisibleText(record.logPath)
            return .init(record: record, status: .unknown, usableAsProof: readable && complete,
                         reason: readable && complete ? nil : "inspectionLogMissingOrEmpty")
        }
        guard record.isSingleCheck else {
            return .init(record: record, status: status(record.exitCode), usableAsProof: false, reason: "compositeCommand")
        }
        guard record.finishedAt >= record.startedAt, !record.command.isEmpty, !record.logPath.isEmpty else {
            return .init(record: record, status: .unknown, usableAsProof: false, reason: "recordIncomplete")
        }
        guard let exit = record.exitCode else {
            return .init(record: record, status: .unknown, usableAsProof: false, reason: "exitCodeUnknown")
        }
        guard exit == 0 else {
            return .init(record: record, status: .failed, usableAsProof: false, reason: "nonzeroExit")
        }
        return .init(record: record, status: .passed, usableAsProof: true, reason: nil)
    }

    private static func status(_ exit: Int32?) -> CheckFacts.Status {
        guard let exit else { return .unknown }
        return exit == 0 ? .passed : .failed
    }

    static func check(_ record: VerificationRecord) -> OMPJSON {
        let value = facts(record)
        return .object([
            "verificationID": .string(record.id), "kind": .string(record.isInspection ? "inspection" : "command"),
            "command": .array(record.command.map { .string(String($0.prefix(2000))) }),
            "workingDirectory": .string(record.workingDirectory),
            "exitCode": record.exitCode.map { .number(Double($0)) } ?? .null,
            "status": .string(value.status.rawValue),
            "singleCheck": .bool(record.isSingleCheck),
            "finishedAt": .number(record.finishedAt.timeIntervalSince1970),
            "usableAsProof": .bool(value.usableAsProof),
            "eligibilityReason": value.reason.map(OMPJSON.string) ?? .null
        ])
    }

    static func logSize(_ path: String) -> Int {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    /// Whether a saved log holds readable text, using the judge's exact semantics: the whole file
    /// must decode as UTF-8 and its trimmed text must be non-empty. A blank head followed by real
    /// content counts as readable; an invalid byte later in the file does not.
    private static func hasVisibleText(_ path: String) -> Bool {
        guard logSize(path) > 0, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Filtered checks with a version-pinned cursor

    struct CheckQuery {
        var query: String?
        var kind: String?
        var status: String?
        var since: Date?
        var until: Date?
        var verificationID: String?
        var order: String
        var offset: Int
        var limit: Int
    }

    private static func matches(_ record: VerificationRecord, facts: CheckFacts, _ q: CheckQuery) -> Bool {
        if let id = q.verificationID, record.id != id { return false }
        if let kind = q.kind {
            switch kind {
            case "inspection": if !record.isInspection { return false }
            case "command": if record.isInspection { return false }
            default: break
            }
        }
        if let status = q.status {
            switch status {
            case "passed": if facts.status != .passed { return false }
            case "failed": if facts.status != .failed { return false }
            case "unknown": if facts.status != .unknown { return false }
            case "eligible": if !facts.usableAsProof { return false }
            case "ineligible": if facts.usableAsProof { return false }
            default: break
            }
        }
        if let since = q.since, record.finishedAt < since { return false }
        if let until = q.until, record.finishedAt > until { return false }
        if let text = q.query, !text.isEmpty {
            let haystack = (record.command.joined(separator: " ") + " " + record.summary).lowercased()
            if !haystack.contains(text.lowercased()) { return false }
        }
        return true
    }

    static func cursor(version: String, query: CheckQuery, offset: Int) -> String {
        // The digest covers only the filter shape; the offset is carried separately, so a page
        // can be verified against the same query it was generated for.
        let shape = [query.query ?? "", query.kind ?? "", query.status ?? "",
                     query.since.map { String($0.timeIntervalSince1970) } ?? "",
                     query.until.map { String($0.timeIntervalSince1970) } ?? "",
                     query.verificationID ?? "", query.order].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(shape.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
        return "c1." + String(version.prefix(12)) + "." + String(offset) + "." + digest
    }

    struct ParsedCursor {
        let versionPrefix: String
        let offset: Int
        let digest: String
    }

    static func parseCursor(_ text: String) -> ParsedCursor? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "c1", let offset = Int(parts[2]), offset >= 0,
              parts[1].count == 12, parts[3].count == 12,
              parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              parts[3].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return .init(versionPrefix: parts[1], offset: offset, digest: parts[3])
    }

    static func checks(_ r: PersistedRun, query: CheckQuery, cursorText: String?) throws -> OMPJSON {
        let version = StallariReview.version(of: r.result)
        let all = r.result?.verifications ?? []
        var query = query
        var changed = false
        if let cursorText {
            guard let parsed = parseCursor(cursorText) else {
                throw StallariError.rejectedEvidence("커서가 잘못됐어요. get_run(view: checks)를 커서 없이 다시 호출해 현재 목록을 받으세요.")
            }
            let expected = cursor(version: version, query: query, offset: parsed.offset)
            if parsed.versionPrefix != String(version.prefix(12)) || parsed.digest != expected.split(separator: ".").last.map(String.init) {
                changed = true
            } else {
                query.offset = parsed.offset
            }
        }
        // One eligibility pass per record: it reads a log, so it must not be repeated per filter.
        let allFacts = all.map { facts($0) }
        var filtered: [(index: Int, record: VerificationRecord, facts: CheckFacts)] = []
        filtered.reserveCapacity(all.count)
        for (index, record) in all.enumerated() where matches(record, facts: allFacts[index], query) {
            filtered.append((index, record, allFacts[index]))
        }
        let ordered = query.order == "oldest" ? filtered : filtered.reversed()
        // An offset past the end yields an empty page rather than trapping on a reversed range.
        let start = changed ? 0 : min(max(0, query.offset), ordered.count)
        let end = min(ordered.count, start + query.limit)
        let page = start < ordered.count ? Array(ordered[start..<end]) : []
        let nextOffset = end < ordered.count ? end : nil
        // Counts describe the whole saved result, not just this filter, so a targeted search
        // cannot make failures or unverified checks look absent.
        let counts = Dictionary(grouping: allFacts, by: { $0.status })
        return .object([
            "run": (changed || start > 0) ? runHeader(r) : run(r),
            "resultVersion": .string(version),
            "query": .object([
                "text": query.query.map(OMPJSON.string) ?? .null, "kind": query.kind.map(OMPJSON.string) ?? .null,
                "status": query.status.map(OMPJSON.string) ?? .null, "order": .string(query.order)
            ]),
            "total": .number(Double(all.count)), "matched": .number(Double(filtered.count)),
            "counts": .object(["passed": .number(Double(counts[.passed]?.count ?? 0)),
                               "failed": .number(Double(counts[.failed]?.count ?? 0)),
                               "unknown": .number(Double(counts[.unknown]?.count ?? 0)),
                               "eligible": .number(Double(allFacts.filter(\.usableAsProof).count))]),
            "verifications": .array(page.map { check($0.1) }),
            "nextOffset": nextOffset.map { .number(Double($0)) } ?? .null,
            "nextCursor": nextOffset.map { .string(cursor(version: version, query: query, offset: $0)) } ?? .null,
            "changed": .bool(changed),
            "changedNote": changed ? .string("결과 버전이 바뀌어 이전 커서 페이지를 버리고 새 목록을 반환했어요.") : .null
        ])
    }

    /// Compatibility page: the existing offset/limit contract, without repeating the whole run
    /// header on follow-up pages.
    static func verifications(_ r: PersistedRun, offset: Int, limit: Int) -> OMPJSON {
        let all = r.result?.verifications ?? [], end = min(all.count, offset + limit)
        let page = offset < all.count ? Array(all[offset..<end]) : []
        let next = end < all.count ? end : nil
        return .object([
            "run": offset > 0 ? runHeader(r) : run(r),
            "resultVersion": .string(StallariReview.version(of: r.result)),
            "verifications": .array(page.map { check($0) }),
            "nextOffset": next.map { .number(Double($0)) } ?? .null,
            "nextCursor": next.map { .string(cursor(version: StallariReview.version(of: r.result),
                                                     query: CheckQuery(order: "oldest", offset: 0, limit: limit), offset: $0)) } ?? .null
        ])
    }

    // MARK: - Original text access

    struct Excerpt {
        let path: String
        let text: String
        let start: Int
        let end: Int
        let total: Int
        let totalBytes: Int
        let nextOffset: Int?
        let earlierOffset: Int?
        let matchedLines: [OMPJSON]
        let scanTruncated: Bool
        /// The exact byte ranges delivered by this call, with the hash of those bytes.
        var segments: [StallariReview.Segment] = []

        init(path: String, text: String, start: Int, end: Int, total: Int, totalBytes: Int,
             nextOffset: Int?, earlierOffset: Int?, matchedLines: [OMPJSON], scanTruncated: Bool,
             segments: [StallariReview.Segment] = []) {
            self.path = path; self.text = text; self.start = start; self.end = end; self.total = total
            self.totalBytes = totalBytes; self.nextOffset = nextOffset; self.earlierOffset = earlierOffset
            self.matchedLines = matchedLines; self.scanTruncated = scanTruncated; self.segments = segments
        }
    }

    /// The stored ranges for a delivered excerpt. Search reads keep one segment per match; range
    /// and tail reads keep the single span that was actually returned.
    static func segments(for e: Excerpt) -> [StallariReview.Segment] {
        e.segments
    }

    /// Exactly the stored bytes of one range, or nil when the file is missing or shorter.
    static func readBytes(_ path: String, start: Int, end: Int) -> Data? {
        guard start >= 0, end > start else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), Int(size) >= end else { return nil }
        guard (try? handle.seek(toOffset: UInt64(start))) != nil else { return nil }
        guard let data = try? handle.read(upToCount: end - start), data.count == end - start else { return nil }
        return data
    }

    private static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        for trim in 1...min(3, data.count) {
            let prefix = data.dropLast(trim)
            if !prefix.isEmpty, let decoded = String(data: prefix, encoding: .utf8) { return decoded }
        }
        return nil
    }

    /// Bounded SHA-256 of the file: the whole file up to 4 MiB, otherwise its first and last
    /// megabyte plus its size. The scope is reported so a hash is never read as a full identity.
    static func fileHash(_ path: String, size: Int) -> (hash: String, scope: String) {
        guard size >= 0, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return ("unreadable", "none") }
        defer { try? handle.close() }
        var hasher = SHA256()
        if size <= 4 << 20 {
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return (hex(hasher.finalize()), "full")
        }
        if let head = try? handle.read(upToCount: 1 << 20) { hasher.update(data: head) }
        if (try? handle.seek(toOffset: UInt64(size - (1 << 20)))) != nil,
           let tail = try? handle.read(upToCount: 1 << 20) { hasher.update(data: tail) }
        hasher.update(data: Data(String(size).utf8))
        return (hex(hasher.finalize()), "sampled")
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func readRange(_ path: String, offset: Int, limit: Int) throws -> Excerpt {
        let url = URL(fileURLWithPath: path)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw StallariError.rejectedEvidence("저장된 텍스트 파일을 읽을 수 없어요. 원본 경로와 파일 보존 상태를 확인하세요.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        let start = min(offset, size)
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.read(upToCount: max(4, limit)) ?? Data()
        guard let text = decode(data) else {
            throw StallariError.rejectedEvidence("UTF-8 텍스트 파일과 유효한 바이트 위치만 읽을 수 있어요. nextOffset을 그대로 사용해 주세요.")
        }
        // Advance by the bytes actually decoded: a partial multi-byte character at the page end is
        // dropped, so the next page starts on a character boundary.
        let end = start + text.utf8.count
        return .init(path: path, text: text, start: start, end: end, total: size, totalBytes: text.utf8.count,
                     nextOffset: end < size ? end : nil, earlierOffset: start > 0 ? max(0, start - limit) : nil,
                     matchedLines: [], scanTruncated: false,
                     segments: text.isEmpty ? [] : [.init(start: start, end: start + text.utf8.count,
                                                         hash: StallariReview.digest(Data(text.utf8)))])
    }

    static func readTail(_ path: String, limit: Int) throws -> Excerpt {
        let url = URL(fileURLWithPath: path)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw StallariError.rejectedEvidence("저장된 텍스트 파일을 읽을 수 없어요. 원본 경로와 파일 보존 상태를 확인하세요.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        var start = max(0, size - limit)
        try handle.seek(toOffset: UInt64(start))
        var data = try handle.read(upToCount: limit) ?? Data()
        var text = decode(data)
        // The window may begin inside a multi-byte character; skip those bytes and retry once.
        while text == nil, start < size, data.count > 1 {
            data = data.dropFirst()
            start += 1
            text = decode(data)
        }
        guard let text else {
            throw StallariError.rejectedEvidence("UTF-8 텍스트 파일의 끝부분만 읽을 수 있어요. offset으로 원문 위치를 지정하세요.")
        }
        return .init(path: path, text: text, start: start, end: start + text.utf8.count, total: size, totalBytes: text.utf8.count,
                     nextOffset: nil, earlierOffset: start > 0 ? max(0, start - limit) : nil,
                     matchedLines: [], scanTruncated: false,
                     segments: text.isEmpty ? [] : [.init(start: start, end: start + text.utf8.count,
                                                         hash: StallariReview.digest(Data(text.utf8)))])
    }

    /// Deterministic case-insensitive ASCII substring search with a bounded scan. Every hit
    /// reports its exact byte range in the original file, and the returned context text is cut
    /// on UTF-8 boundaries; the caller's byte budget is never exceeded.
    static func search(_ path: String, text: String, maxMatches: Int, context: Int, limit: Int) throws -> Excerpt {
        let url = URL(fileURLWithPath: path)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw StallariError.rejectedEvidence("저장된 텍스트 파일을 읽을 수 없어요. 원본 경로와 파일 보존 상태를 확인하세요.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        let cap = min(size, 8 << 20)
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: cap) ?? Data()
        let needle = Array(text.lowercased().utf8)
        guard !needle.isEmpty else { throw StallariError.invalidArguments }
        let raw = [UInt8](data)
        var matches: [OMPJSON] = []
        var segments: [StallariReview.Segment] = []
        var bytesUsed = 0
        var index = 0
        while index + needle.count <= raw.count, matches.count < maxMatches {
            guard asciiEqual(raw, index, needle) else { index += 1; continue }
            var start = max(0, index - context)
            var end = min(raw.count, index + needle.count + context)
            start = boundaryBack(raw, start)
            end = boundaryForward(raw, end)
            let available = limit - bytesUsed
            if available <= 0 { break }
            if end - start > available {
                // Shrink the window symmetrically but keep the match itself.
                let matchEnd = min(raw.count, index + needle.count)
                start = max(boundaryBack(raw, index), matchEnd - available)
                end = matchEnd
                if end - start > available { start = end - available }
                start = boundaryForward(raw, start)
            }
            let excerpt = String(decoding: Data(raw[start..<end]), as: UTF8.self)
            bytesUsed += end - start
            matches.append(.object([
                "byteStart": .number(Double(start)), "byteEnd": .number(Double(end)),
                "matchStart": .number(Double(index)), "matchEnd": .number(Double(index + needle.count)),
                "text": .string(excerpt)
            ]))
            segments.append(.init(start: start, end: end, hash: StallariReview.digest(Data(raw[start..<end]))))
            index = min(raw.count, index + needle.count)
        }
        return .init(path: path, text: "", start: 0, end: 0, total: size, totalBytes: bytesUsed,
                     nextOffset: nil, earlierOffset: nil, matchedLines: matches,
                     scanTruncated: size > cap, segments: segments)
    }

    /// ASCII-only case folding compared on bytes, so indexes stay valid for non-ASCII data.
    private static func asciiEqual(_ raw: [UInt8], _ index: Int, _ needle: [UInt8]) -> Bool {
        var i = 0
        while i < needle.count {
            let a = raw[index + i], b = needle[i]
            if a == b { i += 1; continue }
            let folded = (65...90).contains(a) ? a + 32 : a
            if folded == b { i += 1; continue }
            return false
        }
        return true
    }

    private static func isContinuation(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }
    private static func boundaryBack(_ raw: [UInt8], _ index: Int) -> Int {
        var i = index
        while i > 0, i < raw.count, isContinuation(raw[i]) { i -= 1 }
        return i
    }
    private static func boundaryForward(_ raw: [UInt8], _ index: Int) -> Int {
        var i = index
        while i < raw.count, isContinuation(raw[i]) { i += 1 }
        return i
    }

    static func excerpt(_ e: Excerpt, verificationID: String, mode: String) -> OMPJSON {
        // The file hash is only a coarse identity (full up to 4 MiB, otherwise sampled). The
        // exact identity of what was delivered is the per-segment hash of the returned bytes.
        let hash = fileHash(e.path, size: e.total)
        let delivered = segments(for: e)
        return .object([
            "verificationID": .string(verificationID), "mode": .string(mode), "logPath": .string(e.path),
            "fileHash": .string(hash.hash), "fileHashScope": .string(hash.scope),
            "totalBytes": .number(Double(e.total)),
            "returnedBytes": .number(Double(e.totalBytes)),
            "start": .number(Double(e.start)), "end": .number(Double(e.end)),
            "omittedBefore": .bool(e.start > 0), "omittedAfter": .bool((e.nextOffset ?? e.total) < e.total),
            "nextOffset": e.nextOffset.map { .number(Double($0)) } ?? .null,
            "earlierOffset": e.earlierOffset.map { .number(Double($0)) } ?? .null,
            "matches": e.matchedLines.isEmpty ? .null : .array(e.matchedLines),
            "scanTruncated": .bool(e.scanTruncated),
            "segments": .array(delivered.map { segment in
                .object(["start": .number(Double(segment.start)), "end": .number(Double(segment.end)),
                         "sha256": .string(segment.hash)])
            }),
            "text": .string(e.text),
            "sourceIsUntrusted": .bool(true)
        ])
    }

    static func readFile(_ path: String, offset: Int, limit: Int) throws -> OMPJSON {
        let value = try readRange(path, offset: offset, limit: limit)
        var result = excerpt(value, verificationID: "", mode: "range")
        if case .object(var fields) = result {
            fields["offset"] = .number(Double(offset))
            result = .object(fields)
        }
        return result
    }

    // MARK: - Review state projection

    static func reviewReadback(run: PersistedRun, issue: Issue, latestRunID: String,
                               review: StallariReview?) -> OMPJSON {
        let result = run.result
        let version = StallariReview.version(of: result)
        let criteriaHash = StallariReview.hash(of: issue.acceptance)
        let all = result?.verifications ?? []
        let facts = all.map { self.facts($0) }
        let statuses = Dictionary(grouping: facts, by: { $0.status })
        let currentBasisToken = StallariReview.token(
            resultVersion: version, proposalVersion: issue.proposal?.version,
            approvalVersion: issue.approval?.version, criteriaHash: criteriaHash)
        let invalidations = review?.invalidations(
            resultVersion: version, proposalVersion: issue.proposal?.version,
            approvalVersion: issue.approval?.version, criteriaHash: criteriaHash,
            latestRunID: latestRunID, availableVerificationIDs: Set(all.map(\.id)),
            currentBasisToken: currentBasisToken,
            segmentBytes: { path, start, end in
                let size = logSize(path)
                guard size >= 0, let data = readBytes(path, start: start, end: end) else { return nil }
                return (data, size)
            }) ?? StallariReview.Invalidations()
        let criteria: [OMPJSON] = issue.acceptance.enumerated().map { index, criterion in
            .object(["index": .number(Double(index)), "text": .string(criterion.text),
                     "state": .string(String(describing: criterion.state))])
        }
        let proposalVersion: OMPJSON = issue.proposal.map { OMPJSON.number(Double($0.version)) } ?? .null
        let approvalVersion: OMPJSON = issue.approval.map { OMPJSON.number(Double($0.version)) } ?? .null
        let basis: OMPJSON = .object([
            "issueID": OMPJSON.string(issue.id.rawValue), "runID": OMPJSON.string(run.id.rawValue),
            "latestRunID": OMPJSON.string(latestRunID), "runIsLatest": OMPJSON.bool(run.id.rawValue == latestRunID),
            "resultVersion": OMPJSON.string(version), "runState": OMPJSON.string(run.state.rawValue),
            "proposalVersion": proposalVersion,
            "approvalVersion": approvalVersion,
            "approvedForThisRun": OMPJSON.bool(issue.approval?.runID == run.id),
            "criteriaHash": OMPJSON.string(criteriaHash),
            "reportAvailable": OMPJSON.bool(result?.reportPath != nil)
        ])
        let counts: OMPJSON = .object([
            "total": .number(Double(all.count)),
            "passed": .number(Double(statuses[.passed]?.count ?? 0)),
            "failed": .number(Double(statuses[.failed]?.count ?? 0)),
            "unknown": .number(Double(statuses[.unknown]?.count ?? 0)),
            "inspection": .number(Double(all.filter(\.isInspection).count)),
            "eligible": .number(Double(facts.filter(\.usableAsProof).count))
        ])
        let invalidationsValue: OMPJSON = .object([
            "stale": .bool(invalidations.isStale),
            "reasons": .array(invalidations.reasons.map(OMPJSON.string)),
            "missingSelection": .array(invalidations.missingSelection.map(OMPJSON.string)),
            "changedReads": .array(invalidations.changedReads.map(OMPJSON.string))
        ])
        var value: [String: OMPJSON] = [
            "basis": basis,
            "checks": counts,
            "failedChecks": .array(facts.filter { $0.status == .failed }.suffix(10).map { check($0.record) }),
            "unknownChecks": .array(facts.filter { $0.status == .unknown }.suffix(10).map { check($0.record) }),
            "criteria": .array(criteria),
            "invalidations": invalidationsValue,
            "readingIsNotCompletion": .bool(true),
            "next": .string("Reading a log records only that read. Save notes with save_review, then judge every criterion with judge_issue.")
        ]
        if let review {
            value["review"] = .object([
                "runID": .string(review.runID), "issueID": .string(review.issueID),
                "selectedVerificationIDs": .array(review.selectedVerificationIDs.map(OMPJSON.string)),
                "reads": .array(review.reads.map { read in .object([
                    "verificationID": .string(read.verificationID), "logPath": .string(read.logPath),
                    "start": .number(Double(read.start)), "end": .number(Double(read.end)),
                    "segments": .array(read.segments.map { segment in
                        .object(["start": .number(Double(segment.start)), "end": .number(Double(segment.end)),
                                 "sha256": .string(segment.hash)])
                    }),
                    "fileBytes": .number(Double(read.fileBytes)),
                    "mode": .string(read.mode),
                    "fileChangedSinceRead": .bool(read.supersededAt != nil || invalidations.changedReads.contains(read.verificationID)),
                    "currentBasis": .bool(read.supersededAt == nil && (read.basisVersion == nil || read.basisVersion == currentBasisToken)),
                    "supersededAt": read.supersededAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                    "at": .number(read.at.timeIntervalSince1970)]) }),
                "notes": .array(review.notes.map { note in .object([
                    "text": .string(note.text), "criterion": note.criterion.map { .number(Double($0)) } ?? .null,
                    "at": .number(note.at.timeIntervalSince1970)]) }),
                "openItems": .array(review.openItems.map(OMPJSON.string)),
                "carriedFromVersion": review.carriedFromVersion.map(OMPJSON.string) ?? .null,
                "judgedAt": review.judgedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                "updatedAt": .number(review.updatedAt.timeIntervalSince1970)
            ])
        } else {
            value["review"] = .null
        }
        return .object(value)
    }
}
