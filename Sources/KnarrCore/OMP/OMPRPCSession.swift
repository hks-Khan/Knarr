import Foundation
import Darwin

public struct OMPLaunchConfiguration: Sendable, CustomDebugStringConvertible {
    /// Preserve OMP's official auth environment (PI_CODING_AGENT_DIR/profile/broker).
    /// Hive credentials are attached separately through an app-owned inherited pipe.
    public init(installation: OMPInstallation, workingDirectory: URL, arguments: [String] = ["--mode", "rpc"],
                environment: [String: String] = ProcessInfo.processInfo.environment, handshakeTimeout: Duration = .seconds(20)) {
        self.init(executable: installation.executable, workingDirectory: workingDirectory,
                  arguments: arguments, environment: environment, handshakeTimeout: handshakeTimeout)
    }
    public let executable: URL
    public let workingDirectory: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var handshakeTimeout: Duration
    var hiveCredential: HiveLaunchCredential?
    public var debugDescription: String {
        "OMPLaunchConfiguration(executable: \(executable), workingDirectory: \(workingDirectory), arguments: \(arguments), environment: <redacted>, hiveCredential: \(hiveCredential == nil ? "missing" : "<redacted>"))"
    }
    init(executable: URL, workingDirectory: URL, arguments: [String] = ["--mode", "rpc"],
                environment: [String: String] = ProcessInfo.processInfo.environment, handshakeTimeout: Duration = .seconds(20)) {
        self.executable = executable; self.workingDirectory = workingDirectory
        self.arguments = arguments; self.environment = environment; self.handshakeTimeout = handshakeTimeout
    }
}
public struct OMPProcessExit: Sendable, Equatable {
    public enum Reason: Sendable { case normal, cancelled, failed }
    public let status: Int32
    public let reason: Reason
    public let remainingProcessIDs: [Int32]
}
public enum OMPEvent: Sendable { case frame(OMPJSON), terminated(OMPProcessExit) }
/// A single-use session. Owners must await shutdown on cancellation/app termination.
/// Subscriber work never runs on the receiving loop. Raw frames must not be logged.
public actor OMPRPCSession {
    // OMP 18.7 reads input commands as JSONL; ready.maxFrameBytes bounds its OUTPUT frames.
    // Keep an independent request budget, including JSON/base64 overhead and the newline.
    private static let maxRequestBytes = 64 * 1024 * 1024
    private struct Pending {
        let command: String
        let reply: CheckedContinuation<OMPJSON, any Error>
        let timeout: Task<Void, Never>
    }
    private var process: OwnedOMPProcess?
    private var decoder = OMPFrameDecoder()
    private var pending: [String: Pending] = [:]
    private var subscriptions: [UUID: OMPEventBuffer] = [:]
    private var readyReply: CheckedContinuation<OMPJSON, any Error>?
    private var readyTimeout: Task<Void, Never>?
    private var exitReplies: [CheckedContinuation<OMPProcessExit, Never>] = []
    private var escalation: Task<Void, Never>?
    private var closing = false
    private var cancelled = false
    private var failure: OMPRPCError?
    private var exit: OMPProcessExit?
    private var hasStarted = false
    private let negotiationID = "knarr-protocol-" + UUID().uuidString
    public private(set) var readyFrame: OMPJSON?
    public private(set) var negotiatedVersion: Int?
    public var processID: Int32? { process?.id }

    public init() {}
    deinit {
        // Completed sessions must never signal a PID/group that can later be reused.
        if exit == nil { process?.closeInput(); process?.signalOwnedGroup(SIGTERM); process?.signalOwnedGroup(SIGKILL) }
    }

    public func start(_ configuration: OMPLaunchConfiguration) async throws {
        guard !hasStarted, !closing, exit == nil else { throw OMPRPCError.notRunning }
        hasStarted = true
        do {
            let owned = try OwnedOMPProcess(configuration)
            process = owned
            Task { [weak self, output = owned.output] in
                for await event in output { await self?.consume(event) }
            }
            try await withTaskCancellationHandler {
                let ready = try await awaitReady(timeout: configuration.handshakeTimeout)
                guard ready["protocolVersion"]?.integer == 1,
                      ready["supportedProtocolVersions"]?.array?.contains(.number(2)) == true,
                      let physical = ready["maxFrameBytes"]?.integer, physical > 0, physical <= 1_048_576,
                      let logical = ready["maxReassembledFrameBytes"]?.integer, logical >= physical, logical <= 67_108_864 else {
                    throw OMPRPCError.unsupportedProtocol
                }
                decoder.maxFrameBytes = physical; decoder.maxReassembledFrameBytes = logical
                let response = try await perform("negotiate_protocol", fields: ["protocolVersion": .number(2)],
                    id: negotiationID, timeout: configuration.handshakeTimeout)
                guard response["data"]?["protocolVersion"]?.integer == 2 else { throw OMPRPCError.unsupportedProtocol }
                decoder.allowChunks = true; negotiatedVersion = 2
            } onCancel: { Task { await self.shutdown(cancel: true) } }
        } catch {
            failure = (error as? OMPRPCError) ?? .cancelled
            if process != nil { _ = await shutdown(cancel: Task.isCancelled) }
            else { finish(status: -1, remaining: []) }
            if error is CancellationError { throw OMPRPCError.cancelled }
            throw error
        }
    }

    public func subscribe() -> AsyncStream<OMPEvent> {
        let id = UUID(), buffer = OMPEventBuffer()
        if let exit { buffer.offer(.terminated(exit)); buffer.finish() }
        else { subscriptions[id] = buffer }
        return AsyncStream(unfolding: { await buffer.next() }, onCancel: { [weak self] in
            buffer.cancel()
            Task { await self?.unsubscribe(id) }
        })
    }
    private func unsubscribe(_ id: UUID) { subscriptions.removeValue(forKey: id)?.cancel() }

    /// Payload-free backlog measurements. Critical events are lossless, not hard-capped.
    func eventBufferMetrics() -> [OMPEventBuffer.Metrics] { subscriptions.values.map { $0.metrics() } }

    public func request(_ command: String, fields: [String: OMPJSON] = [:], timeout: Duration = .seconds(10)) async throws -> OMPJSON {
        guard negotiatedVersion == 2, !closing else { throw OMPRPCError.notRunning }
        return try await perform(command, fields: fields, id: UUID().uuidString, timeout: timeout)
    }

    /// Side-channel replies (host_tool_result, extension_ui_response) do not await a response.
    public func send(_ command: String, fields: [String: OMPJSON] = [:]) async throws {
        guard negotiatedVersion == 2, !closing, let process else { throw OMPRPCError.notRunning }
        var object = fields; object["type"] = .string(command)
        let bytes = try OMPJSON.object(object).jsonLine()
        guard bytes.count <= Self.maxRequestBytes else { throw OMPRPCError.requestTooLarge }
        try await process.write(bytes)
    }

    private func perform(_ command: String, fields: [String: OMPJSON], id: String, timeout: Duration) async throws -> OMPJSON {
        try Task.checkCancellation()
        guard !closing, exit == nil, let process else { throw OMPRPCError.notRunning }
        var object = fields; object["type"] = .string(command); object["id"] = .string(id)
        let bytes = try OMPJSON.object(object).jsonLine()
        guard bytes.count <= Self.maxRequestBytes else { throw OMPRPCError.requestTooLarge }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout); await self?.reject(id, error: .timedOut) } catch {}
                }
                pending[id] = Pending(command: command, reply: reply, timeout: timer)
                Task { [weak self] in
                    do { try await process.write(bytes) }
                    catch { await self?.reject(id, error: (error as? OMPRPCError) ?? .ioFailed(-1)) }
                }
            }
        } onCancel: { Task { await self.reject(id, error: .cancelled) } }
    }

    private func awaitReady(timeout: Duration) async throws -> OMPJSON {
        if let readyFrame { return readyFrame }
        if let exit { throw OMPRPCError.processExited(exit.status) }
        return try await withCheckedThrowingContinuation { reply in
            readyReply = reply
            readyTimeout = Task { [weak self] in
                do { try await Task.sleep(for: timeout); await self?.rejectReady(.timedOut) } catch {}
            }
        }
    }
    private func rejectReady(_ error: OMPRPCError) {
        readyTimeout?.cancel(); readyTimeout = nil
        readyReply?.resume(throwing: error); readyReply = nil
    }
    private func reject(_ id: String, error: OMPRPCError) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel(); request.reply.resume(throwing: error)
    }
    private func rejectAll(_ error: OMPRPCError) {
        rejectReady(error)
        for id in Array(pending.keys) { reject(id, error: error) }
    }

    private func consume(_ event: OwnedOMPProcess.Output) {
        switch event {
        case .bytes(let bytes):
            do {
                for frame in try decoder.append(bytes, negotiationID: negotiationID) { try route(frame) }
            } catch { fail((error as? OMPRPCError) ?? .invalidFrame("decode failed")) }
        case .failure(let error): fail(error)
        case .exit(let status, let remaining):
            do { try decoder.finish() } catch { failure = (error as? OMPRPCError) ?? .invalidFrame("EOF") }
            finish(status: status, remaining: remaining)
        }
    }
    private func route(_ frame: OMPJSON) throws {
        if frame["type"]?.string == "ready" {
            guard readyFrame == nil else { throw OMPRPCError.invalidFrame("duplicate ready") }
            readyFrame = frame
            readyTimeout?.cancel(); readyTimeout = nil
            readyReply?.resume(returning: frame); readyReply = nil
        } else if frame["type"]?.string == "response", let id = frame["id"]?.string,
                  let request = pending.removeValue(forKey: id) {
            request.timeout.cancel()
            guard frame["command"]?.string == request.command else {
                request.reply.resume(throwing: OMPRPCError.responseMismatch); throw OMPRPCError.responseMismatch
            }
            guard let success = frame["success"]?.bool else {
                request.reply.resume(throwing: OMPRPCError.invalidFrame("response success flag"))
                throw OMPRPCError.invalidFrame("response success flag")
            }
            if success { request.reply.resume(returning: frame) }
            else { request.reply.resume(throwing: OMPRPCError.remoteFailure) }
        } else {
            for subscriber in subscriptions.values { subscriber.offer(.frame(frame)) }
        }
    }
    private func fail(_ error: OMPRPCError) {
        guard failure == nil else { return }
        failure = error; closing = true; rejectAll(error)
        process?.closeInput(); process?.signalOwnedGroup(SIGTERM)
        escalate(after: .milliseconds(200))
    }
    private func escalate(after delay: Duration) {
        guard escalation == nil else { return }
        escalation = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                await self?.signalTermination()
                try await Task.sleep(for: .milliseconds(200))
                await self?.signalKill()
            } catch {}
        }
    }
    private func signalTermination() { if exit == nil { process?.signalOwnedGroup(SIGTERM) } }
    private func signalKill() { if exit == nil { process?.signalOwnedGroup(SIGKILL) } }

    public func shutdown(cancel: Bool = false) async -> OMPProcessExit {
        if let exit { return exit }
        closing = true
        if cancel { cancelled = true; rejectAll(.cancelled) }
        process?.closeInput()
        if cancel { process?.signalOwnedGroup(SIGTERM) }
        escalate(after: cancel ? .milliseconds(200) : .seconds(2))
        if process == nil { finish(status: -1, remaining: []) }
        return await waitForExit()
    }
    public func waitForExit() async -> OMPProcessExit {
        if let exit { return exit }
        return await withCheckedContinuation { exitReplies.append($0) }
    }
    private func finish(status: Int32, remaining: [Int32]) {
        guard exit == nil else { return }
        let result = OMPProcessExit(status: status,
            reason: cancelled ? .cancelled : (status == 0 && failure == nil && remaining.isEmpty ? .normal : .failed),
            remainingProcessIDs: remaining)
        exit = result; closing = true; escalation?.cancel(); escalation = nil
        process?.closeInput()
        rejectAll(cancelled ? .cancelled : (failure ?? .processExited(status)))
        for subscriber in subscriptions.values { subscriber.offer(.terminated(result)); subscriber.finish() }
        subscriptions.removeAll()
        for reply in exitReplies { reply.resume(returning: result) }
        exitReplies.removeAll()
    }
}

/// Pull-driven delivery using the standard AsyncStream unfolding API. Only adjacent
/// deltas with identical message/block metadata combine; every lifecycle/control
/// boundary remains in FIFO order. Unlike a UI frame timer this also drains offscreen.
/// Critical frames cannot be backpressured here: consumers may await RPC responses
/// carried by the same stdout. Keep them lossless and expose backlog instead.
final class OMPEventBuffer: @unchecked Sendable {
    struct Metrics: Sendable {
        var receivedFrames = 0
        var coalescedFrames = 0
        var queuedFrames = 0
        var peakQueuedFrames = 0
    }
    // KiroCrew's overflow guard motivates bounded batches, not dropping content.
    // Use UTF-8 bytes here, since the transport budget is bytes rather than JS chars.
    static let maxCoalescedBytes = 50_000
    private struct Entry {
        let event: OMPEvent
        var template: OMPJSON?
        var fragments: [String] = []
        var bytes = 0
        init(_ event: OMPEvent) {
            self.event = event
            guard case .frame(.object(var frame)) = event,
                  frame["type"]?.string == "message_update", frame["messageId"]?.string != nil,
                  frame["message"]?["content"] == nil,
                  case .object(var update)? = frame["assistantMessageEvent"],
                  ["text_delta", "thinking_delta"].contains(update["type"]?.string ?? ""),
                  update["contentIndex"]?.integer != nil, let text = update["delta"]?.string else { return }
            update["delta"] = .string(""); frame["assistantMessageEvent"] = .object(update)
            template = .object(frame); fragments = [text]; bytes = text.utf8.count
        }
        func materialize() -> OMPEvent {
            guard case .object(var frame)? = template,
                  case .object(var update)? = frame["assistantMessageEvent"] else { return event }
            update["delta"] = .string(fragments.joined()); frame["assistantMessageEvent"] = .object(update)
            return .frame(.object(frame))
        }
    }
    private let lock = NSLock()
    private var entries: [Entry?] = []
    private var head = 0
    private var waiters: [CheckedContinuation<OMPEvent?, Never>] = []
    private var closed = false
    private var counts = Metrics()

    func offer(_ event: OMPEvent) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        counts.receivedFrames += 1
        if !waiters.isEmpty {
            let reply = waiters.removeFirst()
            lock.unlock(); reply.resume(returning: event); return
        }
        let entry = Entry(event)
        if let template = entry.template, entries.count > head,
           entries[entries.count - 1]?.template == template,
           (entries[entries.count - 1]?.bytes ?? 0) + entry.bytes <= Self.maxCoalescedBytes {
            let index = entries.count - 1
            if entry.bytes > 0 { entries[index]?.fragments.append(contentsOf: entry.fragments) }
            entries[index]?.bytes += entry.bytes
            counts.coalescedFrames += 1
        } else { entries.append(entry) }
        counts.queuedFrames = entries.count - head
        counts.peakQueuedFrames = max(counts.peakQueuedFrames, counts.queuedFrames)
        lock.unlock()
    }
    func next() async -> OMPEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { reply in take(reply) }
        } onCancel: { self.cancel() }
    }
    private func take(_ reply: CheckedContinuation<OMPEvent?, Never>) {
        lock.lock()
        if head < entries.count {
            let entry = entries[head]!
            entries[head] = nil; head += 1
            counts.queuedFrames = entries.count - head
            if head > 64 && head * 2 >= entries.count { entries.removeFirst(head); head = 0 }
            lock.unlock(); reply.resume(returning: entry.materialize())
        } else if closed { lock.unlock(); reply.resume(returning: nil) }
        else { waiters.append(reply); lock.unlock() }
    }
    func finish() {
        lock.lock(); closed = true
        let replies = waiters; waiters.removeAll()
        lock.unlock(); replies.forEach { $0.resume(returning: nil) }
    }
    func cancel() {
        lock.lock(); closed = true; entries.removeAll(); head = 0; counts.queuedFrames = 0
        let replies = waiters; waiters.removeAll()
        lock.unlock(); replies.forEach { $0.resume(returning: nil) }
    }
    func metrics() -> Metrics { lock.withLock { counts } }
}
