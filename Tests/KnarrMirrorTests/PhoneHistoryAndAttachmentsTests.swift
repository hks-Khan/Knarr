import CloudKit
import Foundation
import KnarrCore
import KnarrSync
import Testing
@testable import KnarrMirror

@Suite struct PhoneAttachmentTests {
    func attachment(_ n: Int, type: String = "image/jpeg", bytes: Int = 4) -> MobileAttachment {
        MobileAttachment(id: "a\(n)", name: "shot\(n).jpg", type: type, byteCount: bytes, data: Data(repeating: UInt8(n), count: bytes))
    }

    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("knarr-attach-" + UUID().uuidString, isDirectory: true)
    }

    @Test func picturesAreWrittenOnceUnderTheRequestName() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try MobileRequestApplier.saveAttachments([attachment(1), attachment(2)], in: dir, request: "r1")
        #expect(first.map(\.lastPathComponent) == ["r1-0.jpg", "r1-1.jpg"])
        #expect(try Data(contentsOf: first[1]) == Data(repeating: 2, count: 4))
        // The same request retried rewrites the same files, so no second copy appears.
        let again = try MobileRequestApplier.saveAttachments([attachment(1), attachment(2)], in: dir, request: "r1")
        #expect(again == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
    }

    @Test func countAndSizeLimitsAreRefusedBeforeWriting() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let tooMany = (0...MobileLimits.attachmentCount).map { attachment($0) }
        #expect(throws: MobileRequestApplier.Rejected.self) {
            try MobileRequestApplier.saveAttachments(tooMany, in: dir, request: "r2")
        }
        var huge = attachment(3, bytes: MobileLimits.attachmentBytes + 1)
        #expect(throws: MobileRequestApplier.Rejected.self) {
            try MobileRequestApplier.saveAttachments([huge], in: dir, request: "r3")
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        // Declared size must match what arrived.
        huge.byteCount = 1
        #expect(throws: MobileRequestApplier.Rejected.self) {
            try MobileRequestApplier.saveAttachments([huge], in: dir, request: "r4")
        }
        #expect(throws: MobileRequestApplier.Rejected.self) {
            try MobileRequestApplier.saveAttachments([attachment(9, type: "application/pdf")], in: dir, request: "r5")
        }
    }

    @Test func invalidLaterPictureDoesNotWriteEarlierPictures() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var invalid = attachment(2); invalid.data = nil
        #expect(throws: MobileRequestApplier.Rejected.self) {
            try MobileRequestApplier.saveAttachments([attachment(1), invalid], in: dir, request: "r-invalid")
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func aRequestWithoutBytesIsRefusedRatherThanSentEmpty() {
        var missing = attachment(1); missing.data = nil
        #expect(throws: MobileRequestApplier.Rejected.self) {
            try MobileRequestApplier.saveAttachments([missing], in: directory(), request: "r6")
        }
    }
}

@Suite struct PhoneHistoryProjectionTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let info = StallariInfo(engine: "OMP", scope: "")

    func chat(_ n: Int, thread: String) -> ChatItem {
        ChatItem(at: at.addingTimeInterval(Double(n)), kind: .user("message \(n)"))
    }

    @Test func eachThreadCarriesItsNewestMessagesAndOlderOnesStayWithThePage() {
        let long = (0..<100).map { chat($0, thread: "issue-1") }
        var kept = MobileProjection.records(issues: [], questions: [], chat: [], projects: [], stallari: info, isResponding: false, now: at,
                                            threads: [.default, ConversationThread(id: "issue-1", name: "이슈 대화", issueID: "i1")],
                                            chatByThread: [ConversationThread.defaultID: [chat(0, thread: "default")], "issue-1": long])
        let messages = kept.compactMap { if case .message(let m) = $0 { m } else { nil } }
        #expect(messages.filter { $0.thread == "issue-1" }.count == min(long.count, MobileLimits.recentPerThread))
        #expect(messages.filter { $0.thread == "issue-1" }.map(\.text).last == "message 99")

        // The phone paged older records: those stay in the next snapshot as well.
        let older = MobileProjection.history(items: long, thread: "issue-1", before: at.addingTimeInterval(40),
                                             titles: [:], questions: [])
        let keep = Set(older.map(\.id))
        kept = MobileProjection.records(issues: [], questions: [], chat: [], projects: [], stallari: info, isResponding: false, now: at,
                                        threads: [.default, ConversationThread(id: "issue-1", name: "이슈 대화", issueID: "i1")],
                                        chatByThread: ["issue-1": long], keepMessages: keep)
        let all = kept.compactMap { if case .message(let m) = $0 { m } else { nil } }
        #expect(Set(older.map(\.id)).isSubset(of: Set(all.map(\.id))))
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test func historyPageIsNewestFirstAndLimited() {
        let long = (0..<100).map { chat($0, thread: "issue-1") }
        let page = MobileProjection.history(items: long, thread: "issue-1", before: at.addingTimeInterval(50),
                                            titles: [:], questions: [])
        #expect(page.count == MobileLimits.historyPage)
        #expect(page.first?.text == "message 49")
        #expect(page.last?.text == "message 0")
        // Asking again returns the same records; the phone replaces them by ID.
        #expect(MobileProjection.history(items: long, thread: "issue-1", before: at.addingTimeInterval(50),
                                         titles: [:], questions: []).map(\.id) == page.map(\.id))
    }

    @Test func threadRecordsNameMainAndEachConversation() {
        let threads = [ConversationThread.default,
                       ConversationThread(id: "p1", name: "Soomcha", projectID: "soomcha"),
                       ConversationThread(id: "i1", name: "로그인 문구", issueID: "i1")]
        let records = MobileProjection.records(issues: [makeIssue("i1", .running)], questions: [], chat: [], projects: [],
                                               stallari: info, isResponding: false, now: at, threads: threads,
                                               chatByThread: ["default": [chat(0, thread: "default")],
                                                              "p1": [chat(1, thread: "p1")],
                                                              "i1": [chat(2, thread: "i1")]])
        let list = records.compactMap { if case .thread(let t) = $0 { t } else { nil } }
        #expect(list.map(\.id) == ["default", "p1", "i1"])
        #expect(list.first?.name == "메인")
        #expect(list.first?.kind == .main)
        #expect(list.last?.issue == "i1")
        #expect(list.last?.working == true)
        #expect(list.first?.messageCount == 1)
    }
}
