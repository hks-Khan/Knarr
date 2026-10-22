import Foundation
import CryptoKit
import Darwin

private final class HirdCommandDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    func expire() { lock.withLock { expired = true } }
    var timedOut: Bool { lock.withLock { expired } }
}

extension HirdWorkspace {
    static func diagnostic(root: URL, stage: String, kind: String, failure: String,
                           status: Int32? = nil, timeout: Bool = false, limit: Bool = false,
                           path: URL? = nil, policy: HirdCapturePolicy) -> HirdError {
        func bounded(_ value: String) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }).prefix(policy.maximumDiagnosticFieldBytes))
        }
        let record = HirdWorkspaceDiagnostic(stage: bounded(stage), commandKind: bounded(kind), exitStatus: status,
            timedOut: timeout, outputLimitExceeded: limit,
            pathReference: path.map { HirdSecureFile.hex(SHA256.hash(data: Data($0.path.utf8))) }, failureKind: bounded(failure))
        recordDiagnostic(record, root: root)
        return .workspaceFailure(record)
    }

    /// A diagnostic file holds fixed stage/kind values and a hashed path reference only.
    /// Failing to write it never hides the original outcome. A caller-supplied name is
    /// stable, so a condition that persists across captures does not add one file each time.
    static func recordDiagnostic(_ record: HirdWorkspaceDiagnostic, root: URL, name: String? = nil) {
        let directory = root.appendingPathComponent("workspace-diagnostics")
        guard (try? HirdSecureFile.checkAncestors(directory)) != nil else { return }
        do {
            try HirdSecureFile.createDirectory(directory)
            try HirdSecureFile.write(JSONEncoder().encode(record),
                to: directory.appendingPathComponent((name ?? UUID().uuidString) + ".json"))
        } catch { /* The caller still has the structured outcome. */ }
    }

    static func streamCommand(executable: URL, arguments: [String], at directory: URL, index: URL? = nil,
                              destination: URL, root: URL, stage: String, kind: String,
                              policy: HirdCapturePolicy) async throws -> HirdFileFingerprint {
        try policy.validate()
        let parent: Int32
        do { parent = try HirdSecureFile.openDirectory(destination.deletingLastPathComponent()) }
        catch { throw diagnostic(root: root, stage: stage, kind: kind, failure: "output_parent", path: destination, policy: policy) }
        defer { _ = Darwin.close(parent) }
        let fd = openat(parent, destination.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw diagnostic(root: root, stage: stage, kind: kind, failure: "output_open", path: destination, policy: policy) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_INDEX_FILE", "GIT_DIR", "GIT_WORK_TREE", "GIT_EXTERNAL_DIFF", "GIT_CONFIG_COUNT"] { environment.removeValue(forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        if let index { environment["GIT_INDEX_FILE"] = index.path }
        let process: OwnedOMPProcess
        do { process = try OwnedOMPProcess(.init(executable: executable, workingDirectory: directory, arguments: arguments, environment: environment)) }
        catch { throw diagnostic(root: root, stage: stage, kind: kind, failure: "launch", policy: policy) }
        process.closeInput()
        let state = HirdCommandDeadline()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(policy.streamTimeoutSeconds)); state.expire(); process.signalOwnedGroup(SIGTERM); process.signalOwnedGroup(SIGKILL) }
            catch {}
        }
        defer { deadline.cancel() }
        var hash = SHA256(), count: Int64 = 0
        var exceeded = false, ioFailed = false
        return try await withTaskCancellationHandler {
            for await event in process.output {
                switch event {
                case .bytes(let bytes):
                    count += Int64(bytes.count)
                    if count > policy.maximumCommandBytes { exceeded = true }
                    if exceeded || ioFailed || Task.isCancelled {
                        process.signalOwnedGroup(SIGTERM); process.signalOwnedGroup(SIGKILL)
                    } else {
                        do { try output.write(contentsOf: bytes); hash.update(data: bytes) }
                        catch { ioFailed = true; process.signalOwnedGroup(SIGTERM); process.signalOwnedGroup(SIGKILL) }
                    }
                case .failure:
                    ioFailed = true; process.signalOwnedGroup(SIGTERM); process.signalOwnedGroup(SIGKILL)
                case .exit(let status, let remaining):
                    deadline.cancel()
                    guard status == 0, remaining.isEmpty, !state.timedOut, !exceeded, !ioFailed, !Task.isCancelled else {
                        throw diagnostic(root: root, stage: stage, kind: kind,
                            failure: Task.isCancelled ? "cancelled" : (ioFailed ? "io" : (remaining.isEmpty ? "command" : "cleanup")),
                            status: status, timeout: state.timedOut, limit: exceeded, path: destination, policy: policy)
                    }
                    try output.synchronize()
                    return .init(sha256: HirdSecureFile.hex(hash.finalize()), byteCount: count)
                }
            }
            throw diagnostic(root: root, stage: stage, kind: kind, failure: "stream_closed", timeout: state.timedOut, limit: exceeded, policy: policy)
        } onCancel: { process.signalOwnedGroup(SIGTERM); process.signalOwnedGroup(SIGKILL) }
    }

    static func streamGit(_ arguments: [String], at directory: URL, index: URL? = nil, destination: URL,
                          root: URL, stage: String, kind: String, policy: HirdCapturePolicy? = nil) async throws -> HirdFileFingerprint {
        let policy = try policy ?? HirdCapturePolicy.bundled()
        return try await streamCommand(executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments,
            at: directory, index: index, destination: destination, root: root, stage: stage, kind: kind, policy: policy)
    }

    /// Backwards-compatible bounded metadata projection. Large patch output never uses this API.
    static func git(_ arguments: [String], at directory: URL, index: URL? = nil,
                    policy: HirdCapturePolicy? = nil, diagnosticRoot: URL? = nil, stage: String = "metadata") async throws -> String {
        var policy = try policy ?? HirdCapturePolicy.bundled()
        policy.maximumCommandBytes = policy.maximumMetadataBytes
        policy.streamTimeoutSeconds = policy.metadataTimeoutSeconds
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("hird-git-" + UUID().uuidString)
        try HirdSecureFile.createDirectory(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("stdout")
        _ = try await streamGit(arguments, at: directory, index: index, destination: output,
            root: diagnosticRoot ?? temporary, stage: stage, kind: arguments.first ?? "git", policy: policy)
        return String(decoding: try HirdSecureFile.read(output, limit: policy.maximumMetadataBytes), as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
