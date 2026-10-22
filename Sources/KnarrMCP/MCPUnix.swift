import Darwin
import Foundation

/// Raw Unix-domain socket helpers. No TCP, no Bonjour and no tunnel: the only reachable
/// endpoint is a file in the person's private data folder.
public enum MCPUnix {
    public static let lineLimit = 1_048_576

    public struct Address {
        var value: sockaddr_un
        public init?(path: String) {
            guard path.utf8.count <= MCPPaths.maximumSocketPathBytes else { return nil }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: Array(path.utf8))
            }
            value = address
        }
        public var size: socklen_t { socklen_t(MemoryLayout<sockaddr_un>.size) }
    }

    public static func makeSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd >= 0 {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        return fd
    }

    public static func connect(path: String) -> Int32? {
        guard let address = Address(path: path) else { return nil }
        let fd = makeSocket()
        guard fd >= 0 else { return nil }
        var value = address.value
        let rc = withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, address.size)
            }
        }
        guard rc == 0 else { close(fd); return nil }
        return fd
    }

    /// The kernel-reported peer uid; a different user never reaches the app.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var credential = xucred()
        var size = socklen_t(MemoryLayout<xucred>.size)
        let rc = getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credential, &size)
        guard rc == 0 else { return nil }
        return credential.cr_uid
    }

    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var base = raw.baseAddress else { return data.isEmpty }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, base, remaining)
                if written > 0 { remaining -= written; base = base.advanced(by: written); continue }
                if written < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// Calls `onLine` for each newline-terminated message. Returns when the peer closes or a
    /// malformed frame makes the stream unusable.
    public static func readLines(_ fd: Int32, limit: Int = lineLimit,
                          onLine: (Data) throws -> Void) throws {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var pending = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: buffer[0..<count])
            while let index = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<index]
                pending.removeSubrange(pending.startIndex...index)
                // Tolerate CRLF from clients that add it.
                let trimmed = line.last == 0x0D ? line.dropLast() : line[...]
                if trimmed.isEmpty { continue }
                guard trimmed.count <= limit else { throw MCPFramingError.oversized }
                try onLine(Data(trimmed))
            }
            guard pending.count <= limit else { throw MCPFramingError.oversized }
        }
    }
}
