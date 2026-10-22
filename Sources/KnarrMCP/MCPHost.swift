import Darwin
import Foundation
import KnarrCore

/// The app owns one private local endpoint. Connections retain their own descriptor identity,
/// so late replies cannot be delivered to a newer connection that reused the descriptor number.
public final class MCPHost: @unchecked Sendable {
    public enum HostError: Error, LocalizedError {
        case pathTooLong, bindFailed(String), unsafeExistingPath
        public var errorDescription: String? {
            switch self {
            case .pathTooLong: "MCP 소켓 경로가 너무 깁니다."
            case .bindFailed(let reason): "MCP 소켓을 열지 못했습니다: \(reason)"
            case .unsafeExistingPath: "MCP 경로에 다른 파일이 있거나 사용자 전용 폴더가 아닙니다."
            }
        }
    }
    public let socketPath: String
    private let service: any KnarrAdminServing
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var generation: UUID?
    private var socketIdentity: (dev_t, ino_t)?
    private var connections: [UUID: Connection] = [:]
    private var listenerExit: DispatchGroup?

    private final class Connection: @unchecked Sendable {
        let id = UUID()
        let fd: Int32
        private let lock = NSLock()
        private var ended = false
        private var closed = false
        init(_ fd: Int32) {
            self.fd = fd
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        func write(_ message: OMPJSON) {
            guard let line = try? MCPProtocol.encodeLine(message) else { return }
            lock.withLock {
                guard !ended, !closed else { return }
                if !MCPUnix.writeAll(fd, line) { ended = true; Darwin.shutdown(fd, SHUT_RDWR) }
            }
        }
        func stop() { lock.withLock {
            guard !ended, !closed else { return }
            ended = true
            Darwin.shutdown(fd, SHUT_RDWR)
        } }
        /// Only the read owner closes its descriptor, after readLines has returned.
        func finish() { lock.withLock {
            guard !closed else { return }
            ended = true; closed = true
            Darwin.close(fd)
        } }
    }

    public init(service: any KnarrAdminServing, dataDirectory: URL,
                environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        socketPath = MCPPaths.socketPath(dataDirectory: dataDirectory, environment: environment)
        self.service = service
        guard socketPath.utf8.count <= MCPPaths.maximumSocketPathBytes else { throw HostError.pathTooLong }
    }

    public func start() throws {
        try lock.withLock {
            guard listenFD < 0 else { return }
            let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw HostError.unsafeExistingPath }
            try prepareSocketFile()
            guard let address = MCPUnix.Address(path: socketPath) else { throw HostError.pathTooLong }
            let fd = MCPUnix.makeSocket()
            guard fd >= 0 else { throw HostError.bindFailed(String(cString: strerror(errno))) }
            var value = address.value
            let bound = withUnsafePointer(to: &value) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, address.size) }
            }
            guard bound == 0 else { let reason = String(cString: strerror(errno)); close(fd); throw HostError.bindFailed(reason) }
            if lstat(socketPath, &info) == 0 { socketIdentity = (info.st_dev, info.st_ino) }
            guard chmod(socketPath, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
                let reason = String(cString: strerror(errno)); close(fd); removeOwnedSocket()
                throw HostError.bindFailed(reason)
            }
            listenFD = fd
            let token = UUID(); generation = token
            let group = DispatchGroup(); listenerExit = group; group.enter()
            let thread = Thread { [self] in
                defer { group.leave() }
                acceptLoop(fd, generation: token)
            }
            thread.name = "knarr.mcp.accept"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    public func stop() {
        let (live, group): ([Connection], DispatchGroup?) = lock.withLock {
            generation = nil
            if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
            let live = Array(connections.values)
            connections.removeAll()
            removeOwnedSocket()
            let group = listenerExit; listenerExit = nil
            return (live, group)
        }
        for connection in live { connection.stop() }
        _ = group?.wait(timeout: .now() + 2)
    }

    /// Never deletes regular files, directories, symlinks, or a socket owned by another user.
    private func prepareSocketFile() throws {
        var info = stat()
        guard lstat(socketPath, &info) == 0 else {
            guard errno == ENOENT else { throw HostError.unsafeExistingPath }
            return
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw HostError.unsafeExistingPath }
        if let live = MCPUnix.connect(path: socketPath) {
            close(live)
            throw HostError.bindFailed("이미 다른 Knarr가 MCP 소켓을 사용 중입니다")
        }
        guard unlink(socketPath) == 0 else { throw HostError.unsafeExistingPath }
    }

    private func removeOwnedSocket() {
        guard let (device, inode) = socketIdentity else { return }
        defer { socketIdentity = nil }
        var info = stat()
        if lstat(socketPath, &info) == 0, info.st_dev == device, info.st_ino == inode,
           info.st_mode & S_IFMT == S_IFSOCK { unlink(socketPath) }
    }

    private func acceptLoop(_ fd: Int32, generation token: UUID) {
        while lock.withLock({ generation == token }) {
            let descriptor = accept(fd, nil, nil)
            if descriptor < 0 { if errno == EINTR { continue }; return }
            guard MCPUnix.peerUID(descriptor) == getuid() else { close(descriptor); continue }
            let connection = Connection(descriptor)
            let accepted = lock.withLock {
                guard generation == token else { return false }
                connections[connection.id] = connection
                return true
            }
            guard accepted else { connection.finish(); return }
            let thread = Thread { [self] in serve(connection) }
            thread.name = "knarr.mcp.connection"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    private func serve(_ connection: Connection) {
        defer {
            connection.finish()
            _ = lock.withLock { connections.removeValue(forKey: connection.id) }
        }
        do {
            let server = MCPServer(service: service)
            try MCPUnix.readLines(connection.fd) { line in
                guard let message = try? MCPProtocol.decode(line) else {
                    connection.write(MCPProtocol.failure(id: .null, code: -32700, message: "Parse error"))
                    return
                }
                Task { [server, connection] in
                    guard let reply = await server.handle(message) else { return }
                    connection.write(reply)
                }
            }
        } catch { /* A framing failure ends only this connection. */ }
    }
}
