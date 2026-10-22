import Foundation
import KnarrCore

/// JSON-RPC envelopes shared by the app-side server and the stdio bridge.
/// Both sides frame one message per line; a message never contains a raw newline.
public enum MCPProtocol {
    public static let maxLineBytes = 1_048_576

    public static func success(id: OMPJSON, result: OMPJSON) -> OMPJSON {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
    public static func failure(id: OMPJSON, code: Int, message: String, data: OMPJSON? = nil) -> OMPJSON {
        var error: [String: OMPJSON] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { error["data"] = data }
        return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(error)])
    }
    /// A request id is a string or a number; notifications have none and never get a reply.
    public static func requestID(_ message: OMPJSON) -> OMPJSON? {
        guard let value = message["id"] else { return nil }
        switch value {
        case .string, .number: return value
        default: return nil
        }
    }
    public static func method(_ message: OMPJSON) -> String? {
        guard message["jsonrpc"]?.string == "2.0" else { return nil }
        return message["method"]?.string
    }
    public static func initializeResult(requested: String?) -> OMPJSON {
        let version = requested.flatMap { MCPToolCatalog.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? MCPToolCatalog.latestProtocolVersion
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object(["name": .string(MCPToolCatalog.serverName),
                                   "title": .string("Knarr"),
                                   "version": .string(MCPToolCatalog.serverVersion)]),
            "instructions": .string(MCPToolCatalog.instructions)
        ])
    }
    public static func toolsListResult() -> OMPJSON {
        .object(["tools": .array(MCPToolCatalog.tools)])
    }

    /// Tool results carry both the JSON payload and one text rendering; refusals are tool
    /// errors (`isError`) so the client can read the structured code.
    public static func toolResult(_ payload: OMPJSON) -> OMPJSON {
        let text = (try? JSONEncoder.sortedString(payload)) ?? "{}"
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "structuredContent": payload,
            "isError": .bool(false)
        ])
    }
    public static func toolError(code: String, message: String, details: OMPJSON? = nil) -> OMPJSON {
        var error: [String: OMPJSON] = ["code": .string(code), "message": .string(message)]
        if let details { error["details"] = details }
        let payload = OMPJSON.object(["ok": .bool(false), "error": .object(error)])
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
            "structuredContent": payload,
            "isError": .bool(true)
        ])
    }

    public static func decode(_ data: Data) throws -> OMPJSON {
        guard data.count <= maxLineBytes else { throw MCPFramingError.oversized }
        return try JSONDecoder().decode(OMPJSON.self, from: data)
    }
    public static func encodeLine(_ message: OMPJSON) throws -> Data {
        var data = try JSONEncoder.sorted.encode(message)
        data.append(0x0A)
        return data
    }
}

public enum MCPFramingError: Error, Equatable {
    case oversized
    case malformed
}

extension OMPJSON {
    /// A JSON object's fields, or nil when the value is anything else.
    var objectFields: [String: OMPJSON]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    static func sortedString(_ value: OMPJSON) throws -> String {
        String(decoding: try JSONEncoder.sorted.encode(value), as: UTF8.self)
    }
}
