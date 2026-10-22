import Foundation
import Testing
@testable import KnarrCore

struct ReviewDeliveredBytesTests {
    @Test(arguments: ["range", "tail"]) func hashBelongsToDeliveredBytesEvenIfFileChanges(mode: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-delivered-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("check.log")
        let original = Data("original check\n".utf8), changed = Data("modified check\n".utf8)
        #expect(original.count == changed.count)
        try original.write(to: path)
        let excerpt = try mode == "range" ? StallariReadback.readRange(path.path, offset: 0, limit: 100)
            : StallariReadback.readTail(path.path, limit: 100)
        try changed.write(to: path)
        let segments = StallariReadback.segments(for: excerpt)
        #expect(excerpt.text == String(decoding: original, as: UTF8.self))
        #expect(segments.first?.hash == StallariReview.digest(original))
        let read = StallariReview.Read(verificationID: "v", logPath: path.path, segments: segments,
            fileBytes: original.count, mode: mode, at: .now)
        #expect(!StallariReview.matchesCurrentFile(read) { _, start, end in
            (changed.subdata(in: start..<end), changed.count)
        })
    }
}
