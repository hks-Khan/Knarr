import Foundation

public enum StallariRuntimePolicy {
    /// Preserve the current choice; setters run only for an explicit change.
    @discardableResult public static func ensureThinking(rpc: any StallariRPC, level: String? = nil) async throws -> OMPJSON {
        let current = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
        guard let level, current["thinkingLevel"]?.string != level else { return current }
        guard current["isStreaming"]?.bool != true else { throw StallariThinkingError.busy }
        let levels = try await rpc.request("get_available_thinking_levels", fields: [:], timeout: .seconds(10))["data"]?["levels"]?.array?.compactMap(\.string) ?? []
        guard levels.contains(level) else { throw StallariThinkingError.unsupported }
        _ = try await rpc.request("set_thinking_level", fields: ["level": .string(level)], timeout: .seconds(10))
        let state = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
        guard state["thinkingLevel"]?.string == level else { throw StallariThinkingError.unverified }
        return state
    }
    @discardableResult public static func selectModel(_ wanted: String, rpc: any StallariRPC, hird: any HirdAdapter, thinking: String? = nil) async throws -> OMPJSON {
        let parts = wanted.split(separator: "/", maxSplits: 1).map(String.init)
        let models = try await rpc.request("get_available_models", fields: [:], timeout: .seconds(10))["data"]?["models"]?.array ?? []
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              models.contains(where: { $0["provider"]?.string == parts[0] && $0["id"]?.string == parts[1] }) else { throw LiveKnarrError.noSupportedSelectedModel }
        let before = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
        guard before["isStreaming"]?.bool != true else { throw StallariThinkingError.busy }
        _ = try await rpc.request("set_model", fields: ["provider": .string(parts[0]), "modelId": .string(parts[1])], timeout: .seconds(20))
        let state = try await ensureThinking(rpc: rpc, level: thinking)
        guard state["model"]?["provider"]?.string == parts[0], state["model"]?["id"]?.string == parts[1] else { throw LiveKnarrError.noSupportedSelectedModel }
        return state
    }
}
public enum StallariThinkingError: Error, LocalizedError {
    case unsupported, unverified, busy
    public var errorDescription: String? {
        switch self {
        case .unsupported: "이 모델이 지원하지 않는 추론 수준이에요. 지원하는 수준을 선택해 주세요."
        case .unverified: "선택한 추론 수준이 적용되지 않았어요. 설정을 확인해 주세요."
        case .busy: "Stallari가 응답 중이에요. 응답이 끝난 뒤 모델을 변경해 주세요."
        }
    }
}
