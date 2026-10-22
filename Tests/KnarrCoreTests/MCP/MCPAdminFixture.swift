import Foundation
import Testing
@testable import KnarrCore
import KnarrMCP

/// Builds the real app store, Stallari session and admin service over a throwaway database.
/// Nothing here imitates the app: proposal saves, closure and ownership checks run in the
/// same code the screens use.
@MainActor struct MCPAdminFixture {
    let directory: URL
    let preferencesSuite: String
    let repository: SQLiteKnarrRepository
    let rpc: LiveTestRPC
    let hird: LiveTestHird
    let store: LiveKnarrStore
    let service: KnarrAdminService
    let server: MCPServer
    let socketDirectory: URL

    static func make(options: MCPAdminFixtureOptions = .init()) async throws -> Self {
        // Outside the checkout: the fixture database and its WAL files are throwaway.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("knarr-mcp-fixtures/\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try await SQLiteKnarrRepository.open(at: directory.appendingPathComponent("knarr.db"))
        for project in options.projects {
            try await repository.saveProject(project)
        }
        let rpc = options.tamperedRPC ?? LiveTestRPC()
        let hird = options.tamperedHird ?? LiveTestHird()
        let session = StallariSession(repository: repository, rpc: rpc, hird: hird)
        let suite = "knarr-mcp-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        let store = LiveKnarrStore(repository: repository, session: session, rpc: rpc, hird: hird,
                                   preferences: preferences, subscriptionUsage: .init(sample: true))
        // Normal issue conversations still use their own session. The MCP adapter below
        // stays bound to the main session even when an issue belongs to another thread.
        store.setThreadFactory { [weak store] thread in
            guard let store else { throw StallariError.closed }
            return LiveConversation(repository: repository,
                session: StallariSession(repository: repository, rpc: rpc, hird: hird, threadID: thread.id),
                rpc: rpc, hird: hird, threadID: thread.id, preferences: preferences,
                subscriptionUsage: store.subscriptionUsage)
        }
        try await store.connect()
        let service = try #require(store.adminService())
        let server = MCPServer(service: service)
        // A real client negotiates lifecycle before any tool call; do the same here.
        _ = await server.handle(.object(["jsonrpc": .string("2.0"), "id": .number(0),
            "method": .string("initialize"),
            "params": .object(["protocolVersion": .string(MCPToolCatalog.latestProtocolVersion)])]))
        return .init(directory: directory, preferencesSuite: suite, repository: repository, rpc: rpc, hird: hird, store: store,
                     service: service, server: server, socketDirectory: directory)
    }

    func cleanup() async throws {
        let exit = await store.shutdown()
        #expect(exit.remainingProcessIDs.isEmpty)
        try await repository.close()
        UserDefaults(suiteName: preferencesSuite)?.removePersistentDomain(forName: preferencesSuite)
        try FileManager.default.removeItem(at: directory)
    }

    /// A session bound to one conversation, for tests that need the project side of an issue.
    func session(threadID: String) async throws -> StallariSession {
        StallariSession(repository: repository, rpc: rpc, hird: hird, threadID: threadID)
    }

    /// An issue that belongs to a project conversation rather than the app's main one, created
    /// through the same app path the project screens use.
    func projectOriginIssue(projectID: String, key: String) async throws -> KnarrCore.Issue.ID {
        let project = try #require(try await snapshot().projects.first { $0.id == projectID })
        let thread = try await repository.createProjectConversation(projectID: projectID)
        let session = StallariSession(repository: repository, rpc: rpc, hird: hird,
                                      instructionProjectID: projectID, threadID: thread.id)
        let id = KnarrCore.Issue.ID("project-issue-" + key)
        _ = try await session.createIssue(id: id, title: "프로젝트 이슈 \(key)",
            criteria: ["프로젝트 경계"], instruction: "프로젝트 기원 확인", projectID: project.id)
        _ = await session.shutdown()
        return id
    }

    /// One JSON-RPC round trip through the real dispatcher, exactly as the connection handler does.
    func call(_ method: String, _ params: OMPJSON = .object([:]), id: Int = 1) async -> OMPJSON {
        let reply = await server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params
        ]))
        return reply ?? .null
    }

    func tool(_ name: String, _ arguments: OMPJSON, id: Int = 2) async -> OMPJSON {
        await call("tools/call", .object(["name": .string(name), "arguments": arguments]), id: id)
    }

    /// The tool's structured payload, or a testing failure carrying the refusal.
    func payload(_ reply: OMPJSON) throws -> OMPJSON {
        let result = try #require(reply["result"], "no result: \(reply)")
        #expect(result["isError"]?.bool == false, "tool refused: \(result)")
        return try #require(result["structuredContent"])
    }

    func errorCode(_ reply: OMPJSON) throws -> String {
        let result = try #require(reply["result"], "no result: \(reply)")
        #expect(result["isError"]?.bool == true, "expected a refusal: \(result)")
        return try #require(result["structuredContent"]?["error"]?["code"]?.string)
    }

    func snapshot() async throws -> PersistenceSnapshot { try await repository.snapshot(includeHistory: false) }

    func issue(_ id: KnarrCore.Issue.ID) async throws -> KnarrCore.Issue? {
        try await snapshot().issues.first { $0.id == id }
    }
}

struct MCPAdminFixtureOptions {
    var projects: [StoredProject]
    var tamperedRPC: LiveTestRPC?
    var tamperedHird: LiveTestHird?
    init(projects: [StoredProject]? = nil, tamperedRPC: LiveTestRPC? = nil, tamperedHird: LiveTestHird? = nil) {
        self.projects = projects ?? [
            .init(id: "p", name: "Knarr", absolutePath: "/tmp/knarr-fixture"),
            .init(id: "other", name: "다른 프로젝트", absolutePath: "/tmp/knarr-other")
        ]
        self.tamperedRPC = tamperedRPC
        self.tamperedHird = tamperedHird
    }
}
