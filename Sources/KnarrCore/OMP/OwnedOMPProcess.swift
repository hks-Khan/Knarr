import Foundation
import Darwin

/// One posix_spawn-created process group. No name-based process discovery or kills.
final class OwnedOMPProcess: @unchecked Sendable {
    enum Output: Sendable { case bytes(Data), failure(OMPRPCError), exit(Int32, [Int32]) }
    let id: Int32
    let output: AsyncStream<Output>
    private let inputLock = NSLock()
    private let identityLock = NSLock()
    private struct Identity { let seconds: UInt64; let microseconds: UInt64 }
    private var observed: [Int32: Identity] = [:]
    private var inspectionFailed = false
    private let writes = DispatchQueue(label: "Knarr.OMP.stdin")
    private var input: Int32
    private let startedSeconds: UInt64

    init(_ config: OMPLaunchConfiguration) throws {
        startedSeconds = UInt64(Date().timeIntervalSince1970)
        var inputPipe: [Int32] = [0,0], outputPipe: [Int32] = [0,0], errorPipe: [Int32] = [0,0]
        var opened: [Int32] = []
        defer { opened.forEach { _ = Darwin.close($0) } }
        func checked(_ result: Int32) throws {
            guard result == 0 else { throw OMPRPCError.launchFailed(result) }
        }
        func makePipe() throws -> [Int32] {
            var fds: [Int32] = [0,0]
            guard pipe(&fds) == 0 else { throw OMPRPCError.ioFailed(errno) }
            opened += fds
            for index in fds.indices {
                // Never let dup/close actions alias stdio or the dedicated child
                // descriptor, even if the parent originally had those slots free.
                if fds[index] <= STDERR_FILENO || fds[index] == 198 {
                    let original = fds[index]
                    let moved = fcntl(original, F_DUPFD_CLOEXEC, 199)
                    guard moved >= 0 else { throw OMPRPCError.ioFailed(errno) }
                    opened.append(moved)
                    _ = Darwin.close(original); opened.removeAll { $0 == original }
                    fds[index] = moved
                }
                guard fcntl(fds[index], F_SETFD, FD_CLOEXEC) == 0 else { throw OMPRPCError.ioFailed(errno) }
            }
            return fds
        }
        inputPipe = try makePipe(); outputPipe = try makePipe(); errorPipe = try makePipe()
        var credentialInput: Int32?
        if let credential = config.hiveCredential {
            guard !credential.bytes.isEmpty, credential.bytes.count <= 4095 else { throw HiveProviderError.invalidCredential }
            let secretPipe = try makePipe()
            // Fill BEFORE spawning, with a nonblocking bounded write. A failed or
            // non-reading executable can never deadlock startup or retain a writer.
            guard fcntl(secretPipe[1], F_SETFL, O_NONBLOCK) == 0,
                  fcntl(secretPipe[1], F_SETNOSIGPIPE, 1) == 0 else { throw OMPRPCError.ioFailed(errno) }
            let written = credential.bytes.withUnsafeBytes { raw in
                var result: Int
                repeat { result = Darwin.write(secretPipe[1], raw.baseAddress!, raw.count) } while result < 0 && errno == EINTR
                return result
            }
            guard written == credential.bytes.count else { throw OMPRPCError.ioFailed(written < 0 ? errno : EIO) }
            _ = Darwin.close(secretPipe[1]); opened.removeAll { $0 == secretPipe[1] }
            credentialInput = secretPipe[0]
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO))
        if let credentialInput { try checked(posix_spawn_file_actions_adddup2(&actions, credentialInput, 198)) }
        for fd in opened { try checked(posix_spawn_file_actions_addclose(&actions, fd)) }
        try checked(config.workingDirectory.path.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) })
        // Foundation/Swift executor threads can have SIGCHLD blocked after Process use.
        // Never inherit that thread-local mask into OMP's native shell child reaper.
        var childMask = sigset_t(); sigemptyset(&childMask)
        try checked(posix_spawnattr_setsigmask(&attributes, &childMask))
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK)))
        try checked(posix_spawnattr_setpgroup(&attributes, 0)) // Child PID becomes a unique group ID.
        let argv = ([config.executable.path] + config.arguments).map { strdup($0) } + [nil]
        let env = config.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let result = config.executable.path.withCString { path in
            argv.withUnsafeBufferPointer { args in env.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, path, &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: envp.baseAddress!))
            } }
        }
        guard result == 0 else { throw OMPRPCError.launchFailed(result) }
        id = pid; input = inputPipe[1]
        _ = fcntl(input, F_SETNOSIGPIPE, 1)
        _ = fcntl(input, F_SETFL, O_NONBLOCK)
        // These three descriptors transfer to the process/input/output owners.
        opened.removeAll { $0 == inputPipe[1] || $0 == outputPipe[0] || $0 == errorPipe[0] }
        let reader = OMPOutputReader(outputPipe[0])
        output = AsyncStream(unfolding: { await reader.next() })
        let drained = DispatchGroup()
        drained.enter()
        drainErrorOutput(errorPipe[0], drained: drained, reader: reader)
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            var waited: pid_t
            repeat { waited = waitpid(id, &status, 0) } while waited == -1 && errno == EINTR
            let exitStatus: Int32 = waited == -1 ? -1 : ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
            // An exited parent can leave inherited pipe descriptors in its children.
            // Reclaim the exclusively created group before awaiting pipe EOF.
            signalOwnedGroup(SIGTERM)
            if !remaining().isEmpty { usleep(100_000); signalOwnedGroup(SIGKILL) }
            for _ in 0..<100 {
                if remaining().isEmpty { break }
                usleep(10_000)
            }
            drained.wait()
            reader.complete(.exit(exitStatus, remaining()))
        }
    }

    func write(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, any Error>) in
            writes.async { [self] in
                inputLock.lock()
                let fd = input >= 0 ? fcntl(input, F_DUPFD_CLOEXEC, 3) : -1
                inputLock.unlock()
                guard fd >= 0 else { reply.resume(throwing: OMPRPCError.notRunning); return }
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                defer { _ = Darwin.close(fd) }
                do {
                    let deadline = ContinuousClock.now + .seconds(2)
                    try bytes.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            inputLock.lock(); let closed = input < 0; inputLock.unlock()
                            guard !closed else { throw OMPRPCError.notRunning }
                            let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                            if written < 0 && errno == EINTR { continue }
                            if written < 0 && errno == EAGAIN {
                                guard ContinuousClock.now < deadline else { throw OMPRPCError.timedOut }
                                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                                _ = poll(&descriptor, 1, 50)
                                continue
                            }
                            guard written > 0 else { throw OMPRPCError.ioFailed(errno) }
                            offset += written
                        }
                    }
                    reply.resume()
                } catch { reply.resume(throwing: error) }
            }
        }
    }

    func closeInput() {
        inputLock.lock(); defer { inputLock.unlock() }
        if input >= 0 { observeDescendants(); _ = Darwin.close(input); input = -1 }
    }

    func signalOwnedGroup(_ signal: Int32) {
        observeDescendants()
        let group = members()
        if !group.isEmpty { _ = kill(-id, signal) }
        identityLock.lock(); let owned = observed; identityLock.unlock()
        for (pid, identity) in owned {
            // Native OMP shells can create their own groups. Signal only descendants
            // captured while still attached to this root, with the same birth identity.
            guard let info = Self.info(pid), info.pbi_start_tvsec == identity.seconds,
                  info.pbi_start_tvusec == identity.microseconds, info.pbi_pgid != UInt32(id) else { continue }
            _ = kill(pid, signal)
        }
    }

    private static func info(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return bytes == MemoryLayout<proc_bsdinfo>.size ? info : nil
    }

    private func list(_ type: UInt32, value: UInt32) -> [Int32] {
        let size = proc_listpids(type, value, nil, 0)
        guard size > 0 else {
            if kill(-id, 0) == 0 { identityLock.lock(); inspectionFailed = true; identityLock.unlock() }
            return []
        }
        var pids = [Int32](repeating: 0, count: Int(size) / MemoryLayout<Int32>.size + 64)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(type, value, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<Int32>.size).filter { $0 > 0 })
    }

    private func remember(_ infos: [Int32: proc_bsdinfo]) {
        identityLock.lock(); defer { identityLock.unlock() }
        for (pid, info) in infos {
            observed[pid] = Identity(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
        }
    }

    private func observeDescendants() {
        // Teardown-time snapshot only. No polling while a session is idle or waiting on a person.
        guard getpgid(id) == id else { return }
        var infos: [Int32: proc_bsdinfo] = [:]
        for pid in list(UInt32(PROC_ALL_PIDS), value: 0) {
            if let info = Self.info(pid), info.pbi_start_tvsec >= startedSeconds { infos[pid] = info }
        }
        var owned: Set<Int32> = [id]
        var changed = true
        while changed {
            changed = false
            for (pid, info) in infos where owned.contains(Int32(info.pbi_ppid)) && !owned.contains(pid) {
                owned.insert(pid); changed = true
            }
        }
        remember(infos.filter { owned.contains($0.key) })
    }

    private func members() -> [Int32] {
        var group: [Int32: proc_bsdinfo] = [:]
        for pid in list(UInt32(PROC_PGRP_ONLY), value: UInt32(id)) {
            if let info = Self.info(pid), info.pbi_pgid == UInt32(id), info.pbi_start_tvsec >= startedSeconds {
                group[pid] = info
            }
        }
        remember(group)
        return Array(group.keys)
    }

    private func remaining() -> [Int32] {
        _ = members()
        identityLock.lock(); let owned = observed; let failed = inspectionFailed; identityLock.unlock()
        let alive = owned.compactMap { pid, identity -> Int32? in
            if let info = Self.info(pid) {
                return info.pbi_start_tvsec == identity.seconds && info.pbi_start_tvusec == identity.microseconds ? pid : nil
            }
            // Zombies can vanish from libproc's group list before launchd reaps them.
            // Do not report cleanup complete while their recorded PID still exists.
            return kill(pid, 0) == 0 || errno == EPERM ? pid : nil
        }
        return alive.sorted() + (failed ? [-1] : [])
    }

    private func drainErrorOutput(_ fd: Int32, drained: DispatchGroup, reader: OMPOutputReader) {
        DispatchQueue.global(qos: .utility).async {
            defer { _ = Darwin.close(fd); drained.leave() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count < 0 { reader.recordFailure(.ioFailed(errno)) }
                guard count > 0 else { return }
                // stderr is drained but never retained: it can contain tokens/login URLs.
            }
        }
    }
}

/// Standard AsyncStream pull production bounds application-owned raw stdout to
/// one 64 KiB read. The OS pipe supplies backpressure; no Task-per-read or byte
/// queue can grow behind a busy RPC actor. Blocking read/wait stays off executors.
private final class OMPOutputReader: @unchecked Sendable {
    private let reads = DispatchQueue(label: "Knarr.OMP.stdout", qos: .utility)
    private let exitReady = DispatchSemaphore(value: 0)
    private let exitLock = NSLock()
    private var terminal: OwnedOMPProcess.Output?
    private var readFailure: OMPRPCError?
    // Only the serial reads queue accesses fd/deliveredExit.
    private var fd: Int32
    private var deliveredExit = false
    private var exitArrived = false
    init(_ fd: Int32) { self.fd = fd }
    deinit { if fd >= 0 { _ = Darwin.close(fd) } }

    func recordFailure(_ error: OMPRPCError) { exitLock.withLock { readFailure = error } }
    func complete(_ result: OwnedOMPProcess.Output) {
        exitLock.withLock { terminal = result }
        exitReady.signal()
    }
    func next() async -> OwnedOMPProcess.Output? {
        await withCheckedContinuation { reply in
            reads.async { [self] in
                if deliveredExit { reply.resume(returning: nil); return }
                if fd >= 0 {
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    var count: Int
                    repeat { count = Darwin.read(fd, &buffer, buffer.count) } while count < 0 && errno == EINTR
                    if count > 0 { reply.resume(returning: .bytes(Data(buffer.prefix(count)))); return }
                    let failure = count < 0 ? errno : nil
                    _ = Darwin.close(fd); fd = -1
                    if let failure { reply.resume(returning: .failure(.ioFailed(failure))); return }
                }
                // Deliver all stdout bytes before exit, even when the child died earlier.
                // The waitpid worker reclaims descendants before signalling this result.
                if !exitArrived { exitReady.wait(); exitArrived = true }
                let failure = exitLock.withLock { let value = readFailure; readFailure = nil; return value }
                if let failure { reply.resume(returning: .failure(failure)); return }
                deliveredExit = true
                reply.resume(returning: exitLock.withLock { terminal })
            }
        }
    }
}
