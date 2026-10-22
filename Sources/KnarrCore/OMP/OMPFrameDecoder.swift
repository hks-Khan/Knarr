import Foundation

/// OS byte framing and v2 logical framing are deliberately separate.
struct OMPFrameDecoder {
    var allowChunks = false
    var maxFrameBytes = 1_048_576
    var maxReassembledFrameBytes = 67_108_864
    init(maxFrameBytes: Int = 1_048_576) { self.maxFrameBytes = maxFrameBytes }
    private var line = Data()
    private var chunks: Chunks?

    private struct Chunks {
        let id: String
        let count: Int
        let length: Int
        var next = 0
        var data = Data()
    }

    mutating func append(_ bytes: Data, negotiationID: String? = nil) throws -> [OMPJSON] {
        var frames: [OMPJSON] = []
        var start = bytes.startIndex
        for index in bytes.indices where bytes[index] == 10 {
            line.append(bytes[start..<index])
            guard line.count + 1 <= maxFrameBytes else { throw OMPRPCError.invalidFrame("physical limit") }
            if line.last == 13 { line.removeLast() }
            let physical = try Self.parse(line)
            line.removeAll(keepingCapacity: true)
            if let logical = try assemble(physical) {
                frames.append(logical)
                if let negotiationID, logical["id"]?.string == negotiationID,
                   logical["type"]?.string == "response", logical["command"]?.string == "negotiate_protocol",
                   logical["success"]?.bool == true, logical["data"]?["protocolVersion"]?.integer == 2 {
                    allowChunks = true
                }
            }
            start = bytes.index(after: index)
        }
        line.append(bytes[start..<bytes.endIndex])
        guard line.count < maxFrameBytes else { throw OMPRPCError.invalidFrame("physical limit") }
        return frames
    }

    mutating func finish() throws {
        guard line.isEmpty, chunks == nil else { throw OMPRPCError.invalidFrame("incomplete frame at EOF") }
    }

    private static func parse(_ data: Data) throws -> OMPJSON {
        guard String(data: data, encoding: .utf8) != nil,
              let value = try? JSONDecoder().decode(OMPJSON.self, from: data),
              case .object = value else { throw OMPRPCError.invalidFrame("invalid JSON object or UTF-8") }
        return value
    }

    private mutating func assemble(_ frame: OMPJSON) throws -> OMPJSON? {
        guard frame["type"]?.string == "rpc_chunk" else {
            guard chunks == nil else { throw OMPRPCError.invalidFrame("interrupted chunk sequence") }
            return frame
        }
        guard allowChunks, let id = frame["chunkId"]?.string, !id.isEmpty, id.count <= 128,
              let index = frame["index"]?.integer, let count = frame["count"]?.integer,
              let length = frame["byteLength"]?.integer,
              index >= 0, count >= 2, count <= 256, index < count,
              length >= maxFrameBytes, length <= maxReassembledFrameBytes,
              let base64 = frame["data"]?.string, let data = Data(base64Encoded: base64),
              data.base64EncodedString() == base64, data.count <= 262_144 else {
            throw OMPRPCError.invalidFrame("invalid chunk metadata or payload")
        }
        if chunks == nil {
            guard index == 0 else { throw OMPRPCError.invalidFrame("chunk must start at zero") }
            chunks = Chunks(id: id, count: count, length: length)
        }
        guard var pending = chunks, pending.id == id, pending.count == count,
              pending.length == length, pending.next == index else {
            throw OMPRPCError.invalidFrame("chunk sequence mismatch")
        }
        pending.data.append(data)
        pending.next += 1
        guard pending.data.count <= length else { throw OMPRPCError.invalidFrame("chunk length overflow") }
        if pending.next < count { chunks = pending; return nil }
        guard pending.data.count == length else { throw OMPRPCError.invalidFrame("chunk length mismatch") }
        chunks = nil
        let result = try Self.parse(pending.data)
        guard result["type"]?.string != "rpc_chunk" else { throw OMPRPCError.invalidFrame("nested chunk") }
        return result
    }
}
