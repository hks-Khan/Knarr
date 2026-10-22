import Darwin
import Foundation
import Testing
@testable import KnarrCore
import KnarrMCP

@Suite(.serialized) struct MCPEndpointOwnershipTests {
    @Test func failedSecondHostStopCannotRemoveTheFirstSocket() async throws {
        let f = try await MCPAdminFixture.make()
        let dir = URL(fileURLWithPath: "/tmp/knarr-endpoint-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["KNARR_MCP_SOCKET": dir.appendingPathComponent("knarr.sock").path]
        let first = try MCPHost(service: f.service, dataDirectory: f.directory, environment: env)
        let second = try MCPHost(service: f.service, dataDirectory: f.directory, environment: env)
        do {
            try first.start()
            #expect(throws: (any Error).self) { try second.start() }
            second.stop()
            #expect(FileManager.default.fileExists(atPath: first.socketPath))
            first.stop()
            try await f.cleanup()
        } catch { first.stop(); second.stop(); try await f.cleanup(); throw error }
    }
    @Test func existingOrdinaryFileIsPreserved() async throws {
        let f = try await MCPAdminFixture.make()
        let dir = URL(fileURLWithPath: "/tmp/knarr-endpoint-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("knarr.sock")
        try Data("keep me".utf8).write(to: path)
        let host = try MCPHost(service: f.service, dataDirectory: f.directory,
                               environment: ["KNARR_MCP_SOCKET": path.path])
        do {
            #expect(throws: (any Error).self) { try host.start() }
            host.stop()
            #expect((try? String(contentsOf: path, encoding: .utf8)) == "keep me")
            try await f.cleanup()
        } catch { host.stop(); try await f.cleanup(); throw error }
    }
    @Test func longDataDirectoriesHaveSeparatePrivateFallbacks() {
        let a = MCPPaths.socketPath(dataDirectory: URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 120)), environment: [:])
        let b = MCPPaths.socketPath(dataDirectory: URL(fileURLWithPath: "/tmp/" + String(repeating: "b", count: 120)), environment: [:])
        #expect(a != b)
        #expect(URL(fileURLWithPath: a).deletingLastPathComponent().path != "/tmp")
        #expect(a.utf8.count <= 100)
    }
}
