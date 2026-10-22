import Foundation
import Testing
@testable import KnarrCore

private actor ThinkingRPC: StallariRPC {
    let levels: [String]
    let observed: String
    var setters = 0
    init(levels: [String], observed: String) { self.levels = levels; self.observed = observed }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON {
        if command == "set_thinking_level" { setters += 1 }
        let data: OMPJSON
        switch command {
        case "get_available_thinking_levels": data = .object(["levels": .array(levels.map(OMPJSON.string))])
        case "get_state": data = .object(["thinkingLevel": .string(observed)])
        default: data = .object([:])
        }
        return .object(["data": data])
    }
    func send(_ command: String, fields: [String: OMPJSON]) async throws {}
    func subscribe() async -> AsyncStream<OMPEvent> { AsyncStream { $0.finish() } }
    func shutdown(cancel: Bool) async -> OMPProcessExit { .init(status: 0, reason: .normal, remainingProcessIDs: []) }
}
@Suite struct ThinkingPolicyTests {
    @Test func unsupportedHighNeverSetsLowerLevel() async throws {
        let rpc = ThinkingRPC(levels: ["off", "medium"], observed: "medium")
        await #expect(throws: StallariThinkingError.self) { try await StallariRuntimePolicy.ensureThinking(rpc: rpc, level: "high") }
        #expect(await rpc.setters == 0)
    }
    @Test func successfulSetterDoesNotHideRuntimeClamp() async throws {
        let rpc = ThinkingRPC(levels: ["off", "high"], observed: "medium")
        await #expect(throws: StallariThinkingError.self) { try await StallariRuntimePolicy.ensureThinking(rpc: rpc, level: "high") }
        #expect(await rpc.setters == 1)
    }
    @Test func actualHighIsReturnedToConsumers() async throws {
        let rpc = ThinkingRPC(levels: ["off", "high"], observed: "high")
        #expect(try await StallariRuntimePolicy.ensureThinking(rpc: rpc, level: "high")["thinkingLevel"]?.string == "high")
    }
}
