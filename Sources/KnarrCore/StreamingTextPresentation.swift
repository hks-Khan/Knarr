import Foundation
import Observation

/// Ephemeral display state only. The transcript and persistence always use the received draft.
/// The mounted streaming row advances this state; this object owns no timer or task.
@MainActor @Observable
public final class StreamingTextPresentation {
    public private(set) var messageID: UUID?
    public private(set) var isStreaming = false
    public private(set) var blocks: [MarkdownBlock] = []
    public private(set) var tail = ""
    @ObservationIgnored public private(set) var receivedText = ""
    private var cursor = "".startIndex
    private var scannedCursor = "".startIndex
    @ObservationIgnored private var prefixEnd = "".startIndex
    private var remaining = 0
    @ObservationIgnored private var speed = 0.0
    @ObservationIgnored private var credit = 0.0
    @ObservationIgnored private var markdownElapsed = 0.0
    @ObservationIgnored private var completedBlockCount = 0

    public init() {}

    public var visibleText: String { String(receivedText[..<cursor]) }
    public var hasPendingText: Bool { remaining > 0 }
    /// Pause the frame schedule after both the reveal and its final Markdown promotion settle.
    public var needsFrame: Bool { isStreaming && (hasPendingText || scannedCursor != cursor) }

    public func receive(_ text: String, messageID id: UUID, animate: Bool = true) {
        if messageID != id {
            messageID = id
            receivedText = ""
            cursor = receivedText.startIndex; scannedCursor = cursor; prefixEnd = cursor
            remaining = 0; credit = 0; markdownElapsed = 0; completedBlockCount = 0
            blocks = []; tail = ""
        }
        guard receivedText != text else {
            if !animate { finish() }
            return
        }
        let appending = text.hasPrefix(receivedText)
        if appending && !isStreaming {
            // Selection/Reduce Motion flushes are not message completion. Reopen the unfinished
            // last paragraph so a later delta continues it instead of creating a second block.
            blocks.removeSubrange(completedBlockCount..<blocks.count)
            tail = String(receivedText[prefixEnd..<cursor])
            markdownElapsed = 0
        }
        receivedText = text
        if !appending {
            cursor = receivedText.startIndex; scannedCursor = cursor; prefixEnd = cursor
            remaining = 0; credit = 0; completedBlockCount = 0
            blocks = []; tail = ""
        }
        isStreaming = animate
        // A corrected full snapshot must never leave stale visible prose or stale String indices.
        guard appending, animate else { finish(); return }
        remaining = receivedText[cursor...].count
        // Every batch catches up in about 150ms; larger backlogs reveal more characters per frame.
        speed = max(60, Double(remaining) / 0.15)
    }

    public func advance(by elapsed: TimeInterval) {
        guard needsFrame, elapsed > 0 else { return }
        markdownElapsed += elapsed
        if remaining > 0 {
            credit += speed * elapsed
            let count = min(remaining, Int(credit))
            if count > 0 {
                let next = receivedText.index(cursor, offsetBy: count)
                tail.append(contentsOf: receivedText[cursor..<next])
                cursor = next
                remaining -= count
                credit -= Double(count)
                if remaining == 0 { credit = 0 }
            }
        }
        // Parse only newly completed paragraphs, at most four times a second. Incomplete code,
        // tables and the last paragraph remain verbatim text until a safe boundary or completion.
        if markdownElapsed >= 0.25 {
            markdownElapsed = 0
            promoteCompletedBlocks()
            scannedCursor = cursor
        }
    }

    public func finish() {
        guard messageID != nil, isStreaming || hasPendingText || cursor != receivedText.endIndex else { return }
        cursor = receivedText.endIndex
        promoteCompletedBlocks(updateTail: false)
        completedBlockCount = blocks.count
        blocks.append(contentsOf: MarkdownBlocks.parse(String(receivedText[prefixEnd..<cursor])))
        scannedCursor = cursor
        remaining = 0; credit = 0
        isStreaming = false
        tail = ""
    }

    private func promoteCompletedBlocks(updateTail: Bool = true) {
        guard cursor != scannedCursor else { return }
        var boundary = prefixEnd
        var fence: String?
        // Only the uncommitted suffix is scanned. Blank lines inside fences are not boundaries.
        for line in receivedText[prefixEnd..<cursor].split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.endIndex < cursor else { break } // The last, unfinished line can still change.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
            } else if let open = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                fence = open
            } else if trimmed.isEmpty {
                boundary = receivedText.index(after: line.endIndex)
            }
        }
        guard boundary > prefixEnd else { return }
        blocks.append(contentsOf: MarkdownBlocks.parse(String(receivedText[prefixEnd..<boundary])))
        prefixEnd = boundary
        if updateTail { tail = String(receivedText[boundary..<cursor]) }
    }
}
