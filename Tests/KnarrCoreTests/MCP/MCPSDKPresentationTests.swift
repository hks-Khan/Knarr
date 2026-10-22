import AppKit
import SwiftUI
import Testing
@testable import KnarrCore
@testable import KnarrUI
import KnarrMCP

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled && ProcessInfo.processInfo.environment["KNARR_MCP_SDK_TESTS"] == "1"))
struct MCPSDKPresentationTests {
    private func labels(_ node: NSObject) -> [String] {
        func value(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }
        return ["accessibilityLabel", "accessibilityValue"].compactMap { value($0) as? String }
            + ((value("accessibilityChildren") as? [NSObject]) ?? []).flatMap(labels)
    }
    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(predicate())
    }
    private func sdk(_ phase: String, socket: String, directory: URL) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let evidence = root.appendingPathComponent("outputs/qa-candidate/evidence/mcp-sdk/" + directory.lastPathComponent)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let log = evidence.appendingPathComponent(phase + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("Tests/Runtime/mcp-sdk-roundtrip.py").path,
                             phase, root.appendingPathComponent(".build/debug/knarr-mcp").path, socket]
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        for _ in 0..<1800 {
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(!process.isRunning, "SDK timed out")
        let output = try String(contentsOf: log, encoding: .utf8)
        #expect(process.terminationStatus == 0, "\(phase): \(output)")
        try #require(process.terminationStatus == 0)
        print("MCP SDK \(phase): passed")
    }
    private func capture(_ host: NSView, _ name: String) throws {
        guard let root = ProcessInfo.processInfo.environment["KNARR_REVIEW_SCREENSHOTS"] else { return }
        let directory = URL(fileURLWithPath: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }
    @Test func officialSDKMutationsAppearInRealStoreAndNativeCards() async throws {
        let f = try await MCPAdminFixture.make()
        let socketDirectory = URL(fileURLWithPath: "/tmp/knarr-sdk-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
        let environment = ["KNARR_MCP_SOCKET": socketDirectory.appendingPathComponent("knarr.sock").path]
        let host = try MCPHost(service: LazyAdminService { f.store.adminService() }, dataDirectory: f.directory, environment: environment)
        let view = NSHostingView(rootView: IssueCardsView(store: f.store, maximumHeight: 500, open: { _ in }, collapsed: .constant(false))
            .frame(width: 960, height: 500, alignment: .top).background(K.canvas).preferredColorScheme(.light))
        let window = TestWindow.make(size: NSSize(width: 960, height: 500))
        defer { window.contentView = nil; window.close() }
        window.contentView = view; TestWindow.present(window)
        do {
            try host.start()
            try await sdk("create", socket: host.socketPath, directory: f.directory)
            try await settle { labels(view).contains { $0.contains("제안 v1") } }
            #expect(labels(view).contains { $0.contains("MCP 화면 연결 확인") })
            #expect(labels(view).contains { $0.contains("승인 대기") })
            try await sdk("update", socket: host.socketPath, directory: f.directory)
            try await settle { labels(view).contains { $0.contains("제안 v2") } }
            #expect(labels(view).contains { $0.contains("수정한 실행 제안") })
            view.layoutSubtreeIfNeeded(); try capture(view, "mcp-proposal-v2")
            try await sdk("close", socket: host.socketPath, directory: f.directory)
            try await settle { !labels(view).contains { $0.contains("MCP 화면 연결 확인") } }
            let archived = try #require(try await f.snapshot().issues.first { $0.title == "MCP 화면 연결 확인" })
            #expect(archived.archivedAt != nil)
            #expect(archived.proposal?.version == 2)
            #expect(archived.proposalHistory?.count == 2)
            try await sdk("lost", socket: host.socketPath, directory: f.directory)
            host.stop()
            #expect(!FileManager.default.fileExists(atPath: host.socketPath))
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            let service = KnarrAdminService(repository: reopened) { throw KnarrAdminError.unavailable("재전송은 새 실행이 필요하지 않습니다") }
            let restored = try MCPHost(service: service, dataDirectory: f.directory, environment: environment)
            do {
                try restored.start()
                try await sdk("reopen", socket: restored.socketPath, directory: f.directory)
                restored.stop(); try await reopened.close()
            } catch { restored.stop(); try await reopened.close(); throw error }
            #expect(await f.rpc.prompts.isEmpty)
            #expect(await f.hird.runs.isEmpty)
            #expect(try await f.snapshot().issues.count == 2)
            try await f.cleanup()
        } catch { host.stop(); try await f.cleanup(); throw error }
    }
}
