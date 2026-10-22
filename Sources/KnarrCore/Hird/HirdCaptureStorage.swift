import Foundation
import CryptoKit
import Darwin

public struct HirdCapturePolicy: Codable, Sendable, Hashable {
    public var metadataTimeoutSeconds: Double
    public var streamTimeoutSeconds: Double
    public var maximumMetadataBytes: Int64
    public var maximumCommandBytes: Int64
    public var maximumArtifactBytes: Int64
    public var maximumTotalArtifactBytes: Int64
    public var maximumArtifactCount: Int
    public var maximumSelectedPaths: Int
    public var maximumPathBytes: Int
    public var maximumManifestBytes: Int64
    public var evidenceRoots: [String]
    public var generatedDirectoryPrefixes: [String]
    public var generatedDirectoryNames: [String]
    public var sensitiveComponents: [String]
    public var sensitivePrefixes: [String]
    public var sensitiveSuffixes: [String]
    public var maximumDiagnosticFieldBytes: Int
    public var sessionArtifactPattern: String
    /// Minimum interval for routine recovery archives; final/background archives bypass it.
    public var checkpointIntervalSeconds: Int
    /// Total capture attempts when the worktree changes while a snapshot is taken.
    public var sourceStabilityAttempts: Int
    public var sourceStabilityRetryDelayMilliseconds: Int

    /// Older capture files have no retry keys; they keep the bundled retry bound.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        metadataTimeoutSeconds = try values.decode(Double.self, forKey: .metadataTimeoutSeconds)
        streamTimeoutSeconds = try values.decode(Double.self, forKey: .streamTimeoutSeconds)
        maximumMetadataBytes = try values.decode(Int64.self, forKey: .maximumMetadataBytes)
        maximumCommandBytes = try values.decode(Int64.self, forKey: .maximumCommandBytes)
        maximumArtifactBytes = try values.decode(Int64.self, forKey: .maximumArtifactBytes)
        maximumTotalArtifactBytes = try values.decode(Int64.self, forKey: .maximumTotalArtifactBytes)
        maximumArtifactCount = try values.decode(Int.self, forKey: .maximumArtifactCount)
        maximumSelectedPaths = try values.decode(Int.self, forKey: .maximumSelectedPaths)
        maximumPathBytes = try values.decode(Int.self, forKey: .maximumPathBytes)
        maximumManifestBytes = try values.decode(Int64.self, forKey: .maximumManifestBytes)
        evidenceRoots = try values.decode([String].self, forKey: .evidenceRoots)
        generatedDirectoryPrefixes = try values.decode([String].self, forKey: .generatedDirectoryPrefixes)
        generatedDirectoryNames = try values.decode([String].self, forKey: .generatedDirectoryNames)
        sensitiveComponents = try values.decode([String].self, forKey: .sensitiveComponents)
        sensitivePrefixes = try values.decode([String].self, forKey: .sensitivePrefixes)
        sensitiveSuffixes = try values.decode([String].self, forKey: .sensitiveSuffixes)
        maximumDiagnosticFieldBytes = try values.decode(Int.self, forKey: .maximumDiagnosticFieldBytes)
        sessionArtifactPattern = try values.decode(String.self, forKey: .sessionArtifactPattern)
        checkpointIntervalSeconds = try values.decodeIfPresent(Int.self, forKey: .checkpointIntervalSeconds)
            ?? JSONDecoder().decode(OMPJSON.self, from: HirdPolicyFiles.resource("capture.json"))["checkpointIntervalSeconds"]!.integer!
        sourceStabilityAttempts = try values.decodeIfPresent(Int.self, forKey: .sourceStabilityAttempts) ?? 3
        sourceStabilityRetryDelayMilliseconds = try values.decodeIfPresent(Int.self, forKey: .sourceStabilityRetryDelayMilliseconds) ?? 250
    }

    static func bundled() throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: HirdPolicyFiles.resource("capture.json"))
        try value.validate(); return value
    }
    func validate() throws {
        guard metadataTimeoutSeconds.isFinite, metadataTimeoutSeconds > 0,
              streamTimeoutSeconds.isFinite, streamTimeoutSeconds > 0,
              maximumMetadataBytes > 0, maximumCommandBytes > 0, maximumArtifactBytes > 0,
              maximumTotalArtifactBytes > 0, maximumArtifactCount > 0, maximumSelectedPaths > 0,
              maximumPathBytes > 0, maximumManifestBytes > 0, maximumDiagnosticFieldBytes > 0,
              checkpointIntervalSeconds > 0,
              (1...10).contains(sourceStabilityAttempts), (0...5_000).contains(sourceStabilityRetryDelayMilliseconds),
              evidenceRoots.allSatisfy(HirdSecureFile.isRelative),
              [generatedDirectoryPrefixes, generatedDirectoryNames, sensitiveComponents, sensitivePrefixes, sensitiveSuffixes]
                .allSatisfy({ !$0.isEmpty && $0.allSatisfy { !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") } }) else { throw HirdError.workspace }
        let safety = try JSONDecoder().decode(Self.self, from: HirdPolicyFiles.resource("capture.json"))
        guard sessionArtifactPattern == safety.sessionArtifactPattern else { throw HirdError.workspace }
        func includes(_ values: [String], _ required: [String]) -> Bool {
            Set(required.map { $0.lowercased() }).isSubset(of: Set(values.map { $0.lowercased() }))
        }
        guard includes(sensitiveComponents, safety.sensitiveComponents), includes(sensitivePrefixes, safety.sensitivePrefixes),
              includes(sensitiveSuffixes, safety.sensitiveSuffixes) else { throw HirdError.workspace }
    }
    func isSensitive(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            let value = component.lowercased()
            return sensitiveComponents.contains { value == $0.lowercased() }
                || sensitivePrefixes.contains { value.hasPrefix($0.lowercased()) }
                || sensitiveSuffixes.contains { value.hasSuffix($0.lowercased()) }
        }
    }
    func isGenerated(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { component in
            generatedDirectoryNames.contains(String(component)) || generatedDirectoryPrefixes.contains { component.hasPrefix($0) }
        }
    }
    func isEvidence(_ path: String) -> Bool { evidenceRoots.contains { path.hasPrefix($0 + "/") } }
}

extension HirdPolicyFiles {
    /// Capture settings are read once per dispatch, independently of OMP's prompt policy.
    func loadCapture() throws -> HirdCapturePolicy {
        try HirdSecureFile.checkAncestors(directory)
        try HirdSecureFile.createDirectory(directory)
        let file = directory.appendingPathComponent("capture.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            do { try HirdSecureFile.write(Self.resource("capture.json"), to: file) }
            catch let error as POSIXError where error.code == .EEXIST {}
        }
        let defaults = try HirdCapturePolicy.bundled()
        let data = try HirdSecureFile.read(file, limit: defaults.maximumManifestBytes)
        let policy = try JSONDecoder().decode(HirdCapturePolicy.self, from: data)
        try policy.validate(); return policy
    }
}

struct HirdFileFingerprint: Codable, Sendable, Equatable {
    let sha256: String
    let byteCount: Int64
}

struct HirdCaptureSnapshot: Sendable, Equatable {
    let files: [String: String]
    var isEmpty: Bool { files.isEmpty }
    func changedFiles(comparedTo other: Self) -> [String] {
        Set(files.keys).union(other.files.keys).filter { files[$0] != other.files[$0] }.sorted()
    }
}

/// Evidence selection stays pure. Skipped entries are reported by a fixed kind
/// (`symlink`, `fifo`, …), never by path or raw error text.
struct HirdEvidenceSelection: Sendable, Equatable {
    let paths: [String]
    let skippedKinds: [String]
}

public struct HirdWorkspaceDiagnostic: Codable, Sendable, Equatable {
    public let stage: String
    public let commandKind: String
    public let exitStatus: Int32?
    public let timedOut: Bool
    public let outputLimitExceeded: Bool
    public let pathReference: String?
    public let failureKind: String
}

enum HirdCaptureFailure: Error { case quota }

/// All worktree reads walk descriptor-relative components with O_NOFOLLOW. No
/// credential content is opened during selection; caller checks policy first.
enum HirdSecureFile {
    static func isRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func checkAncestors(_ url: URL) throws {
        // /tmp and /var are platform aliases. Resolve only that system prefix;
        // every application-owned component still has to be a real directory.
        let path = url.standardizedFileURL.path
        var current = URL(fileURLWithPath: "/")
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component))
            var status = stat()
            if lstat(current.path, &status) != 0 {
                if errno == ENOENT { continue }
                throw HirdError.workspace
            }
            if (status.st_mode & S_IFMT) == S_IFLNK {
                guard current.path == "/var" || current.path == "/tmp" else { throw HirdError.workspace }
            }
        }
    }
    static func openDirectory(_ url: URL, create: Bool = false) throws -> Int32 {
        var path = url.standardizedFileURL.path
        for alias in ["/var", "/tmp"] where path == alias || path.hasPrefix(alias + "/") {
            guard let resolved = realpath(alias, nil) else { throw HirdError.workspace }
            path = String(cString: resolved) + String(path.dropFirst(alias.count))
            free(resolved)
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw HirdError.workspace }
        for component in path.split(separator: "/") {
            var next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if next < 0, errno == ENOENT, create {
                if mkdirat(fd, String(component), S_IRWXU) != 0, errno != EEXIST { _ = Darwin.close(fd); throw HirdError.workspace }
                next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            _ = Darwin.close(fd); fd = next
            guard fd >= 0 else { throw HirdError.workspace }
        }
        return fd
    }
    static func createDirectory(_ url: URL) throws {
        let fd = try openDirectory(url, create: true); _ = Darwin.close(fd)
    }
    static func createFile(_ url: URL) throws -> FileHandle {
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { _ = Darwin.close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func write(_ data: Data, to url: URL) throws {
        let output = try createFile(url); defer { try? output.close() }
        try output.write(contentsOf: data); try output.synchronize()
    }
    static func openRead(root: URL, path: String) throws -> Int32 {
        guard isRelative(path) else { throw HirdError.workspace }
        var fd = try openDirectory(root)
        let components = path.split(separator: "/")
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (index == components.count - 1 ? O_NONBLOCK : O_DIRECTORY)
            let next = openat(fd, String(component), flags)
            _ = Darwin.close(fd); fd = next
            guard fd >= 0 else { throw HirdError.workspace }
        }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { _ = Darwin.close(fd); throw HirdError.workspace }
        return fd
    }
    @discardableResult static func transfer(_ url: URL, to destination: URL? = nil, limit: Int64) throws -> HirdFileFingerprint {
        let fd = try openRead(root: url.deletingLastPathComponent(), path: url.lastPathComponent)
        defer { _ = Darwin.close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0 else { throw HirdError.workspace }
        guard before.st_size <= limit else { throw HirdCaptureFailure.quota }
        var output: Int32 = -1
        if let destination {
            let parent = try openDirectory(destination.deletingLastPathComponent())
            defer { _ = Darwin.close(parent) }
            output = openat(parent, destination.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard output >= 0 else { throw HirdError.workspace }
        }
        defer { if output >= 0 { _ = Darwin.close(output) } }
        var hash = SHA256(), total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw HirdError.workspace }
            if count == 0 { break }
            total += Int64(count); guard total <= limit else { throw HirdCaptureFailure.quota }
            try buffer.withUnsafeBytes { raw in
                let bytes = UnsafeRawBufferPointer(rebasing: raw[..<count])
                hash.update(bufferPointer: bytes)
                if output >= 0 {
                    var offset = 0
                    while offset < count {
                        let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw HirdError.workspace }
                        offset += written
                    }
                }
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, total == before.st_size, before.st_dev == after.st_dev,
              before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw HirdError.workspace }
        if output >= 0, fsync(output) != 0 { throw HirdError.workspace }
        return .init(sha256: hex(hash.finalize()), byteCount: total)
    }
    /// An active numeric tool log has no completion guarantee. Preserve exactly
    /// the size observed on admission, not EOF: a writer may append indefinitely.
    /// Identity and observed size checks reject replacement or observed shrink;
    /// this is a prefix observation, not an atomic snapshot of an arbitrary writer.
    static func transferPrefix(_ url: URL, to destination: URL, limit: Int64) throws -> HirdFileFingerprint {
        let parentURL = url.deletingLastPathComponent()
        let parent = try openDirectory(parentURL)
        defer { _ = Darwin.close(parent) }
        var parentStatus = stat()
        guard fstat(parent, &parentStatus) == 0 else { throw HirdError.workspace }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw HirdError.workspace }
        defer { _ = Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_size >= 0 else { throw HirdError.workspace }
        guard before.st_size <= limit else { throw HirdCaptureFailure.quota }
        let prefixBytes = before.st_size
        var named = stat()
        guard fstatat(parent, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              (named.st_mode & S_IFMT) == S_IFREG, named.st_dev == before.st_dev,
              named.st_ino == before.st_ino, named.st_size >= prefixBytes else { throw HirdError.workspace }
        let output = try createFile(destination)
        defer { try? output.close() }
        let outputFD = output.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var total: Int64 = 0, hash = SHA256()
        while total < prefixBytes {
            var current = stat()
            guard fstat(fd, &current) == 0, current.st_size >= prefixBytes else { throw HirdError.workspace }
            let requested = Int(min(Int64(buffer.count), prefixBytes - total))
            let count = pread(fd, &buffer, requested, off_t(total))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw HirdError.workspace }
            try buffer.withUnsafeBytes { raw in
                let bytes = UnsafeRawBufferPointer(rebasing: raw[..<count])
                hash.update(bufferPointer: bytes)
                var offset = 0
                while offset < count {
                    let written = Darwin.write(outputFD, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw HirdError.workspace }
                    offset += written
                }
            }
            total += Int64(count)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size >= prefixBytes,
              fstatat(parent, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              (named.st_mode & S_IFMT) == S_IFREG, named.st_dev == before.st_dev,
              named.st_ino == before.st_ino, named.st_size >= prefixBytes else { throw HirdError.workspace }
        let reopenedParent = try openDirectory(parentURL)
        defer { _ = Darwin.close(reopenedParent) }
        var currentParent = stat()
        guard fstat(reopenedParent, &currentParent) == 0, currentParent.st_dev == parentStatus.st_dev,
              currentParent.st_ino == parentStatus.st_ino else { throw HirdError.workspace }
        try output.synchronize()
        return .init(sha256: hex(hash.finalize()), byteCount: total)
    }
    static func read(_ url: URL, limit: Int64) throws -> Data {
        let fd = try openRead(root: url.deletingLastPathComponent(), path: url.lastPathComponent)
        defer { _ = Darwin.close(fd) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
            guard Int64(data.count) + Int64(chunk.count) <= limit else { throw HirdError.workspace }
            data.append(chunk)
        }
        return data
    }
    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
}
