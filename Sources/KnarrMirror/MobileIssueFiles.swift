import Foundation
import ImageIO
import KnarrCore
import KnarrSync
import UniformTypeIdentifiers

/// Reads what the issue detail shows beyond the stored fields: the final report, the saved checks
/// with their exit codes, and the run's screenshots shrunk to a thumbnail the phone can hold.
///
/// The projection runs off the main thread, so the file reads and JPEG encoding never block the
/// screen. A saved file's bytes do not change under a given path while it exists, so a path that
/// was read once is served from memory; a different size or modification date is read again.
enum MobileIssueFiles {
    struct Result {
        var report: String?
        var verifications: [MobileIssue.Verification]?
        var captures: [MobileCapture]?
    }

    /// Thumbnails stay small enough that four of them fit under one CloudKit asset budget.
    static let thumbnailMaxEdge = 640
    static let thumbnailBytes = 180_000
    static let reportLimit = MobileLimits.text
    /// Saved screenshots are a few kilobytes each; this bounds what a long session keeps alive.
    static let cacheLimit = 64

    /// One file's identity on disk: same path, size and modification time means the same bytes.
    private struct Stamp: Hashable {
        var path: String
        var size: Int
        var modified: Date
    }

    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var reports: [Stamp: String?] = [:]
        private var thumbnails: [Stamp: Data?] = [:]
        private var order: [Stamp] = []

        private func stamp(_ url: URL) -> Stamp? {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return Stamp(path: url.path, size: values.fileSize ?? -1, modified: values.contentModificationDate ?? .distantPast)
        }

        private func remember(_ stamp: Stamp) {
            order.append(stamp)
            if order.count > MobileIssueFiles.cacheLimit {
                let drop = order.count - MobileIssueFiles.cacheLimit
                for key in order.prefix(drop) { reports[key] = nil; thumbnails[key] = nil }
                order.removeFirst(drop)
            }
        }

        /// Real disk reads, so a test can prove a repeated snapshot did not touch the file again.
        private(set) var diskReads = 0

        func report(_ url: URL, read: () -> String?) -> String? {
            guard let stamp = stamp(url) else { return read() }
            lock.lock()
            if let cached = reports[stamp] { lock.unlock(); return cached }
            lock.unlock()
            let value = read()
            lock.lock(); reports[stamp] = value; diskReads += 1; remember(stamp); lock.unlock()
            return value
        }

        func thumbnail(_ url: URL, read: () -> Data?) -> Data? {
            guard let stamp = stamp(url) else { return read() }
            lock.lock()
            if let cached = thumbnails[stamp] { lock.unlock(); return cached }
            lock.unlock()
            let value = read()
            lock.lock(); thumbnails[stamp] = value; diskReads += 1; remember(stamp); lock.unlock()
            return value
        }

        /// Drops everything, so a test can prove a second read does not touch the disk again.
        func clear() {
            lock.lock(); reports = [:]; thumbnails = [:]; order = []; diskReads = 0; lock.unlock()
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return order.count
        }
    }

    static let cache = Cache()

    static func read(_ issue: Issue) -> Result {
        guard let result = issue.latestResult else { return .init() }
        let report = result.reportPath.flatMap(readReport)
        let checks = result.verifications.filter { !$0.isInspection }.suffix(12).reversed().map { record in
            MobileIssue.Verification(id: record.id, command: record.command.joined(separator: " "),
                                     exitCode: record.exitCode.map(Int.init), at: record.finishedAt,
                                     summary: record.summary.nilIfEmpty)
        }
        let paths = result.verifications.flatMap { $0.attachmentPaths ?? [] }
        let captures = paths.prefix(MobileLimits.captureCount).compactMap { path -> MobileCapture? in
            guard let data = thumbnail(URL(fileURLWithPath: path)) else { return nil }
            let url = URL(fileURLWithPath: path)
            return MobileCapture(id: url.lastPathComponent, caption: url.deletingPathExtension().lastPathComponent,
                                 width: thumbnailMaxEdge, height: thumbnailMaxEdge, data: data)
        }
        return .init(report: report, verifications: checks.isEmpty ? nil : checks,
                     captures: captures.isEmpty ? nil : captures)
    }

    static func readReport(_ path: String) -> String? {
        cache.report(URL(fileURLWithPath: path)) {
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed.clipped(to: reportLimit)
        }
    }

    /// A JPEG thumbnail of a saved screenshot. Anything unreadable is left out rather than sent whole.
    static func thumbnail(_ url: URL) -> Data? {
        cache.thumbnail(url) { encodeThumbnail(url) }
    }

    private static func encodeThumbnail(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxEdge,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= thumbnailBytes else { return nil }
        return data as Data
    }
}

extension String {
    func nilIfEmptyTrimmed() -> String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
