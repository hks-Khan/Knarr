import CryptoKit
import Foundation
import KnarrSync
import Testing
@testable import KnarrMirror

@Suite struct LiveActivityAPNsTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    func push(environment: MobileActivityDevice.Environment = .sandbox) -> LiveActivityPush {
        let issue = MobileIssue(id: "t", title: "이슈", project: "p", state: .running, group: .working, headline: "", detail: "",
                               criteria: [], progress: nil, startedAt: at, updatedAt: at)
        return .init(event: .start, token: String(repeating: "a", count: 64), environment: environment,
                     content: LiveActivitySummary.make(issues: [issue], questions: [])!, sessionID: "s", timestamp: 1800000000)
    }
    @Test func requestIsSignedAndTargetsOnlyAPNs() async throws {
        let key = P256.Signing.PrivateKey()
        let sender = LiveActivityAPNs(configuration: .init(keyID: "ABCDEFGHIJ", teamID: "0123456789", privateKeyPath: "unused"), privateKey: key)
        let request = try await sender.request(for: push(), now: at)
        #expect(request.url?.host == "api.sandbox.push.apple.com")
        #expect(request.url?.path == "/3/device/" + String(repeating: "a", count: 64))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apns-topic") == "com.kyen.knarr.mobile.push-type.liveactivity")
        #expect(request.value(forHTTPHeaderField: "apns-push-type") == "liveactivity")
        #expect(request.value(forHTTPHeaderField: "apns-priority") == "10")
        let bearer = try #require(request.value(forHTTPHeaderField: "authorization"))
        let jwt = bearer.dropFirst(7).split(separator: ".").map(String.init)
        #expect(jwt.count == 3)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(jwt[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data((jwt[0] + "." + jwt[1]).utf8)))
        let claims = try #require(try JSONSerialization.jsonObject(with: decode(jwt[1])) as? [String: Any])
        #expect(claims["iat"] as? Int == 1800000000)
        #expect(try await sender.request(for: push(environment: .production), now: at).url?.host == "api.push.apple.com")
    }
    @Test func providerJWTIsReusedAndRotatedAfterFiftyMinutes() async throws {
        let sender = LiveActivityAPNs(configuration: .init(keyID: "ABCDEFGHIJ", teamID: "0123456789", privateKeyPath: "unused"), privateKey: .init())
        let first = try await sender.request(for: push(), now: at).value(forHTTPHeaderField: "authorization")
        let next = try await sender.request(for: push(), now: at.addingTimeInterval(60)).value(forHTTPHeaderField: "authorization")
        let rotated = try await sender.request(for: push(), now: at.addingTimeInterval(3100)).value(forHTTPHeaderField: "authorization")
        #expect(first != nil)
        #expect(first == next)
        #expect(first != rotated)
    }
    @Test func malformedDeviceTokenCannotBecomeAURL() async throws {
        let sender = LiveActivityAPNs(configuration: .init(keyID: "ABCDEFGHIJ", teamID: "0123456789", privateKeyPath: "unused"), privateKey: .init())
        var invalid = push(); invalid.token = "../../other?secret=x"
        await #expect(throws: LiveActivityAPNs.Failure.invalidToken) { try await sender.request(for: invalid, now: at) }
    }
    func decode(_ text: String) throws -> Data {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return try #require(Data(base64Encoded: value))
    }
}
