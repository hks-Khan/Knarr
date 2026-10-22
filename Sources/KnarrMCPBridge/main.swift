import Darwin
import Foundation
import KnarrCore
import KnarrMCP

/// Local stdio MCP server for Knarr. This process is the executable an MCP client launches:
/// it speaks MCP on stdin/stdout and forwards each message to the running Knarr app over a
/// Unix-domain socket inside the person's private data folder. It exposes no files or shell.
///
/// When Knarr is not running the bridge stays alive and answers each request with a structured
/// `knarr_unavailable` error, so the client shows a clear reason instead of a crashed server.
/// If the app quits mid-session, outstanding requests get `knarr_disconnected`; the next request
/// reconnects to a freshly started app.
enum BridgeFailure {
    static let unavailable = (code: -32001, name: "knarr_unavailable")
    static let disconnected = (code: -32002, name: "knarr_disconnected")
    static let malformed = (code: -32700, name: "parse_error")
}

let socketPath = MCPPaths.socketPath(dataDirectory: MCPPaths.dataDirectory())
let stdoutLock = NSLock()

func emit(_ message: OMPJSON) {
    guard let line = try? MCPProtocol.encodeLine(message) else { return }
    stdoutLock.lock()
    defer { stdoutLock.unlock() }
    _ = MCPUnix.writeAll(STDOUT_FILENO, line)
}

func log(_ text: String) {
    FileHandle.standardError.write(Data("knarr-mcp: \(text)\n".utf8))
}

func failure(_ id: OMPJSON, _ error: (code: Int, name: String), _ text: String) -> OMPJSON {
    MCPProtocol.failure(id: id, code: error.code, message: text,
                        data: .object(["code": .string(error.name), "socket": .string(socketPath)]))
}

/// One client-to-app connection. Request ids waiting for an app reply are tracked so a broken
/// socket produces exactly one error per outstanding request, never a silent hang.
final class Bridge: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var pending: [String: OMPJSON] = [:]
    private var pumping = false

    init(path: String) { self.path = path }

    /// Opens the socket and starts the reply reader when it is not already running.
    func ensureConnected() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { return true }
        guard let opened = MCPUnix.connect(path: path) else { return false }
        fd = opened
        guard !pumping else { return true }
        pumping = true
        let thread = Thread { [weak self] in self?.pump(opened) }
        thread.name = "knarr-mcp.replies"
        thread.stackSize = 512 * 1024
        thread.start()
        return true
    }

    func send(_ message: OMPJSON, id: OMPJSON?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0, let line = try? MCPProtocol.encodeLine(message) else { return false }
        if let id, let key = Self.key(id) { pending[key] = id }
        guard MCPUnix.writeAll(fd, line) else {
            if let key = id.flatMap(Self.key) { pending.removeValue(forKey: key) }
            return false
        }
        return true
    }

    private func pump(_ handle: Int32) {
        do {
            try MCPUnix.readLines(handle) { line in
                guard let message = try? MCPProtocol.decode(line) else { return }
                if let id = MCPProtocol.requestID(message) {
                    lock.lock()
                    if let key = Self.key(id) { pending.removeValue(forKey: key) }
                    lock.unlock()
                }
                emit(message)
            }
        } catch { /* framing failure is treated as a closed connection */ }

        lock.lock()
        let orphaned = Array(pending.values)
        pending.removeAll()
        if fd == handle {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            fd = -1
        }
        pumping = false
        lock.unlock()

        for id in orphaned {
            emit(failure(id, BridgeFailure.disconnected,
                         "Knarr 앱과의 연결이 끊겼습니다. 앱을 다시 실행한 뒤 요청을 반복해 주세요."))
        }
        log("disconnected socket=\(path) pending=\(orphaned.count)")
    }

    private static func key(_ id: OMPJSON) -> String? {
        switch id {
        case .string(let value): return "s:" + value
        case .number(let value): return "n:" + String(Int(value))
        default: return nil
        }
    }
}

let bridge = Bridge(path: socketPath)
log("socket=\(socketPath)")

func handle(_ line: Data) {
    guard let message = try? MCPProtocol.decode(line) else {
        emit(failure(.null, BridgeFailure.malformed, "JSON-RPC 메시지를 해석하지 못했습니다."))
        return
    }
    let id = MCPProtocol.requestID(message)
    guard bridge.ensureConnected() else {
        if let id {
            emit(failure(id, BridgeFailure.unavailable,
                         "Knarr 앱이 실행 중이 아닙니다. Mac에서 Knarr를 열고 다시 시도해 주세요."))
        }
        return
    }
    // Notifications are forwarded too; only requests are tracked for disconnect replies.
    if !bridge.send(message, id: id), let id {
        emit(failure(id, BridgeFailure.disconnected,
                     "Knarr 앱과의 연결이 끊겼습니다. 앱을 다시 실행한 뒤 요청을 반복해 주세요."))
    }
}

do {
    try MCPUnix.readLines(STDIN_FILENO, onLine: handle)
} catch {
    log("stdin framing failed; exiting")
    exit(2)
}
log("stdin closed; exiting")
exit(0)
