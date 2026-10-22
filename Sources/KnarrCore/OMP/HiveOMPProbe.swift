import Foundation

/// Safe evidence only. No prompts, response bodies, headers or credentials are persisted.
public struct HiveVerification: Codable, Sendable, Equatable {
    public let requestedModel: String
    public let observedModel: String
    public let thinkingLevel: String
    public let reasoningObserved: Bool
    public let toolResultRoundTrip: Bool
    public let streamSettled: Bool
    public let exitCode: Int32
    public let remainingProcessIDs: [Int32]
}

public enum HiveProbeError: Error, LocalizedError, Equatable {
    case credentialRequired, launchFailed, modelMismatch, toolMismatch, incomplete, timeout, cleanup
    public var errorDescription: String? {
        switch self {
        case .credentialRequired: "Hive 키를 보안 입력 화면에서 먼저 저장해 주세요."
        case .launchFailed: "독립 OMP 연결 검사 프로세스를 시작하지 못했어요."
        case .modelMismatch: "OMP에서 요청한 Hive 모델·high 설정을 확인하지 못했어요."
        case .toolMismatch: "Hive 연결 검사의 도구 왕복이 일치하지 않아요."
        case .incomplete: "Hive 응답·도구 후속 응답·스트림 종료를 모두 확인하지 못했어요."
        case .timeout: "Hive 연결 검사가 제한 시간 안에 끝나지 않았어요."
        case .cleanup: "연결 검사 프로세스의 종료를 확인하지 못했어요."
        }
    }
}

/// A normal OMP client, not an OpenCode agent/proxy. The sole host tool returns a
/// fresh nonce; there is no shell, file access, arbitrary argument echo or key getter.
public enum HiveOMPProbe {
    public static func run(installation: OMPInstallation, runtime: HiveProviderRuntime, root: URL) async throws -> HiveVerification {
        guard runtime.isPrepared else { throw HiveProbeError.credentialRequired }
        let directory = root.appendingPathComponent("probe-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let overlay = directory.appendingPathComponent("probe.yml")
        try StallariTools.discoveryOverlay.write(to: overlay, atomically: true, encoding: .utf8)
        let configuration = try runtime.configure(.init(installation: installation, workingDirectory: directory,
            arguments: ["--mode", "rpc-ui", "--no-ui", "--no-session", "--no-tools", "--no-extensions", "--no-skills", "--no-rules", "--no-lsp", "--no-pty", "--no-title", "--config", overlay.path, "--model", HiveProviderRuntime.modelIdentifier, "--thinking", "high"],
            environment: isolatedEnvironment(in: directory)))
        return try await run(configuration: configuration)
    }

    /// Shared wire validation also exercises each role's actual launch builder in fixtures.
    static func run(configuration: OMPLaunchConfiguration) async throws -> HiveVerification {
        let rpc = OMPRPCSession()
        let nonce = "KNARR_HIVE_TOOL_" + UUID().uuidString
        var failedStage = HiveProbeError.launchFailed
        do {
            let events = await rpc.subscribe()
            try await rpc.start(configuration)
            failedStage = .modelMismatch
            let available = try await rpc.request("get_available_models")["data"]?["models"]?.array ?? []
            guard available.contains(where: { $0["provider"]?.string == "hive" && $0["id"]?.string == "deepseek-ai/deepseek-v4.1-flash-1017" }) else { throw HiveProbeError.modelMismatch }
            _ = try await rpc.request("set_model", fields: ["provider": .string("hive"), "modelId": .string("deepseek-ai/deepseek-v4.1-flash-1017")])
            _ = try await rpc.request("set_thinking_level", fields: ["level": .string("high")])
            let state = try await rpc.request("get_state")["data"] ?? .null
            let observed = (state["model"]?["provider"]?.string ?? "") + "/" + (state["model"]?["id"]?.string ?? "")
            guard observed == HiveProviderRuntime.modelIdentifier, state["thinkingLevel"]?.string == "high" else { throw HiveProbeError.modelMismatch }
            failedStage = .incomplete
            _ = try await rpc.request("set_host_tools", fields: ["tools": .array([.object([
                "name": .string("knarr_hive_probe"), "description": .string("Return the Knarr connection verification nonce. No input or side effects."),
                "loadMode": .string("essential"), "parameters": .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
            ])])])
            _ = try await rpc.request("set_event_filter", fields: ["events": .array([.string("message_end")]), "messageUpdates": .string("delta")])
            let prompt = try await rpc.request("prompt", fields: ["message": .string("Connection verification only. Call knarr_hive_probe exactly once with no arguments. After receiving its result, reply with exactly the nonce returned by the tool. Do not call any other tool.")])
            let progress = try await withThrowingTaskGroup(of: ProbeProgress.self) { group in
                group.addTask { try await consume(events, rpc: rpc, promptID: prompt["id"]?.string, nonce: nonce) }
                group.addTask { try await Task.sleep(for: .seconds(75)); throw HiveProbeError.timeout }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw HiveProbeError.incomplete }
                return first
            }
            let exit = await rpc.shutdown()
            guard exit.status == 0, exit.remainingProcessIDs.isEmpty else { throw HiveProbeError.cleanup }
            return .init(requestedModel: HiveProviderRuntime.modelIdentifier, observedModel: observed, thinkingLevel: "high",
                         reasoningObserved: progress.reasoning, toolResultRoundTrip: true, streamSettled: true,
                         exitCode: exit.status, remainingProcessIDs: exit.remainingProcessIDs)
        } catch {
            _ = await rpc.shutdown(cancel: true)
            // Provider errors can carry arbitrary response text. Never surface it in UI/evidence.
            if let safe = error as? HiveProbeError { throw safe }
            if error is CancellationError { throw CancellationError() }
            throw failedStage
        }
    }

    static func isolatedEnvironment(in directory: URL) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": directory.appendingPathComponent("home").path,
         "PI_CODING_AGENT_DIR": directory.appendingPathComponent("agent").path,
         // PI_CONFIG_DIR is resolved relative to the real home by OMP's dirs.ts.
         "PI_CONFIG_DIR": String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1) + directory.path.dropFirst(),
         "NO_COLOR": "1"]
    }
    private struct ProbeProgress: Sendable { var tool = false; var final = false; var reasoning = false; var completed = false }
    private static func consume(_ events: AsyncStream<OMPEvent>, rpc: OMPRPCSession, promptID: String?, nonce: String) async throws -> ProbeProgress {
        var progress = ProbeProgress()
        for await event in events {
            try Task.checkCancellation()
            guard case .frame(let frame) = event else { throw HiveProbeError.incomplete }
            switch frame["type"]?.string {
            case "host_tool_call":
                guard !progress.tool, frame["toolName"]?.string == "knarr_hive_probe", let id = frame["id"]?.string,
                      frame["arguments"] == .object([:]) else { throw HiveProbeError.toolMismatch }
                progress.tool = true
                try await rpc.send("host_tool_result", fields: ["id": .string(id), "result": .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(nonce)])]), "details": .object([:])])])
            case "message_end":
                let message = frame["message"] ?? frame["event"]?["message"] ?? .null
                if message["role"]?.string == "assistant" {
                    let blocks = message["content"]?.array ?? []
                    progress.reasoning = progress.reasoning || blocks.contains { $0["type"]?.string == "thinking" }
                    if progress.tool, message["stopReason"]?.string == "stop" {
                        let text = blocks.compactMap { $0["text"]?.string }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                        progress.final = text == nonce
                    }
                }
            case "prompt_result":
                guard frame["id"]?.string == promptID else { continue }
                guard frame["status"]?.string == "completed" else { throw HiveProbeError.incomplete }
                progress.completed = true
                if frame["sessionSettled"]?.bool == true {
                    guard progress.tool && progress.final else { throw HiveProbeError.incomplete }
                    return progress
                }
            case "session_settled":
                if progress.completed {
                    guard progress.tool && progress.final else { throw HiveProbeError.incomplete }
                    return progress
                }
            default: break
            }
        }
        throw HiveProbeError.incomplete
    }
}
