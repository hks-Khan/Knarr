import Foundation
import Testing
@testable import KnarrCore

@Suite struct OMPFrameTests {
    @Test func splitUTF8JSONLAndMultipleLines() throws {
        var decoder = OMPFrameDecoder()
        let bytes = Data("{\"type\":\"event\",\"text\":\"한글\"}\n{\"type\":\"event2\"}\r\n".utf8)
        var frames: [OMPJSON] = []
        for byte in bytes { frames += try decoder.append(Data([byte])) }
        #expect(frames.count == 2)
        #expect(frames.first?["text"]?.string == "한글")
        try decoder.finish()
    }

    @Test func largeLogicalFrameIsInvisibleUntilComplete() throws {
        var decoder = OMPFrameDecoder()
        decoder.allowChunks = true
        let logical = Data("{\"type\":\"response\",\"id\":\"big\",\"text\":\"\(String(repeating: "가", count: 500_000))\"}".utf8)
        let pieces = stride(from: 0, to: logical.count, by: 250_000).map {
            Data(logical[$0..<min($0 + 250_000, logical.count)])
        }
        for (i, piece) in pieces.enumerated() {
            let frame: OMPJSON = .object(["type": .string("rpc_chunk"), "chunkId": .string("c1"),
                "index": .number(Double(i)), "count": .number(Double(pieces.count)),
                "byteLength": .number(Double(logical.count)), "data": .string(piece.base64EncodedString())])
            let result = try decoder.append(try frame.jsonLine())
            #expect(result.count == (i == pieces.count - 1 ? 1 : 0))
            if let result = result.first { #expect(result["id"]?.string == "big") }
        }
        try decoder.finish()
    }

    @Test func rejectsInvalidUTF8AndUnfinishedJSONL() throws {
        var decoder = OMPFrameDecoder()
        #expect(throws: OMPRPCError.self) { try decoder.append(Data([0xff, 10])) }
        decoder = OMPFrameDecoder()
        _ = try decoder.append(Data("{\"type\":\"event\"}".utf8))
        #expect(throws: OMPRPCError.self) { try decoder.finish() }
    }

    @Test func rejectsInterruptedChunkSequenceAndPreNegotiationChunks() throws {
        let chunk: OMPJSON = .object(["type": .string("rpc_chunk"), "chunkId": .string("c1"),
            "index": .number(0), "count": .number(2), "byteLength": .number(1_100_000),
            "data": .string(Data(repeating: 65, count: 250_000).base64EncodedString())])
        var decoder = OMPFrameDecoder()
        #expect(throws: OMPRPCError.self) { try decoder.append(try chunk.jsonLine()) }
        decoder = OMPFrameDecoder()
        decoder.allowChunks = true
        #expect(try decoder.append(try chunk.jsonLine()).isEmpty)
        #expect(throws: OMPRPCError.self) { try decoder.append(Data("{\"type\":\"event\"}\n".utf8)) }
    }

    @Test func physicalLimitStopsUnterminatedGrowth() throws {
        var decoder = OMPFrameDecoder(maxFrameBytes: 64)
        #expect(throws: OMPRPCError.self) { try decoder.append(Data(repeating: 65, count: 64)) }
    }
    @Test(arguments: ["index", "count", "id", "base64", "length", "limit"])
    func rejectsChunkMetadataMismatch(kind: String) throws {
        var decoder = OMPFrameDecoder(); decoder.allowChunks = true
        var fields: [String: OMPJSON] = ["type": .string("rpc_chunk"), "chunkId": .string("c1"),
            "index": .number(0), "count": .number(5), "byteLength": .number(1_100_000),
            "data": .string(Data(repeating: 65, count: 250_000).base64EncodedString())]
        _ = try decoder.append(try OMPJSON.object(fields).jsonLine())
        fields["index"] = .number(1)
        switch kind {
        case "index": fields["index"] = .number(0)
        case "count": fields["count"] = .number(6)
        case "id": fields["chunkId"] = .string("c2")
        case "base64": fields["data"] = .string("??")
        case "length": fields["byteLength"] = .number(1_100_001)
        default: fields["byteLength"] = .number(67_108_865)
        }
        #expect(throws: OMPRPCError.self) { try decoder.append(try OMPJSON.object(fields).jsonLine()) }
        #expect(throws: OMPRPCError.self) { try decoder.finish() }
    }

    @Test func negotiationAndLargeResponseInSameOSRead() throws {
        var decoder = OMPFrameDecoder()
        let logical = Data("{\"type\":\"response\",\"text\":\"\(String(repeating: "a", count: 1_100_000))\"}".utf8)
        let pieces = stride(from: 0, to: logical.count, by: 250_000).map { Data(logical[$0..<min($0 + 250_000, logical.count)]) }
        var bytes = try OMPJSON.object(["type": .string("response"), "id": .string("negotiation"),
            "command": .string("negotiate_protocol"), "success": .bool(true), "data": .object(["protocolVersion": .number(2)])]).jsonLine()
        for (index, piece) in pieces.enumerated() {
            bytes.append(try OMPJSON.object(["type": .string("rpc_chunk"), "chunkId": .string("coalesced"),
                "index": .number(Double(index)), "count": .number(Double(pieces.count)),
                "byteLength": .number(Double(logical.count)), "data": .string(piece.base64EncodedString())]).jsonLine())
        }
        let frames = try decoder.append(bytes, negotiationID: "negotiation")
        #expect(frames.count == 2)
        #expect(frames.last?["text"]?.string?.count == 1_100_000)
    }

}
