import Foundation
import CryptoKit

/// The small, durable slice of a Stallari review that must survive conversation compaction
/// and an app restart: which result it looked at, what it selected, what it actually read,
/// its own notes and the items it has not resolved yet.
///
/// Reading a log is recorded as a read, never as a completed review. Every read stores the
/// exact byte ranges that were delivered and the hash of those bytes, so a same-length rewrite
/// or a changed middle of a large file is detected — a file size is never used as identity.
public struct StallariReview: Codable, Sendable, Hashable {
    /// One delivered contiguous byte range of one saved file.
    public struct Segment: Codable, Sendable, Hashable {
        public var start: Int
        public var end: Int
        /// SHA-256 over exactly the bytes in `start..<end`.
        public var hash: String
        public init(start: Int, end: Int, hash: String) {
            self.start = start; self.end = end; self.hash = hash
        }
    }
    public struct Read: Codable, Sendable, Hashable {
        public var verificationID: String
        public var logPath: String
        /// The ranges actually delivered; a search read has one segment per match.
        public var segments: [Segment]
        public var fileBytes: Int
        public var mode: String
        public var at: Date
        /// The saved result version that was current when these bytes were delivered. A read
        /// taken against a superseded result stays as history but never qualifies as a re-read
        /// of the current evidence. Older payloads have no value here and are treated the same.
        public var basisVersion: String?
        /// An explicit rereview may supersede changed bytes after their ranges have been read
        /// again. Keep the original read as history, without treating it as current evidence.
        public var supersededAt: Date?
        public init(verificationID: String, logPath: String, segments: [Segment], fileBytes: Int,
                    mode: String, at: Date, basisVersion: String? = nil, supersededAt: Date? = nil) {
            self.verificationID = verificationID; self.logPath = logPath
            self.segments = segments; self.fileBytes = fileBytes; self.mode = mode; self.at = at
            self.basisVersion = basisVersion
            self.supersededAt = supersededAt
        }
        /// Kept for payloads written before segments existed: the delivered span is the segment.
        public init(verificationID: String, logPath: String, excerptHash: String, start: Int, end: Int,
                    fileBytes: Int, mode: String, at: Date) {
            self.init(verificationID: verificationID, logPath: logPath,
                      segments: [.init(start: start, end: end, hash: excerptHash)],
                      fileBytes: fileBytes, mode: mode, at: at)
        }
        public var start: Int { segments.map(\.start).min() ?? 0 }
        public var end: Int { segments.map(\.end).max() ?? 0 }
    }
    /// Only an explicit tool call writes a note; an excerpt delivery never creates one.
    public struct Note: Codable, Sendable, Hashable {
        public var text: String
        public var criterion: Int?
        public var at: Date
        public init(text: String, criterion: Int?, at: Date) {
            self.text = text; self.criterion = criterion; self.at = at
        }
    }

    public var issueID: String
    public var runID: String
    /// Content identity of the saved `RunResult` the review was formed against.
    public var resultVersion: String
    public var proposalVersion: Int?
    public var approvalVersion: Int?
    /// SHA-256 over the completion criteria texts, so wording changes invalidate the review.
    public var criteriaHash: String
    public var selectedVerificationIDs: [String]
    public var reads: [Read]
    public var notes: [Note]
    public var openItems: [String]
    /// Set only by `judge_issue` against a review whose basis still matched.
    public var judgedAt: Date?
    public var updatedAt: Date
    /// Optimistic version for whole-record saves; older payloads begin at revision zero.
    public var revision: Int?
    /// When the recorded basis stopped matching, the reviewer's own notes and open items are
    /// carried forward instead of being discarded, and this records the basis they came from.
    public var carriedFromVersion: String?

    public init(issueID: String, runID: String, resultVersion: String, proposalVersion: Int?,
                approvalVersion: Int?, criteriaHash: String, selectedVerificationIDs: [String] = [],
                reads: [Read] = [], notes: [Note] = [], openItems: [String] = [],
                judgedAt: Date? = nil, updatedAt: Date = .now, carriedFromVersion: String? = nil) {
        self.issueID = issueID; self.runID = runID; self.resultVersion = resultVersion
        self.proposalVersion = proposalVersion; self.approvalVersion = approvalVersion
        self.criteriaHash = criteriaHash; self.selectedVerificationIDs = selectedVerificationIDs
        self.reads = reads; self.notes = notes; self.openItems = openItems
        self.judgedAt = judgedAt; self.updatedAt = updatedAt
        self.carriedFromVersion = carriedFromVersion
    }

    public static let maximumReads = 60
    public static let maximumNotes = 20
    public static let maximumSelected = 40
    public static let maximumOpenItems = 20
    public static let maximumNoteCharacters = 1000
    public static let maximumOpenItemCharacters = 400
    public static let maximumSegmentsPerRead = 16

    /// Keeps one durable row small; the order is oldest first so the newest detail survives.
    public func bounded() -> StallariReview {
        var value = self
        value.reads = reads.suffix(Self.maximumReads).map { read in
            var read = read
            read.segments = Array(read.segments.suffix(Self.maximumSegmentsPerRead))
            return read
        }
        value.notes = notes.suffix(Self.maximumNotes).map {
            Note(text: String($0.text.prefix(Self.maximumNoteCharacters)), criterion: $0.criterion, at: $0.at)
        }
        value.openItems = openItems.suffix(Self.maximumOpenItems).map { String($0.prefix(Self.maximumOpenItemCharacters)) }
        value.selectedVerificationIDs = Array(selectedVerificationIDs.prefix(Self.maximumSelected))
        return value
    }

    /// Canonical, deterministic identity of the saved evidence a review was formed against.
    /// JSON encoding is avoided here: the same result must hash the same way on every call.
    /// The artifact manifest metadata is included, so a result whose only change is a new
    /// artifact set still invalidates an earlier cursor or review.
    public static func version(of result: RunResult?) -> String {
        guard let result else { return "none" }
        var canonical = [result.worktreePath, result.branch ?? "", result.commit ?? "", result.diffPath ?? "",
                         result.summary, result.reportPath ?? "", result.artifactManifestPath ?? ""]
        if let manifest = result.artifactManifestMetadata {
            canonical.append(manifest.sha256)
            canonical.append(String(manifest.artifactCount))
            canonical.append(String(manifest.totalBytes))
        } else {
            canonical.append("-")
        }
        // Times are quantized to milliseconds: a stored payload and a fresh read must agree even
        // when the database round-trips a Double, so a version never flips by itself.
        func time(_ value: Date) -> String { String(Int64((value.timeIntervalSince1970 * 1000).rounded())) }
        for check in result.verifications {
            canonical.append(check.id)
            canonical.append(check.command.joined(separator: "\u{1f}"))
            canonical.append(check.workingDirectory)
            canonical.append(check.isInspection ? "inspection" : "command")
            canonical.append(time(check.startedAt))
            canonical.append(time(check.finishedAt))
            canonical.append(check.exitCode.map(String.init) ?? "-")
            canonical.append(check.logPath)
            canonical.append(check.summary)
            canonical.append((check.attachmentPaths ?? []).joined(separator: "\u{1f}"))
        }
        return SHA256.hash(data: Data(canonical.joined(separator: "\u{1e}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(of criteria: [Criterion]) -> String {
        let text = criteria.map(\.text).joined(separator: "\u{0}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The basis a review record is formed against right now.
    public static func basis(issue: Issue, run: PersistedRun) -> (resultVersion: String, proposalVersion: Int?, approvalVersion: Int?, criteriaHash: String) {
        (version(of: run.result), issue.proposal?.version, issue.approval?.version, hash(of: issue.acceptance))
    }

    /// One opaque label for the whole basis a read was delivered under. A read counts as a
    /// re-read of current evidence only when its label still equals the current one, so a result
    /// change and a criteria-wording change both disqualify older reads.
    public static func token(resultVersion: String, proposalVersion: Int?, approvalVersion: Int?,
                             criteriaHash: String) -> String {
        let parts = [resultVersion, proposalVersion.map(String.init) ?? "-",
                     approvalVersion.map(String.init) ?? "-", criteriaHash]
        return digest(Data(parts.joined(separator: "\u{1e}").utf8))
    }

    /// Why this saved review no longer describes the current issue/run/result.
    public struct Invalidations: Sendable, Equatable {
        public var reasons: [String] = []
        public var missingSelection: [String] = []
        public var changedReads: [String] = []
        public var supersededRun: Bool = false
        public var isStale: Bool {
            !reasons.isEmpty || !missingSelection.isEmpty || !changedReads.isEmpty || supersededRun
        }
        public init() {}
        public var summary: String {
            reasons.joined(separator: ",")
        }
    }

    /// `segmentBytes` returns exactly the current bytes at a stored range, or nil when the file
    /// is missing or shorter than that range. The stored hash of those same bytes is compared,
    /// so the check covers same-length rewrites and changed middles of large files.
    /// `currentBasisToken` identifies the review's current basis: a read recorded under an older
    /// basis is history, not evidence, and cannot make the review permanently stale. Reads
    /// written before tokens existed (nil) are still checked against the current bytes.
    public func invalidations(resultVersion: String, proposalVersion: Int?, approvalVersion: Int?,
                              criteriaHash: String, latestRunID: String,
                              availableVerificationIDs: Set<String>,
                              currentBasisToken: String? = nil,
                              segmentBytes: (String, Int, Int) -> (bytes: Data, fileBytes: Int)?) -> Invalidations {
        var value = Invalidations()
        if self.resultVersion != resultVersion { value.reasons.append("resultChanged") }
        if self.proposalVersion != proposalVersion { value.reasons.append("proposalChanged") }
        if self.approvalVersion != approvalVersion { value.reasons.append("approvalChanged") }
        if self.criteriaHash != criteriaHash { value.reasons.append("criteriaChanged") }
        if runID != latestRunID { value.supersededRun = true; value.reasons.append("runSuperseded") }
        // The notes were carried over from an older basis and no explicit re-review has confirmed
        // them since. Saving another plain note does not make them current.
        if carriedFromVersion != nil { value.reasons.append("basisCarriedOver") }
        let available = availableVerificationIDs
        value.missingSelection = selectedVerificationIDs.filter { !available.contains($0) }
        if !value.missingSelection.isEmpty { value.reasons.append("selectedEvidenceMissing") }
        for read in reads where read.supersededAt == nil {
            if let token = read.basisVersion, let current = currentBasisToken, token != current { continue }
            if !Self.matchesCurrentFile(read, segmentBytes: segmentBytes),
               !value.changedReads.contains(read.verificationID) {
                value.changedReads.append(read.verificationID)
            }
        }
        if !value.changedReads.isEmpty { value.reasons.append("readLogChanged") }
        return value
    }

    /// True when the stored ranges still hold exactly the bytes that were delivered: same file
    /// length, same hash of the same ranges. A same-length rewrite or a changed middle fails.
    static func matchesCurrentFile(_ read: Read,
                                   segmentBytes: (String, Int, Int) -> (bytes: Data, fileBytes: Int)?) -> Bool {
        guard !read.segments.isEmpty else { return false }
        return read.segments.allSatisfy { segment in
            guard let current = segmentBytes(read.logPath, segment.start, segment.end) else { return false }
            guard current.fileBytes == read.fileBytes else { return false }
            return StallariReview.digest(current.bytes) == segment.hash
        }
    }
}
