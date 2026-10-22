import Foundation
import Testing
@testable import KnarrCore

/// Real saved records from the two named cases: the mobile progress run has 399 verification
/// records and the auto-install run has 428. Every search page is collected to the end and
/// compared with the original ordered ID list, and derived documents/images must exist.
///
/// Runs only with the app database copy: `knarr-efficiency-verify` links this test into a
/// standalone binary pointed at a copy (see docs/evidence/stallari-review-readback-2026-10-22.md).
@Suite(.serialized) struct ReviewSearchRealDataTests {
    static let cases: [(runID: String, records: Int)] = [
        ("hird-05FB280B-9D8D-46F0-A75C-5140933813EA", 399),
        ("hird-EC0D9FBA-7199-47F2-90A9-DE836B1756CA", 428)
    ]

    private static let database: URL? = ProcessInfo.processInfo.environment["KNARR_DB_COPY"]
        .map { URL(fileURLWithPath: $0) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNARR_DB_COPY"] != nil))
    func namedCasesFindEveryRecordAcrossAllPages() async throws {
        let url = try #require(Self.database)
        let repository = try await SQLiteKnarrRepository.open(at: url)
        do {
            let snapshot = try await repository.snapshot(includeHistory: false)
            for expected in Self.cases {
                let run = try #require(snapshot.runs.first { $0.id.rawValue == expected.runID },
                                       "missing run \(expected.runID)")
                let all = try #require(run.result?.verifications)
                #expect(all.count == expected.records, "\(expected.runID) record count")

                // Every page of the default (oldest-first) listing, collected to the end.
                var seen: [String] = []
                var cursor: String?
                var pages = 0
                var pageBytes = 0
                var totalOldPages = 0
                var totalOldBytes = 0
                var offset = 0
                repeat {
                    let page = try StallariReadback.checks(run, query: .init(query: nil, kind: nil, status: nil,
                        since: nil, until: nil, verificationID: nil, order: "oldest", offset: 0, limit: 20),
                        cursorText: cursor)
                    pages += 1
                    pageBytes += try page.jsonLine().count
                    seen += (page["verifications"]?.array ?? []).compactMap { $0["verificationID"]?.string }
                    cursor = page["nextCursor"]?.string
                } while cursor != nil
                repeat {
                    let page = StallariReadback.verifications(run, offset: offset, limit: 20)
                    totalOldPages += 1
                    totalOldBytes += try page.jsonLine().count
                    offset = page["nextOffset"]?.integer ?? all.count
                } while offset < all.count

                // Exact order, no duplicates, nothing missing — for both cases.
                #expect(seen == all.map(\.id), "\(expected.runID) page order and completeness")
                #expect(Set(seen).count == expected.records)
                print("REAL_CASE run=\(expected.runID) records=\(all.count) filterPages=\(pages) " +
                      "filterBytes=\(pageBytes) legacyPages=\(totalOldPages) legacyBytes=\(totalOldBytes) " +
                      "legacyFirstPageBytes=\(try StallariReadback.verifications(run, offset: 0, limit: 20).jsonLine().count)")

                // Failed and exit-code-less records keep reachable original text.
                let failed = all.filter { StallariReadback.facts($0).status == .failed }
                let unknown = all.filter { StallariReadback.facts($0).status == .unknown }
                for record in (failed.prefix(3) + unknown.prefix(3)) {
                    let size = StallariReadback.logSize(record.logPath)
                    // A record with no saved file is itself an unverified finding, not a skip.
                    #expect(size > 0, "\(expected.runID) \(record.id) has no saved log")
                    let text = try StallariReadback.readTail(record.logPath, limit: 1500)
                    #expect(!text.text.isEmpty)
                    #expect(text.total == size)
                }

                // Inspection evidence (documents/images) must be openable and non-blank.
                let inspections = all.filter(\.isInspection)
                #expect(!inspections.isEmpty, "\(expected.runID) has inspection evidence")
                for record in inspections.prefix(5) {
                    let facts = StallariReadback.facts(record)
                    #expect(facts.usableAsProof, "\(record.id) inspection eligibility")
                    let attachments = record.attachmentPaths ?? []
                    if let image = attachments.first {
                        let bytes = try Data(contentsOf: URL(fileURLWithPath: image))
                        #expect(bytes.count > 0)
                    }
                }

                // The saved report must be readable.
                if let report = run.result?.reportPath {
                    #expect(StallariReadback.logSize(report) > 0, "\(expected.runID) report missing")
                    #expect(!(try StallariReadback.readRange(report, offset: 0, limit: 2000)).text.isEmpty)
                } else {
                    Issue.record("\(expected.runID) has no saved report path")
                }
            }
            try await repository.close()
        } catch { try await repository.close(); throw error }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNARR_DB_COPY"] != nil))
    func filteredSearchRecoversAllMatchesAtLowerCostThanFullPaging() async throws {
        let url = try #require(Self.database)
        let repository = try await SQLiteKnarrRepository.open(at: url)
        do {
            let snapshot = try await repository.snapshot(includeHistory: false)
            let run = try #require(snapshot.runs.first { $0.id.rawValue == Self.cases[0].runID })
            let all = try #require(run.result?.verifications)
            let expected = all.filter {
                ($0.command.joined(separator: " ") + " " + $0.summary).lowercased().contains("swift test")
            }
            // Collect every filtered page, so the comparison covers the whole match set.
            var seen: [String] = []
            var bytes = 0
            var pages = 0
            var cursor: String?
            var matchesReported: Int?
            repeat {
                let page = try StallariReadback.checks(run, query: .init(query: "swift test", kind: nil, status: nil,
                    since: nil, until: nil, verificationID: nil, order: "newest", offset: 0, limit: 20), cursorText: cursor)
                pages += 1
                bytes += try page.jsonLine().count
                matchesReported = page["matched"]?.integer
                seen += (page["verifications"]?.array ?? []).compactMap { $0["verificationID"]?.string }
                cursor = page["nextCursor"]?.string
            } while cursor != nil
            #expect(matchesReported == expected.count)
            #expect(seen == expected.map(\.id).reversed())
            #expect(Set(seen).count == seen.count)

            var legacyBytes = 0, legacyPages = 0, offset = 0
            repeat {
                let page = StallariReadback.verifications(run, offset: offset, limit: 20)
                legacyPages += 1
                legacyBytes += try page.jsonLine().count
                offset = page["nextOffset"]?.integer ?? all.count
            } while offset < all.count
            print("REAL_EQUAL_SCOPE matched=\(seen.count) filterPages=\(pages) filterBytes=\(bytes) " +
                  "legacyPages=\(legacyPages) legacyBytes=\(legacyBytes)")
            #expect(pages <= legacyPages)
            try await repository.close()
        } catch { try await repository.close(); throw error }
    }
}
