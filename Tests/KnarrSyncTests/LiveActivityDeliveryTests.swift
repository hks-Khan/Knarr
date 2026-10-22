import Foundation
import Testing
@testable import KnarrSync

@Suite struct LiveActivityDeliveryTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    var summary: LiveActivitySummary { LiveActivitySummary.make(issues: [LiveActivityTests().issue()], questions: [])! }
    func device(active: Bool = false) -> MobileActivityDevice {
        .init(id: "phone", environment: .sandbox, enabled: true, startToken: String(repeating: "a", count: 64),
              activityID: active ? "activity" : nil, updateToken: active ? String(repeating: "b", count: 64) : nil, updatedAt: at)
    }
    @Test func startsOnceWhileWaitingForThePhoneToRegisterItsActivity() throws {
        var plan = LiveActivityDeliveryPlan()
        let push = try #require(plan.next(device: device(), summary: summary, now: at))
        #expect(push.event == .start)
        plan.reserve(push)
        #expect(plan.next(device: device(), summary: summary, now: at.addingTimeInterval(60)) == nil)
        let restored = try JSONDecoder().decode(LiveActivityDeliveryPlan.self, from: JSONEncoder().encode(plan))
        #expect(restored.next(device: device(), summary: summary, now: at.addingTimeInterval(120)) == nil)
    }
    @Test func updatesTheExistingActivityAndSkipsIdenticalContent() throws {
        var plan = LiveActivityDeliveryPlan()
        let push = try #require(plan.next(device: device(active: true), summary: summary, now: at))
        #expect(push.event == .update)
        plan.commit(push)
        #expect(plan.next(device: device(active: true), summary: summary, now: at.addingTimeInterval(60)) == nil)
        var changed = summary; changed.status = .needsInput
        #expect(plan.next(device: device(active: true), summary: changed, now: at)?.event == .update)
    }
    @Test func endsWithFinalContentAndDoesNotKeepSendingEnd() throws {
        var plan = LiveActivityDeliveryPlan()
        plan.commit(try #require(plan.next(device: device(active: true), summary: summary, now: at)))
        let end = try #require(plan.next(device: device(active: true), summary: nil, now: at.addingTimeInterval(1)))
        #expect(end.event == .end)
        #expect(end.content.isFinished)
        plan.commit(end)
        #expect(plan.next(device: device(active: true), summary: nil, now: at.addingTimeInterval(2)) == nil)
    }
    @Test func honorsDisabledDismissedAndMissingTokens() {
        let plan = LiveActivityDeliveryPlan()
        var d = device(); d.enabled = false
        #expect(plan.next(device: d, summary: summary, now: at) == nil)
        d.enabled = true; d.dismissedAt = at
        #expect(plan.next(device: d, summary: summary, now: at) == nil)
        d.dismissedAt = nil; d.startToken = nil
        #expect(plan.next(device: d, summary: summary, now: at) == nil)
        d = device(); d.activityID = "token-pending"
        #expect(plan.next(device: d, summary: summary, now: at) == nil)
    }
    @Test func tokenRotationAllowsUpdatingAgainAndExpiredTokensAreSuppressed() throws {
        var plan = LiveActivityDeliveryPlan(); var d = device(active: true)
        plan.commit(try #require(plan.next(device: d, summary: summary, now: at)))
        d.updateToken = String(repeating: "c", count: 64)
        #expect(plan.next(device: d, summary: summary, now: at)?.event == .update)
        plan.invalidToken = d.updateToken
        #expect(plan.next(device: d, summary: summary, now: at) == nil)
    }
    @Test func payloadUsesAppleKeysAndDefaultDateEncoding() throws {
        let push = LiveActivityPush(event: .start, token: "fixture", environment: .sandbox, content: summary, sessionID: "session", timestamp: 1800000000)
        let data = try push.payload()
        #expect(data.count > 0 && data.count <= 4096)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aps = try #require(body["aps"] as? [String: Any])
        #expect(aps["event"] as? String == "start")
        #expect(aps["attributes-type"] as? String == "KnarrActivityAttributes")
        #expect(aps["alert"] != nil)
        let content = try #require(aps["content-state"] as? [String: Any])
        #expect(content["startedAt"] as? Double == summary.startedAt.timeIntervalSinceReferenceDate)
        #expect(aps["stale-date"] as? Int == 1800000900)
        var end = push; end.event = .end
        let endBody = try #require(try JSONSerialization.jsonObject(with: end.payload()) as? [String: [String: Any]])
        #expect(endBody["aps"]?["dismissal-date"] as? Int == 1800000060)
        #expect(endBody["aps"]?["attributes-type"] == nil)
    }
}
