import Darwin
import Foundation

extension HirdWorkspace {
    // OMP's numeric tool-output namespace is flat. Child journals/reports and
    // nested artifact trees are deliberately outside this payload contract.
    static func appendSessionArtifacts(artifacts: inout [HirdArtifact], workspace: RunWorkspace,
                                       root: URL, stage: URL, policy: HirdCapturePolicy) throws {
        guard let path = workspace.ompSessionPath else { return }
        let sessions = URL(fileURLWithPath: path).standardizedFileURL
        guard sessions == root.appendingPathComponent("sessions").standardizedFileURL else { throw HirdError.workspace }
        guard try sessionDirectoryExists(sessions) else { return }
        let matcher = try NSRegularExpression(pattern: policy.sessionArtifactPattern)
        var total = try artifactBytes(artifacts, policy: policy)
        var indexes: [String: Int] = [:]
        for (index, artifact) in artifacts.enumerated() where artifact.role == .sessionArtifact {
            indexes[artifact.sourcePath] = index
        }
        for journal in try sessionNames(in: sessions, policy: policy).sorted() where journal.hasSuffix(".jsonl") {
            let store = sessions.appendingPathComponent(journal).deletingPathExtension()
            guard !policy.isSensitive(store.lastPathComponent) else { throw HirdError.workspace }
            guard try sessionDirectoryExists(store) else { continue }
            for name in try sessionNames(in: store, policy: policy).sorted() where isSessionPayload(name, matcher: matcher) {
                let relative = "sessions/" + store.lastPathComponent + "/" + name
                let existing = indexes[relative]
                let retainedBytes = total - (existing.map { artifacts[$0].byteCount } ?? 0)
                guard HirdSecureFile.isRelative(relative), relative.utf8.count <= policy.maximumPathBytes,
                      !policy.isSensitive(relative) else { throw HirdError.workspace }
                guard existing != nil || artifacts.count < policy.maximumArtifactCount else { throw HirdCaptureFailure.quota }
                let temporary = stage.appendingPathComponent(UUID().uuidString)
                let hash = try HirdSecureFile.transferPrefix(store.appendingPathComponent(name), to: temporary,
                    limit: min(policy.maximumArtifactBytes, policy.maximumTotalArtifactBytes - retainedBytes))
                let artifact = HirdArtifact(role: .sessionArtifact, sourcePath: relative, blobPath: "blobs/" + hash.sha256,
                    sha256: hash.sha256, byteCount: hash.byteCount, captureKind: .observedPrefix)
                let blob = root.appendingPathComponent(artifact.blobPath)
                try HirdSecureFile.createDirectory(blob.deletingLastPathComponent())
                try publish(temporary, as: blob, expected: hash, policy: policy)
                if let existing { artifacts[existing] = artifact }
                else { indexes[relative] = artifacts.count; artifacts.append(artifact) }
                total = retainedBytes + hash.byteCount
            }
        }
    }

    static func validateSessionArtifact(_ artifact: HirdArtifact, policy: HirdCapturePolicy) throws {
        let components = artifact.sourcePath.split(separator: "/", omittingEmptySubsequences: false)
        let matcher = try NSRegularExpression(pattern: policy.sessionArtifactPattern)
        guard artifact.role == .sessionArtifact, artifact.captureKind == .observedPrefix, HirdSecureFile.isRelative(artifact.sourcePath),
              artifact.sourcePath.utf8.count <= policy.maximumPathBytes, !policy.isSensitive(artifact.sourcePath),
              components.count == 3, components[0] == "sessions", !components[1].isEmpty,
              isSessionPayload(String(components[2]), matcher: matcher),
              artifact.blobPath == "blobs/" + artifact.sha256 else { throw HirdError.workspace }
    }

    static func validateSessionArtifactTargets(artifacts: [HirdArtifact], manifestURL _: URL,
                                               destinationRoot: URL, policy: HirdCapturePolicy) throws {
        for artifact in artifacts where artifact.role == .sessionArtifact {
            try validateSessionArtifact(artifact, policy: policy)
            let destination = destinationRoot.appendingPathComponent(artifact.sourcePath)
            try HirdSecureFile.checkAncestors(destination)
            var status = stat()
            if lstat(destination.path, &status) == 0 {
                guard (status.st_mode & S_IFMT) == S_IFREG,
                      try HirdSecureFile.transfer(destination, limit: artifact.byteCount) ==
                        HirdFileFingerprint(sha256: artifact.sha256, byteCount: artifact.byteCount) else { throw HirdError.workspace }
            } else if errno != ENOENT { throw HirdError.workspace }
        }
    }

    static func restoreSessionArtifacts(artifacts: [HirdArtifact], manifestURL: URL,
                                        destinationRoot: URL, policy: HirdCapturePolicy) throws {
        for artifact in artifacts where artifact.role == .sessionArtifact {
            try validateSessionArtifact(artifact, policy: policy)
            let source = manifestURL.deletingLastPathComponent().appendingPathComponent(artifact.blobPath)
            _ = try copySessionPayload(source, to: destinationRoot.appendingPathComponent(artifact.sourcePath),
                expected: .init(sha256: artifact.sha256, byteCount: artifact.byteCount), limit: artifact.byteCount, policy: policy)
        }
    }

    static func copySessionArtifacts(sourceJournal: URL, destinationJournal: URL, policy: HirdCapturePolicy) throws {
        let source = sourceJournal.deletingPathExtension()
        guard try sessionDirectoryExists(source) else { return }
        guard !policy.isSensitive(source.path) else { throw HirdError.workspace }
        let matcher = try NSRegularExpression(pattern: policy.sessionArtifactPattern)
        let names = try sessionNames(in: source, policy: policy).filter { isSessionPayload($0, matcher: matcher) }.sorted()
        guard names.count <= policy.maximumArtifactCount else { throw HirdCaptureFailure.quota }
        var total: Int64 = 0
        for name in names {
            let hash = try copySessionPayload(source.appendingPathComponent(name),
                to: destinationJournal.deletingPathExtension().appendingPathComponent(name), expected: nil,
                limit: min(policy.maximumArtifactBytes, policy.maximumTotalArtifactBytes - total), policy: policy)
            total += hash.byteCount
        }
    }

    private static func copySessionPayload(_ source: URL, to destination: URL,
                                           expected: HirdFileFingerprint?, limit: Int64,
                                           policy: HirdCapturePolicy) throws -> HirdFileFingerprint {
        guard !policy.isSensitive(source.path), !policy.isSensitive(destination.path) else { throw HirdError.workspace }
        try HirdSecureFile.createDirectory(destination.deletingLastPathComponent())
        var status = stat()
        if lstat(destination.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFREG else { throw HirdError.workspace }
            let existing = try HirdSecureFile.transfer(destination, limit: limit)
            guard expected == nil || expected == existing else { throw HirdError.workspace }
            return existing
        }
        guard errno == ENOENT else { throw HirdError.workspace }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".session-payload-" + UUID().uuidString)
        defer {
            if let parent = try? HirdSecureFile.openDirectory(temporary.deletingLastPathComponent()) {
                _ = unlinkat(parent, temporary.lastPathComponent, 0); _ = Darwin.close(parent)
            }
        }
        let actual = try expected == nil
            ? HirdSecureFile.transferPrefix(source, to: temporary, limit: limit)
            : HirdSecureFile.transfer(source, to: temporary, limit: limit)
        guard expected == nil || expected == actual else { throw HirdError.workspace }
        try publish(temporary, as: destination, expected: actual, policy: policy)
        return actual
    }

    private static func isSessionPayload(_ name: String, matcher: NSRegularExpression) -> Bool {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return matcher.firstMatch(in: name, range: range)?.range == range
    }

    private static func sessionDirectoryExists(_ url: URL) throws -> Bool {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            if errno == ENOENT { return false }
            throw HirdError.workspace
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR else { throw HirdError.workspace }
        return true
    }

    private static func sessionNames(in directory: URL, policy: HirdCapturePolicy) throws -> [String] {
        let fd = try HirdSecureFile.openDirectory(directory)
        guard let stream = fdopendir(fd) else { _ = Darwin.close(fd); throw HirdError.workspace }
        defer { _ = closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw HirdError.workspace }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard names.count < policy.maximumSelectedPaths, name.utf8.count <= policy.maximumPathBytes else { throw HirdCaptureFailure.quota }
            names.append(name)
        }
    }
}
