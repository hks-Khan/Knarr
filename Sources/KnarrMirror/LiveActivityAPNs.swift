import CryptoKit
import Foundation
import KnarrSync

/// Signing happens only on the Mac. The private key is never copied to CloudKit or the phone.
public actor LiveActivityAPNs {
    public struct Configuration: Codable, Sendable {
        public var keyID: String
        public var teamID: String
        public var privateKeyPath: String
        public init(keyID: String, teamID: String, privateKeyPath: String) {
            self.keyID = keyID; self.teamID = teamID; self.privateKeyPath = privateKeyPath
        }
    }
    public enum Failure: Error, Equatable { case invalidConfiguration, invalidToken, response(Int), transport }
    private let config: Configuration
    private let signingKey: P256.Signing.PrivateKey
    private var jwt: (value: String, at: Date)?
    private let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)

    /// Missing configuration leaves foreground activities working. No credentials are bundled in either app.
    public nonisolated static func configured() -> LiveActivityAPNs? {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Knarr/liveactivity-apns.json")
        guard let data = try? Data(contentsOf: file), let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
              let attributes = try? FileManager.default.attributesOfItem(atPath: configuration.privateKeyPath),
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
              let pem = try? String(contentsOfFile: configuration.privateKeyPath, encoding: .utf8),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: pem),
              validIdentifier(configuration.keyID), validIdentifier(configuration.teamID) else { return nil }
        return LiveActivityAPNs(configuration: configuration, privateKey: key)
    }
    private nonisolated static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (48...57).contains($0.value) }
    }
    public init(configuration: Configuration, privateKey: P256.Signing.PrivateKey) {
        config = configuration; signingKey = privateKey
    }
    public func request(for push: LiveActivityPush, now: Date) throws -> URLRequest {
        guard Self.validIdentifier(config.keyID), Self.validIdentifier(config.teamID) else { throw Failure.invalidConfiguration }
        guard (64...512).contains(push.token.utf8.count), push.token.utf8.count % 2 == 0,
              push.token.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidToken }
        let host = push.environment == .sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        var request = URLRequest(url: URL(string: "https://\(host)/3/device/\(push.token)")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.httpBody = try push.payload()
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue("com.kyen.knarr.mobile.push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        request.setValue(push.event == .update && push.content.status == .running ? "5" : "10", forHTTPHeaderField: "apns-priority")
        request.setValue(String(push.timestamp + 300), forHTTPHeaderField: "apns-expiration")
        if push.event != .start { request.setValue(String(("knarr-" + push.sessionID).prefix(64)), forHTTPHeaderField: "apns-collapse-id") }
        request.setValue("bearer " + (try authorization(now: now)), forHTTPHeaderField: "authorization")
        return request
    }
    public func send(_ push: LiveActivityPush) async throws {
        let request = try request(for: push, now: .now)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Failure.transport } // URL errors include the device token in their URL; never propagate them.
        guard let http = response as? HTTPURLResponse else { throw Failure.transport }
        guard http.statusCode == 200 else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            if http.statusCode == 410 || reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic" { throw Failure.invalidToken }
            throw Failure.response(http.statusCode)
        }
    }

    private func authorization(now: Date) throws -> String {
        if let jwt, (0..<3000).contains(now.timeIntervalSince(jwt.at)) { return jwt.value }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": config.keyID], options: .sortedKeys)
        let claims = try JSONSerialization.data(withJSONObject: ["iss": config.teamID, "iat": Int(now.timeIntervalSince1970)], options: .sortedKeys)
        let unsigned = Self.base64URL(header) + "." + Self.base64URL(claims)
        let signature = try signingKey.signature(for: Data(unsigned.utf8))
        let value = unsigned + "." + Self.base64URL(signature.rawRepresentation)
        jwt = (value, now)
        return value
    }
    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
