import Foundation
import Testing
@testable import KnarrCore
import KnarrMCP

/// The actual local transport: a Unix-domain socket served by `MCPHost`, spoken to through
/// the same `MCPServer`. Also covers the refusals the person sees when the app is absent.
@Suite(.serialized) struct MCPTransportTests {
    @Test func socketHostServesInitializeListAndCallForTheSameUser() async throws {
        let f = try await MCPAdminFixture.make()
        // macOS caps sun_path at 104 bytes; the fixture workspace path is longer than the
        // real data folder, so tests use a short temporary socket path.
        let socketDirectory = URL(fileURLWithPath: "/tmp/knarr-mcp-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
        let environment = ["KNARR_MCP_SOCKET": socketDirectory.appendingPathComponent("knarr.sock").path]
        let host = try MCPHost(service: f.service, dataDirectory: f.directory, environment: environment)
        do {
            try host.start()
            // Socket I/O stays off the main actor: the service is main-actor isolated, so a
            // blocking read on the main thread would deadlock the very call being awaited.
            let client = try #require(SocketClient(path: host.socketPath))

            let initialized = try await client.ask(.object(["jsonrpc": .string("2.0"), "id": .number(1),
                "method": .string("initialize"), "params": .object(["protocolVersion": .string("2025-06-18")])]))
            #expect(initialized["result"]?["serverInfo"]?["name"]?.string == "knarr")
            try await client.notify(.object([
                "jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))

            let listed = try await client.ask(.object(["jsonrpc": .string("2.0"), "id": .number(2),
                "method": .string("tools/list"), "params": .object([:])]))
            #expect(listed["result"]?["tools"]?.array?.count == MCPToolCatalog.toolNames.count)

            let created = try await client.ask(.object(["jsonrpc": .string("2.0"), "id": .number(3),
                "method": .string("tools/call"), "params": .object([
                    "name": .string("create_issue"),
                    "arguments": .object(["projectID": .string("p"), "idempotencyKey": .string("socket-1"),
                        "title": .string("소켓 경로 이슈"), "criteria": .array([.string("소켓")]),
                        "instruction": .string("소켓 경로 확인")])
                ])]))
            let payload = try #require(created["result"]?["structuredContent"])
            let id = KnarrCore.Issue.ID(try #require(payload["issueID"]?.string))
            #expect(payload["state"]?.string == "awaitingApproval")

            // The app's own snapshot, which the screens render, shows the same record.
            let saved = try #require(try await f.issue(id))
            #expect(saved.title == "소켓 경로 이슈")
            #expect(saved.archivedAt == nil)
            #expect(await f.hird.runs.isEmpty)

            // Two connections are served concurrently and see each other's committed writes.
            let second = try #require(SocketClient(path: host.socketPath))
            // A second connection has its own lifecycle: tools are refused until it negotiates.
            let ungated = try await second.ask(.object([
                "jsonrpc": .string("2.0"), "id": .number(40), "method": .string("tools/list"),
                "params": .object([:])]))
            #expect(ungated["error"]?["code"]?.integer == -32600)
            _ = try await second.ask(.object([
                "jsonrpc": .string("2.0"), "id": .number(41), "method": .string("initialize"),
                "params": .object(["protocolVersion": .string("2025-06-18")])]))
            let seen = try await second.ask(.object([
                "jsonrpc": .string("2.0"), "id": .number(4), "method": .string("tools/call"),
                "params": .object(["name": .string("get_issue"),
                    "arguments": .object(["projectID": .string("p"), "issueID": .string(id.rawValue)])])]))
            #expect(seen["result"]?["structuredContent"]?["issue"]?["title"]?.string == "소켓 경로 이슈")

            // Socket file permissions restrict access to this user.
            let attributes = try FileManager.default.attributesOfItem(atPath: host.socketPath)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            host.stop()
            #expect(!FileManager.default.fileExists(atPath: host.socketPath))
            try await f.cleanup()
        } catch {
            host.stop()
            try await f.cleanup()
            throw error
        }
    }

    @Test func bridgeReportsKnarrNotRunningInsteadOfHangingOrCrashing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-mcp-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("absent.sock").path
        let binary = Self.bridgeBinary()
        try #require(FileManager.default.isExecutableFile(atPath: binary), "build knarr-mcp first: \(binary)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var environment = ProcessInfo.processInfo.environment
        environment["KNARR_MCP_SOCKET"] = socket
        process.environment = environment
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer {
            input.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let reader = output.fileHandleForReading
        let writer = input.fileHandleForWriting

        func ask(_ message: OMPJSON) throws -> OMPJSON {
            var data = try JSONEncoder().encode(message)
            data.append(0x0A)
            writer.write(data)
            let deadline = Date().addingTimeInterval(10)
            var buffer = Data()
            while Date() < deadline {
                if let index = buffer.firstIndex(of: 0x0A) {
                    return try JSONDecoder().decode(OMPJSON.self, from: buffer[..<index])
                }
                var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 100) <= 0 { continue }
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
            throw MCPFramingError.malformed
        }

        let initialize = try ask(.object(["jsonrpc": .string("2.0"), "id": .number(1),
            "method": .string("initialize"), "params": .object(["protocolVersion": .string("2025-06-18")])]))
        #expect(initialize["error"]?["data"]?["code"]?.string == "knarr_unavailable")
        #expect(initialize["error"]?["message"]?.string?.contains("실행 중이 아닙니다") == true)

        let listed = try ask(.object(["jsonrpc": .string("2.0"), "id": .number(2),
            "method": .string("tools/list"), "params": .object([:])]))
        #expect(listed["error"]?["data"]?["code"]?.string == "knarr_unavailable")

        // A malformed line gets a parse error and the server keeps serving.
        writer.write(Data("{not json}\n".utf8))
        let malformed = try ask(.object(["jsonrpc": .string("2.0"), "id": .number(3), "method": .string("ping")]))
        #expect(malformed["error"]?["code"]?.integer == -32700)

        writer.closeFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let log = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(log.contains("socket=\(socket)"))
    }

    @Test func bridgeReportsDisconnectWhenAppQuitsMidSession() async throws {
        let f = try await MCPAdminFixture.make()
        let directory = URL(fileURLWithPath: "/tmp/knarr-mcp-bridge-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("knarr.sock").path
        let host = try MCPHost(service: f.service, dataDirectory: f.directory,
                               environment: ["KNARR_MCP_SOCKET": socket])
        let binary = Self.bridgeBinary()
        try #require(FileManager.default.isExecutableFile(atPath: binary), "build knarr-mcp first: \(binary)")
        do {
            try host.start()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            var environment = ProcessInfo.processInfo.environment
            environment["KNARR_MCP_SOCKET"] = socket
            process.environment = environment
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            try process.run()
            defer {
                input.fileHandleForWriting.closeFile()
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
            let reader = output.fileHandleForReading, writer = input.fileHandleForWriting

            func send(_ message: OMPJSON) throws {
                var data = try JSONEncoder().encode(message)
                data.append(0x0A)
                writer.write(data)
            }
            /// Poll-based so a missing reply fails the test instead of blocking forever.
            func next(timeout: TimeInterval = 10) throws -> OMPJSON {
                var buffer = Data()
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if let index = buffer.firstIndex(of: 0x0A) {
                        return try JSONDecoder().decode(OMPJSON.self, from: buffer[..<index])
                    }
                    var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&descriptor, 1, 100)
                    if ready <= 0 { continue }
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
                throw MCPFramingError.malformed
            }

            try send(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
                "params": .object(["protocolVersion": .string("2025-06-18")])]))
            let initialized = try next()
            #expect(initialized["result"]?["serverInfo"]?["name"]?.string == "knarr")

            try send(.object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/call"),
                "params": .object(["name": .string("list_projects"), "arguments": .object([:])])]))
            let projects = try next()
            #expect(projects["result"]?["isError"]?.bool == false)

            // The app quits: the socket closes and every pending request gets exactly one error.
            host.stop()
            try send(.object(["jsonrpc": .string("2.0"), "id": .number(3), "method": .string("tools/list"),
                "params": .object([:])]))
            let answer = try next()
            #expect(answer["id"]?.integer == 3)
            #expect(answer["error"]?["data"]?["code"]?.string == "knarr_unavailable")

            writer.closeFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            try await f.cleanup()
        } catch {
            host.stop()
            try await f.cleanup()
            throw error
        }
    }

    private static func bridgeBinary() -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent(".build/debug/knarr-mcp").path
    }
}

/// One socket connection whose blocking reads run off the caller's actor.
final class SocketClient: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var buffer = Data()

    init?(path: String) {
        guard let fd = MCPUnix.connect(path: path) else { return nil }
        self.fd = fd
    }
    deinit { shutdown(fd, SHUT_RDWR); close(fd) }

    func notify(_ message: OMPJSON) async throws {
        let fd = self.fd
        let line = try MCPProtocol.encodeLine(message)
        _ = await Task.detached { MCPUnix.writeAll(fd, line) }.value
    }

    func ask(_ message: OMPJSON) async throws -> OMPJSON {
        let fd = self.fd
        let line = try MCPProtocol.encodeLine(message)
        guard await Task.detached(operation: { MCPUnix.writeAll(fd, line) }).value else {
            throw MCPFramingError.malformed
        }
        return try await Task.detached { [self] in
            while true {
                if let index = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<index]
                    buffer.removeSubrange(buffer.startIndex...index)
                    return try MCPProtocol.decode(Data(line))
                }
                var chunk = [UInt8](repeating: 0, count: 65_536)
                let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count <= 0 { throw MCPFramingError.malformed }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }.value
    }
}
