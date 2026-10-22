import Foundation

/// Owned by one phone; kept in the user's private CloudKit database. Never log token fields.
public struct MobileActivityDevice: Codable, Sendable, Hashable, Identifiable {
    public enum Environment: String, Codable, Sendable { case sandbox, production }
    public var id: String
    public var environment: Environment
    public var enabled: Bool
    public var startToken: String?
    public var activityID: String?
    public var updateToken: String?
    public var dismissedAt: Date?
    public var content: LiveActivitySummary?
    public var updatedAt: Date
    public init(id: String, environment: Environment, enabled: Bool, startToken: String? = nil, activityID: String? = nil,
                updateToken: String? = nil, dismissedAt: Date? = nil, content: LiveActivitySummary? = nil, updatedAt: Date) {
        self.id = id; self.environment = environment; self.enabled = enabled; self.startToken = startToken
        self.activityID = activityID; self.updateToken = updateToken; self.dismissedAt = dismissedAt
        self.content = content; self.updatedAt = updatedAt
    }
}

public struct LiveActivityPush: Sendable {
    public enum Event: String, Codable, Sendable { case start, update, end }
    public var event: Event
    public var token: String
    public var environment: MobileActivityDevice.Environment
    public var content: LiveActivitySummary
    public var sessionID: String
    public var timestamp: Int
    public init(event: Event, token: String, environment: MobileActivityDevice.Environment, content: LiveActivitySummary,
                sessionID: String, timestamp: Int) {
        self.event = event; self.token = token; self.environment = environment; self.content = content
        self.sessionID = sessionID; self.timestamp = timestamp
    }
    public func payload() throws -> Data {
        struct APS: Encodable {
            var timestamp: Int
            var event: String
            var content: LiveActivitySummary
            var staleDate: Int?
            var dismissalDate: Int?
            var attributesType: String?
            var attributes: KnarrActivityAttributes?
            var alert: [String: String]?
            enum CodingKeys: String, CodingKey {
                case timestamp, event, attributes, alert
                case content = "content-state", staleDate = "stale-date", dismissalDate = "dismissal-date", attributesType = "attributes-type"
            }
        }
        struct Envelope: Encodable { var aps: APS }
        let aps = APS(timestamp: timestamp, event: event.rawValue, content: content,
                      staleDate: event == .end ? nil : timestamp + 900,
                      dismissalDate: event == .end ? timestamp + 60 : nil,
                      attributesType: event == .start ? "KnarrActivityAttributes" : nil,
                      attributes: event == .start ? KnarrActivityAttributes(sessionID: sessionID) : nil,
                      alert: event == .start ? ["title": "Knarr", "body": "맡긴 작업의 진행 상황을 표시해요"] : nil)
        // ActivityKit requires the default Codable date strategy, unlike our CloudKit records.
        let encoded = try JSONEncoder().encode(Envelope(aps: aps))
        guard encoded.count <= 4096 else { throw PayloadError.tooLarge }
        return encoded
    }
    public enum PayloadError: Error { case tooLarge }
}

/// Persisted by the Mac. A reserved start is not repeated after an ambiguous network failure.
public struct LiveActivityDeliveryPlan: Codable, Sendable {
    public var lastContent: LiveActivitySummary?
    public var lastToken: String?
    public var lastEvent: LiveActivityPush.Event?
    public var pendingStartToken: String?
    public var invalidToken: String?
    public var lastTimestamp: Int = 0
    public init() {}
    public func next(device: MobileActivityDevice, summary: LiveActivitySummary?, now: Date) -> LiveActivityPush? {
        guard device.enabled else { return nil }
        let timestamp = max(Int(now.timeIntervalSince1970), lastTimestamp + 1)
        if let id = device.activityID {
            guard let token = device.updateToken, token != invalidToken else { return nil }
            if let summary {
                guard lastContent != summary || lastToken != token || lastEvent != .update else { return nil }
                return .init(event: .update, token: token, environment: device.environment, content: summary, sessionID: id, timestamp: timestamp)
            }
            guard lastEvent != .end || lastToken != token, let previous = lastContent ?? device.content else { return nil }
            return .init(event: .end, token: token, environment: device.environment,
                         content: previous.ending(completed: false, at: now), sessionID: id, timestamp: timestamp)
        }
        guard let summary, let token = device.startToken, token != invalidToken, token != pendingStartToken else { return nil }
        if let dismissedAt = device.dismissedAt, summary.newestStartedAt <= dismissedAt { return nil }
        return .init(event: .start, token: token, environment: device.environment, content: summary,
                     sessionID: UUID().uuidString, timestamp: timestamp)
    }
    public mutating func reserve(_ push: LiveActivityPush) { if push.event == .start { pendingStartToken = push.token } }
    public mutating func commit(_ push: LiveActivityPush) {
        lastContent = push.content; lastToken = push.token; lastEvent = push.event; lastTimestamp = push.timestamp
        if push.event != .start { pendingStartToken = nil }
    }
}
