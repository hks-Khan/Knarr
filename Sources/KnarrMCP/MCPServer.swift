import Foundation
import KnarrCore

/// The MCP side of one connection: initialize, tools/list, tools/call and the utility
/// methods MCP clients use. Every tool maps to one `KnarrAdminOperation`; unknown names
/// never reach the app. One instance serves one connection, so lifecycle state is per
/// connection and a client cannot call tools before it negotiated (spec 2025-06-18,
/// lifecycle: no requests before `initialize` completes).
public final class MCPServer: @unchecked Sendable {
    private let service: any KnarrAdminServing
    /// Host connections create a server per accepted socket; this is not shared across clients.
    private let lifecycle = Lifecycle()
    private final class Lifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var initialized = false
        var negotiated: Bool {
            get { lock.lock(); defer { lock.unlock() }; return initialized }
            set { lock.lock(); initialized = newValue; lock.unlock() }
        }
    }

    public init(service: any KnarrAdminServing) {
        self.service = service
    }

    /// Returns nil for notifications (no reply is allowed) and a JSON-RPC message otherwise.
    public func handle(_ message: OMPJSON) async -> OMPJSON? {
        guard let id = MCPProtocol.requestID(message) else {
            // Notifications are accepted and never answered.
            return nil
        }
        guard let method = MCPProtocol.method(message) else {
            return MCPProtocol.failure(id: id, code: -32600, message: "Invalid Request")
        }
        switch method {
        case "initialize":
            guard let params = message["params"], params.objectFields != nil else {
                return MCPProtocol.failure(id: id, code: -32602, message: "initialize requires params")
            }
            lifecycle.negotiated = true
            return MCPProtocol.success(id: id,
                result: MCPProtocol.initializeResult(requested: params["protocolVersion"]?.string))
        case "ping":
            return MCPProtocol.success(id: id, result: .object([:]))
        default:
            // Every other request requires a completed initialize on this connection.
            guard lifecycle.negotiated else {
                return MCPProtocol.failure(id: id, code: -32600,
                    message: "Server not initialized: send initialize first on this connection")
            }
            switch method {
            case "tools/list":
                return MCPProtocol.success(id: id, result: MCPProtocol.toolsListResult())
            case "tools/call":
                return await callTool(id: id, message: message)
            default:
                return MCPProtocol.failure(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private func callTool(id: OMPJSON, message: OMPJSON) async -> OMPJSON {
        guard let params = message["params"], params.objectFields != nil,
              let name = params["name"]?.string else {
            return MCPProtocol.failure(id: id, code: -32602, message: "tools/call requires a tool name")
        }
        guard let operation = KnarrAdminOperation(rawValue: name) else {
            return MCPProtocol.failure(id: id, code: -32602,
                message: "Unknown tool: \(name)", data: .object(["code": .string("unknown_tool")]))
        }
        let arguments = params["arguments"] ?? .object([:])
        do {
            let payload = try await service.adminCall(operation.rawValue, arguments: arguments)
            return MCPProtocol.success(id: id, result: MCPProtocol.toolResult(payload))
        } catch let error as KnarrAdminError {
            return MCPProtocol.success(id: id,
                result: MCPProtocol.toolError(code: error.code, message: error.message,
                                              details: .object(["operation": .string(operation.rawValue)])))
        } catch {
            return MCPProtocol.success(id: id,
                result: MCPProtocol.toolError(code: "unavailable",
                                              message: "Knarr가 요청을 처리하지 못했습니다.",
                                              details: .object(["operation": .string(operation.rawValue)])))
        }
    }
}
