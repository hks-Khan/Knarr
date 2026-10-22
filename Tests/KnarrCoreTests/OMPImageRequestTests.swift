import Foundation
import CryptoKit
import Testing
@testable import KnarrCore

private let imagePeer = #"""
import sys,json,base64,hashlib
seen=[];side=None
def emit(r,data):
 print(json.dumps(dict(type='response',id=r['id'],command=r['type'],success=True,data=data)),flush=True)
print(json.dumps(dict(type='ready',protocolVersion=1,supportedProtocolVersions=[1,2],maxFrameBytes=1048576,maxReassembledFrameBytes=67108864)),flush=True)
for line in sys.stdin:
 r=json.loads(line);t=r['type'];seen.append(t)
 if t=='negotiate_protocol': emit(r,dict(protocolVersion=2))
 elif t=='inspect_images':
  data=[base64.b64decode(i['data'],validate=True) for i in r['images']]
  emit(r,dict(sizes=[len(x) for x in data],hashes=[hashlib.sha256(x).hexdigest() for x in data],wireBytes=len(line.encode('utf-8'))))
 elif t=='large_side_channel': side=hashlib.sha256(r['data'].encode()).hexdigest()
 else: emit(r,dict(commands=seen,sideHash=side))
"""#

private func imagePayloads() throws -> [Data] {
    if let paths = ProcessInfo.processInfo.environment["KNARR_IMAGE_SEND_FILES"] {
        let urls = try JSONDecoder().decode([String].self, from: Data(paths.utf8))
        return try urls.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    }
    // Match the two failing screenshots' byte counts; this peer tests transport, not image decoding.
    return [Data(repeating: 0xA1, count: 2_636_724), Data(repeating: 0xB2, count: 2_382_619)]
}
private func imageFields(_ data: [Data]) -> [String: OMPJSON] {
    ["images": .array(data.map { .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string($0.base64EncodedString())]) }),
     "message": .string("두 스크린샷과 한글 메시지를 그대로 전달합니다.")]
}
private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@Suite(.serialized) struct OMPImageRequestTests {
    @Test func twoLargeImagesArriveUnchangedAndSessionRemainsUsable() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        try imagePeer.write(to: fixture.directory.appendingPathComponent("fixture.py"), atomically: true, encoding: .utf8)
        let session = OMPRPCSession()
        do {
            try await session.start(fixture.configuration)
            let images = try imagePayloads()
            let response = try await session.request("inspect_images", fields: imageFields(images))
            #expect(response["data"]?["sizes"]?.array == images.map { .number(Double($0.count)) })
            #expect(response["data"]?["hashes"]?.array == images.map { .string(hash($0)) })
            #expect((response["data"]?["wireBytes"]?.integer ?? 0) > 1_048_576)
            #expect(try await session.request("get_state")["success"]?.bool == true)
            #expect(await session.shutdown().remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }
    @Test func largeSideChannelPreservesBytesAndFollowingRequest() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        try imagePeer.write(to: fixture.directory.appendingPathComponent("fixture.py"), atomically: true, encoding: .utf8)
        let session = OMPRPCSession()
        do {
            try await session.start(fixture.configuration)
            let text = String(repeating: "첨부", count: 300_000)
            try await session.send("large_side_channel", fields: ["data": .string(text)])
            let response = try await session.request("get_state")
            #expect(response["data"]?["sideHash"]?.string == hash(Data(text.utf8)))
            #expect(await session.shutdown().remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }
    @MainActor @Test func oversizedRequestExplainsLimitAndNeverReachesPeer() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        try imagePeer.write(to: fixture.directory.appendingPathComponent("fixture.py"), atomically: true, encoding: .utf8)
        let session = OMPRPCSession()
        do {
            try await session.start(fixture.configuration)
            do {
                _ = try await session.request("oversize", fields: ["data": .string(String(repeating: "a", count: 64 * 1024 * 1024))])
                Testing.Issue.record("The oversized request must be rejected before writing")
            } catch {
                #expect(LiveConversation.safeError(error, fallback: "generic failure") == "메시지와 첨부의 전체 전송 용량을 초과했어요. 이미지를 나눠서 보내 주세요.")
            }
            let state = try await session.request("get_state")
            #expect(state["data"]?["commands"]?.array?.contains(.string("oversize")) == false)
            #expect(await session.shutdown().remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil))
struct OMPImageRuntimeTests {
    @Test func installedOMPReadsLargeImageBearingJSONWithoutInvokingModel() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])
        let fixture = try RPCFixture(); defer { fixture.remove() }
        var environment = ProcessInfo.processInfo.environment
        environment["PI_CODING_AGENT_DIR"] = fixture.directory.appendingPathComponent("official-agent").path
        environment["PI_CONFIG_DIR"] = String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1) + fixture.directory.path.dropFirst()
        environment.removeValue(forKey: "OMP_PROFILE"); environment.removeValue(forKey: "PI_PROFILE")
        let session = OMPRPCSession()
        do {
            let install = try OMPInstallation(executable: URL(fileURLWithPath: executable))
            try await session.start(.init(installation: install, workingDirectory: fixture.directory,
                arguments: ["--mode", "rpc", "--no-session", "--no-tools", "--no-lsp", "--no-pty", "--no-extensions", "--no-skills", "--no-rules", "--no-title"], environment: environment))
            // get_state ignores extra fields: exercise the real input parser with exact image bytes, without a provider call.
            let response = try await session.request("get_state", fields: imageFields(try imagePayloads()))
            #expect(response["success"]?.bool == true)
            #expect(response["data"]?["sessionId"]?.string?.isEmpty == false)
            #expect(try await session.request("get_state")["success"]?.bool == true)
            #expect(await session.shutdown().remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }
}
