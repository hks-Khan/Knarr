import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct StallariAutonomyTests {
    @Test func exportContractForIsolatedLiveValidation() throws {
        let tool = try #require(StallariTools.definitions.first { $0["name"]?.string == "approve_issue" })
        #expect(tool["parameters"]?["required"]?.array == [.string("issueID"), .string("version")])
        guard let path = ProcessInfo.processInfo.environment["KNARR_AUTONOMY_EVIDENCE"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(StallariTools.definitions).write(to: root.appendingPathComponent("tools.json"))
        try StallariTools.fixedInstructions.write(to: root.appendingPathComponent("system.txt"), atomically: true, encoding: .utf8)
        try StallariTools.discoveryOverlay.write(to: root.appendingPathComponent("config.yml"), atomically: true, encoding: .utf8)
    }
    @Test func instructionsRequireExecutionRequestButNotRepeatedApproval() throws {
        let text = StallariTools.fixedInstructions
        let rules = try #require(InstructionSources.packaged(role: .stallari).source(.rules, role: .stallari)?.text)
        #expect(rules.contains("Design discussion, questions and agreement that something needs improvement do not authorize starting work."))
        #expect(text.contains(rules))
        #expect(text.contains("only when the user requests implementation, modification or execution"))
        #expect(text.contains("continues within the approved scope through verification and necessary corrections without requesting the same approval again"))
        #expect(text.contains("ask the user when scope grows"))
        #expect(text.contains("Explicit stop or rejection takes precedence"))
        #expect(!text.contains("The user's current request and conversation authorize work within the agreed goal."))
        #expect(!text.contains("without asking for consent again"))
    }
    @Test func toolDescriptionsShareTheExecutionPolicyInsteadOfTheirOwnApprovalRule() throws {
        let tools = Dictionary(uniqueKeysWithValues: StallariTools.definitions.compactMap { tool -> (String, String)? in
            guard let name = tool["name"]?.string, let description = tool["description"]?.string else { return nil }
            return (name, description)
        })
        for name in ["approve_issue", "create_issue", "update_issue_proposal", "dispatch_hird"] {
            let description = try #require(tools[name])
            #expect(description.contains("execution policy"))
            #expect(!description.contains("current instructions and conversation authorize"))
            #expect(!description.contains("agreed goal"))
        }
        #expect(try #require(tools["approve_issue"]).contains("the app does not parse approval phrases"))
        #expect(try #require(tools["dispatch_hird"]).contains("cannot authorize dispatch"))
        #expect(try #require(tools["create_issue"]).contains("Does not launch Hird"))
    }
    @Test func runtimeRulesSeedOnceAndReachEveryLaunchPrompt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let packaged = try #require(InstructionSources.packaged(role: .stallari).source(.rules, role: .stallari)?.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seeded = try InstructionSources.load(dataDirectory: root, role: .stallari)
        let commonRules = try #require(InstructionSources.packaged(role: .stallari).source(.rules, role: .common)?.text)
        #expect(seeded.source(.rules, role: .stallari)?.text.trimmingCharacters(in: .whitespacesAndNewlines) == packaged)
        #expect(seeded.rules == commonRules.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + packaged)
        #expect(!seeded.rules.contains("\n\n\n"))
        let file = root.appendingPathComponent("instructions/stallari/RULES.md")
        #expect(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == packaged)
        try "Custom operating rule: begin only after an execution request.\n".write(to: file, atomically: true, encoding: .utf8)
        let custom = try InstructionSources.load(dataDirectory: root, role: .stallari)
        #expect(custom.rules.hasSuffix("Custom operating rule: begin only after an execution request."))
        #expect(custom.rules.contains(commonRules))
        #expect(!custom.rules.contains(packaged))
        let prompt = StallariTools.systemPrompt(policy: .current, instructions: custom)
        #expect(prompt.contains("Custom operating rule"))
        #expect(!prompt.contains(packaged))
    }
    @Test func unreadableRulesFailClosedWithoutRestoringAuthorization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try InstructionSources.load(dataDirectory: root, role: .stallari)
        let file = root.appendingPathComponent("instructions/stallari/RULES.md")
        try "   \n".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: InstructionSourceError.self) { _ = try InstructionSources.load(dataDirectory: root, role: .stallari) }
        let prompt = StallariTools.systemPrompt(policy: .current, instructions: nil, failure: InstructionSources.failure)
        #expect(prompt.contains("instruction files could not be read"))
        #expect(prompt.contains("Do not save-and-approve, approve or dispatch new work"))
        #expect(!prompt.contains("only when the user requests implementation"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "   \n")
    }

    @Test(arguments: ["세 개 승인", "승인이라고", "작업중인거 다 돌려서 마무리 지으라고 빨리", "응 그렇게 진행해", "승인해. 그리고 끝까지 확인해줘"])
    func controllerCanActWithoutPhraseReceipt(message: String) async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("delegated")
            _ = try await f.session.send(message, about: nil)
            let args: OMPJSON = .object(["issueID": .string(id.rawValue), "version": .number(1)])
            let run = try await f.session.performTool("approve_issue", arguments: args)
            let same = try await f.session.performTool("approve_issue", arguments: args)
            #expect(run["runID"] == same["runID"])
            #expect(try await f.repository.snapshot().runs.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func controllerStillCannotStartStaleOrForeignProposal() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("versioned")
            try await f.session.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "변경된 계획")
            for (target, version) in [(id.rawValue, 1), ("missing", 2)] {
                await #expect(throws: (any Error).self) {
                    _ = try await f.session.performTool("approve_issue", arguments: .object(["issueID": .string(target), "version": .number(Double(version))]))
                }
            }
            #expect(try await f.repository.snapshot().runs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
