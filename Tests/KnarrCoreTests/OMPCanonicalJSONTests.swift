import Foundation
import Testing
@testable import KnarrCore

@Suite struct OMPCanonicalJSONTests {
    @Test func recursivelyStableWireKeepsArrayOrderAndDetectsChanges() throws {
        let wire: OMPJSON = .object(["z": .array([.string("z"), .string("a")]), "a": .object(["z": .number(1), "a": .bool(true)])])
        #expect(String(decoding: try wire.jsonLine(), as: UTF8.self) == "{\"a\":{\"a\":true,\"z\":1},\"z\":[\"z\",\"a\"]}\n")
        let changed: OMPJSON = .object(["z": .array([.string("a"), .string("z")]), "a": .object(["z": .number(1), "a": .bool(true)])])
        #expect(try changed.jsonLine() != wire.jsonLine())
        #expect(try JSONDecoder().decode(OMPJSON.self, from: wire.jsonLine()) == wire)
    }
    @Test func fullHostToolRosterUsesCanonicalWire() throws {
        let payload: OMPJSON = .object(["type": .string("set_host_tools"), "tools": .array(StallariTools.definitions)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var canonical = try encoder.encode(payload); canonical.append(10)
        #expect(try payload.jsonLine() == canonical)
        if let path = ProcessInfo.processInfo.environment["KNARR_ROSTER_CAPTURE"] {
            try payload.jsonLine().write(to: URL(fileURLWithPath: path))
        }
    }
}
