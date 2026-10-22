import Foundation
import Darwin

public protocol SessionReading: Sendable {
    func query(_ request: OMPJSON) async throws -> OMPJSON
}

public enum SessionAPIError: Error, Sendable, Equatable, LocalizedError {
    case unavailable, invalidRequest, failed(String), timedOut, cancelled, cleanup
    public var errorDescription: String? {
        switch self {
        case .unavailable: "대화 조회 실행 파일 또는 Claude SDK를 찾지 못했어요. 세션 API 설치 설정을 확인해 주세요."
        case .invalidRequest: "대화 공급자, 세션 ID, 조회 범위를 확인해 주세요."
        case .failed(let code): "대화 조회 API가 응답하지 못했어요 (\(code)). 기록이 없다는 뜻은 아니에요."
        case .timedOut: "대화 조회 시간이 초과됐어요. 프로젝트나 조회 개수를 좁혀 주세요."
        case .cancelled: "대화 조회가 취소됐어요."
        case .cleanup: "대화 조회 프로세스의 종료를 확인하지 못했어요."
        }
    }
}

/// Each lookup owns a short-lived bridge and any app-server child. No resident connection or polling.
public struct LocalSessionAPI: SessionReading {
    private let configuration: OMPLaunchConfiguration?
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = Bundle.main.url(forResource: "session-api", withExtension: "mjs")
            ?? Bundle.module.url(forResource: "session-api", withExtension: "mjs")
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        func executable(_ key: String, _ name: String, _ defaults: [String]) -> String? {
            let choices = environment[key].map { [$0] } ?? defaults + paths.map { $0 + "/" + name }
            return choices.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        }
        guard let script, let node = executable("KNARR_NODE_EXECUTABLE", "node", ["/opt/homebrew/bin/node", "/usr/local/bin/node"]) else {
            configuration = nil; return
        }
        var env = environment
        if let codex = executable("KNARR_CODEX_EXECUTABLE", "codex", [home.appendingPathComponent(".local/bin/codex").path, "/opt/homebrew/bin/codex"]) { env["KNARR_CODEX_EXECUTABLE"] = codex }
        let omp = environment["KNARR_OMP_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "omp", withExtension: nil)
            ?? root.appendingPathComponent(".runtime/omp/" + OMPInstallation.version + "/omp")
        env["KNARR_OMP_EXECUTABLE"] = omp.path
        let defaultSDKRoots: [String?] = [
            Bundle.main.resourceURL?.appendingPathComponent("SessionAPI/node_modules/@anthropic-ai/claude-agent-sdk").path,
            root.appendingPathComponent(".runtime/session-api/node_modules/@anthropic-ai/claude-agent-sdk").path,
            home.appendingPathComponent(".local/share/knarr/session-api/node_modules/@anthropic-ai/claude-agent-sdk").path
        ]
        let sdkRoots: [String] = environment["KNARR_CLAUDE_SDK_PATH"].map { [$0] } ?? defaultSDKRoots.compactMap { $0 }
        if let sdk = sdkRoots.first(where: { FileManager.default.fileExists(atPath: $0 + "/package.json") }) { env["KNARR_CLAUDE_SDK_PATH"] = sdk }
        configuration = .init(executable: URL(fileURLWithPath: node), workingDirectory: home, arguments: [script.path], environment: env)
    }
    init(configuration: OMPLaunchConfiguration) { self.configuration = configuration }
    public func query(_ request: OMPJSON) async throws -> OMPJSON {
        guard ["codex", "claude"].contains(request["provider"]?.string ?? ""),
              ["list", "search", "read", "usage"].contains(request["operation"]?.string ?? "") else { throw SessionAPIError.invalidRequest }
        guard var configuration else { throw SessionAPIError.unavailable }
        if request["provider"]?.string == "claude", request["operation"]?.string == "usage" {
            guard let path = configuration.environment["KNARR_OMP_EXECUTABLE"],
                  let installation = try? OMPInstallation(executable: URL(fileURLWithPath: path)) else { throw SessionAPIError.unavailable }
            configuration.environment["KNARR_OMP_EXECUTABLE"] = installation.executable.path
        }
        return try await SessionAPIProcess().run(configuration, request: request)
    }
}

/// Reuses OMP's process ownership/reclamation, but speaks a single JSON request/response to the bridge.
actor SessionAPIProcess {
    private var process: OwnedOMPProcess?
    private var reply: CheckedContinuation<OMPJSON, any Error>?
    private var output = Data()
    private var failure: SessionAPIError?
    private var timer: Task<Void, Never>?
    private var escalation: Task<Void, Never>?
    private(set) var exit: OMPProcessExit?
    private var started = false

    func run(_ configuration: OMPLaunchConfiguration, request: OMPJSON, timeout: Duration = .seconds(65)) async throws -> OMPJSON {
        guard !started else { throw SessionAPIError.invalidRequest }; started = true
        try Task.checkCancellation()
        let bytes = try request.jsonLine()
        guard bytes.count <= 16384 else { throw SessionAPIError.invalidRequest }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply = continuation
                do {
                    let owned = try OwnedOMPProcess(configuration); process = owned
                    Task { for await event in owned.output { self.consume(event) } }
                    Task {
                        do { try await owned.write(bytes); owned.closeInput() }
                        catch { self.stop(.failed("write_failed")) }
                    }
                    timer = Task { do { try await Task.sleep(for: timeout); self.stop(.timedOut) } catch {} }
                } catch { reply = nil; continuation.resume(throwing: SessionAPIError.unavailable) }
            }
        } onCancel: { Task { await self.stop(.cancelled) } }
    }
    private func stop(_ error: SessionAPIError) {
        guard exit == nil else { return }
        if failure == nil { failure = error }
        process?.closeInput(); process?.signalOwnedGroup(SIGTERM)
        if escalation == nil {
            escalation = Task {
                do { try await Task.sleep(for: .milliseconds(250)); if exit == nil { process?.signalOwnedGroup(SIGKILL) } } catch {}
            }
        }
    }
    private func consume(_ event: OwnedOMPProcess.Output) {
        switch event {
        case .bytes(let bytes):
            guard output.count + bytes.count <= 1_048_576 else { stop(.failed("response_too_large")); return }
            output.append(bytes)
        case .failure: stop(.failed("read_failed"))
        case .exit(let status, let remaining):
            timer?.cancel(); escalation?.cancel()
            exit = .init(status: status, reason: failure == .cancelled ? .cancelled : (status == 0 && failure == nil && remaining.isEmpty ? .normal : .failed), remainingProcessIDs: remaining)
            process = nil
            guard let reply else { return }; self.reply = nil
            do {
                guard remaining.isEmpty else { throw SessionAPIError.cleanup }
                if let failure { throw failure }
                guard let frame = try? JSONDecoder().decode(OMPJSON.self, from: output) else { throw SessionAPIError.failed("invalid_response") }
                guard status == 0, frame["ok"]?.bool == true, let result = frame["result"] else {
                    let code = frame["error"]?.string ?? "bridge_failed"
                    let safe = code.count <= 64 && code.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "_") }
                    throw SessionAPIError.failed(safe ? code : "bridge_failed")
                }
                reply.resume(returning: result)
            } catch { reply.resume(throwing: error) }
        }
    }
}
