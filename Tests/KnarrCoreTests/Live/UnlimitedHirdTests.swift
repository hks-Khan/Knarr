import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct UnlimitedHirdTests {
    @Test func storedLimitsKeepLegacyValuesAndUnlimitedAcrossRoundTrips() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let missing = try decoder.decode(ProjectSettings.self, from: Data("{}".utf8))
        #expect(missing.maxHirds == 2)
        for limit in [0, 1, 2, 4, 32, 64] {
            let settings = try decoder.decode(ProjectSettings.self, from: Data("{\"maxHirds\":\(limit)}".utf8))
            #expect(settings.cleaned.maxHirds == limit)
            #expect(try decoder.decode(ProjectSettings.self, from: encoder.encode(settings.cleaned)).maxHirds == limit)
        }
    }

    @Test func unlimitedApprovalsAndDispatchesCanExceedOldCapThenRestoreLimit() async throws {
        let f = try await LiveFixture.make()
        do {
            _ = try await f.session.performTool("set_project_settings", arguments: .object([
                "projectID": .string("p"), "maxHirds": .number(0)]))
            #expect(try await f.repository.snapshot().projects.first { $0.id == "p" }?.settings.maxHirds == 0)
            for n in 0..<6 {
                let id = KnarrCore.Issue.ID("unlimited-\(n)")
                try await f.create(id)
                if n.isMultiple(of: 2) {
                    _ = try await f.session.approveIssue(issueID: id, version: 1)
                } else {
                    try await f.dispatch(.init("unlimited-run-\(n)"), issue: id)
                }
            }
            let running = try await f.repository.snapshot().runs
            #expect(running.filter { $0.projectID == "p" && !$0.state.isTerminal }.count == 6)
            try await f.create("next")
            try await f.store.whenIdle()
            #expect(f.store.approvalBlockReason(for: "next") == nil)

            _ = try await f.session.performTool("set_project_settings", arguments: .object([
                "projectID": .string("p"), "maxHirds": .number(6)]))
            try await f.store.whenIdle()
            #expect(f.store.approvalBlockReason(for: "next") != nil)
            await #expect(throws: StallariError.self) {
                _ = try await f.session.approveIssue(issueID: "next", version: 1)
            }
            #expect(try await f.repository.snapshot().runs == running)
            #expect(try await f.repository.snapshot().issues.first { $0.id == "next" }?.approval == nil)

            _ = try await f.session.performTool("set_project_settings", arguments: .object([
                "projectID": .string("p"), "maxHirds": .number(7)]))
            let seventh = try await f.session.approveIssue(issueID: "next", version: 1)
            #expect(try await f.repository.snapshot().runs.contains { $0.id == seventh })
            #expect(try await f.session.approveIssue(issueID: "next", version: 1) == seventh)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func defaultStoreAdmissionAllowsUnlimitedAndKeepsFiniteLimit() throws {
        let store = SampleKnarrStore()
        let target = try #require(store.issues(inProject: "gamza").first { $0.hasActiveHird })
        store.updateProjectSettings("gamza", .init(maxHirds: 1))
        #expect(store.approvalBlockReason(for: target.id) != nil)
        store.updateProjectSettings("gamza", .init(maxHirds: 0))
        #expect(store.approvalBlockReason(for: target.id) == nil)
    }

    @Test func invalidLimitInputsDoNotChangeStoredSettings() async throws {
        let f = try await StallariFixture.make()
        do {
            let before = try await f.repository.snapshot().projects
            for value: OMPJSON in [.number(-1), .number(1.5), .string("many"), .null] {
                await #expect(throws: StallariError.invalidArguments) {
                    _ = try await f.session.performTool("set_project_settings", arguments: .object([
                        "projectID": .string("p"), "maxHirds": value]))
                }
                #expect(try await f.repository.snapshot().projects == before)
            }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
