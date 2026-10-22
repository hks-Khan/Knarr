import Foundation
import Testing
@testable import KnarrSync

@MainActor @Suite struct MobileClientModelTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    func issue(_ id: String, _ group: MobileIssue.Group, updated: TimeInterval = 0) -> MobileRecord {
        .issue(MobileIssue(id: id, title: id, project: "P", state: group == .working ? .running : group == .mine ? .needsInput : .failed, group: group, headline: "", detail: "",
                           criteria: [], progress: nil, startedAt: at, updatedAt: at.addingTimeInterval(updated),
                           runs: group == .working ? [.init(name: "Hird", role: "검사", status: .working, steps: [])] : []))
    }

    @Test func issuesAreGroupedLikeTheMacPanel() {
        let model = MobileClientModel()
        model.apply(saved: [issue("w", .working), issue("m1", .mine, updated: 1), issue("m2", .mine, updated: 5), issue("s", .stopped)], deleted: [])
        #expect(model.sections.map(\.group) == [.mine, .working, .stopped])
        #expect(model.sections.first?.issues.map(\.id) == ["m2", "m1"])
    }

    @Test func deletedRecordsDisappear() {
        let model = MobileClientModel()
        model.apply(saved: [issue("a", .working)], deleted: [])
        model.apply(saved: [], deleted: [issue("a", .working).recordName])
        #expect(model.sections.isEmpty)
    }

    @Test func pendingQuestionsOfAIssueAreListed() {
        let model = MobileClientModel()
        let open = MobileQuestion(id: "q1", issue: "a", asker: "Hird-1", prompt: "?", options: [], allowsMultiple: false,
                                  state: .pending, answer: nil, askedAt: at)
        var closed = open; closed.id = "q2"; closed.state = .answered
        model.apply(saved: [.question(open), .question(closed)], deleted: [])
        #expect(model.pendingQuestions(for: "a").map(\.id) == ["q1"])
        #expect(model.pendingQuestionCount == 1)
    }

    @Test func messagesAreOldestFirst() {
        let model = MobileClientModel()
        model.apply(saved: [.message(.init(id: "2", at: at.addingTimeInterval(9), role: .stallari, text: "b", project: nil)),
                            .message(.init(id: "1", at: at, role: .user, text: "a", project: nil))], deleted: [])
        #expect(model.messages.map(\.id) == ["1", "2"])
    }

    @Test func aSentRequestStaysPendingUntilTheMacRemovesIt() {
        let model = MobileClientModel()
        let request = model.makeRequest(.message(text: "안녕", project: nil), now: at)
        model.apply(saved: [.request(request)], deleted: [])
        #expect(model.pendingRequests.map(\.id) == [request.id])
        model.apply(saved: [], deleted: [MobileRecord.request(request).recordName])
        #expect(model.pendingRequests.isEmpty)
    }

    @Test func answeringIsBlockedOnceAQuestionIsAlreadyBeingAnswered() {
        let model = MobileClientModel()
        let q = MobileQuestion(id: "q1", issue: "a", asker: "Hird-1", prompt: "?", options: ["예"], allowsMultiple: false,
                               state: .pending, answer: nil, askedAt: at)
        model.apply(saved: [.question(q)], deleted: [])
        #expect(model.isAwaitingMac(question: "q1") == false)
        model.apply(saved: [.request(model.makeRequest(.answer(question: "q1", options: ["예"], text: nil), now: at))], deleted: [])
        #expect(model.isAwaitingMac(question: "q1"))
    }
}

@MainActor @Suite struct MobileClientModelFeedbackTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func requestsTheMacRemovedAreReportedAsApplied() {
        let model = MobileClientModel()
        let request = model.makeRequest(.action(issue: "a", action: .stop), now: at)
        model.apply(saved: [.request(request)], deleted: [])
        let applied = model.apply(saved: [], deleted: [MobileRecord.request(request).recordName])
        #expect(applied.map(\.id) == [request.id])
    }

    @Test func aRequestCancelledOnThePhoneIsNotReportedAsApplied() {
        let model = MobileClientModel()
        let request = model.makeRequest(.message(text: "x", project: nil), now: at)
        model.apply(saved: [.request(request)], deleted: [])
        model.forget(request: request.id)
        #expect(model.pendingRequests.isEmpty)
        #expect(model.apply(saved: [], deleted: [MobileRecord.request(request).recordName]).isEmpty)
    }

    @Test func replacingEverythingDropsWhatTheCloudNoLongerHas() {
        let model = MobileClientModel()
        model.apply(saved: [.project(.init(id: "old", name: "old", openIssues: 0))], deleted: [])
        model.replaceAll(with: [.project(.init(id: "new", name: "new", openIssues: 0))])
        #expect(model.projects.map(\.id) == ["new"])
    }

    @Test func resolvedQuestionsOfAIssueAreKept() {
        let model = MobileClientModel()
        let q = MobileQuestion(id: "q", issue: "a", asker: "Hird-1", prompt: "?", options: [], allowsMultiple: false,
                               state: .answered, answer: "예", askedAt: at)
        model.apply(saved: [.question(q)], deleted: [])
        #expect(model.resolvedQuestions(for: "a").map(\.id) == ["q"])
    }
}
