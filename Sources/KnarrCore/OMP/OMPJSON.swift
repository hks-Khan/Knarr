import Foundation

public enum OMPJSON: Sendable, Equatable, Codable {
    case object([String: OMPJSON]), array([OMPJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: OMPJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([OMPJSON].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> OMPJSON? { if case .object(let v) = self { v[key] } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var integer: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded() == v, abs(v) < 9_007_199_254_740_992 else { return nil }
        return Int(v)
    }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var array: [OMPJSON]? { if case .array(let v) = self { v } else { nil } }
    public func jsonLine() throws -> Data {
        let encoder = JSONEncoder()
        // Object iteration order changes between processes. Providers cache the exact tool schema prefix.
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self); data.append(10); return data
    }
}

/// Descriptions never include server payloads, stderr, credentials or login URLs.
public enum OMPRPCError: Error, Sendable, Equatable {
    case invalidFrame(String), unsupportedProtocol, notRunning, timedOut, cancelled
    case launchFailed(Int32), ioFailed(Int32), processExited(Int32), remoteFailure, responseMismatch, requestTooLarge
}
