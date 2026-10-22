import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct InstructionSourcesTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-instructions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func seedsEveryRoleOnceAndPreservesEdits() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let first = try InstructionSources.load(dataDirectory: base, role: .hird)
        #expect(first.background.contains("Hird"))
        #expect(!first.rules.isEmpty)
        let common = base.appendingPathComponent("instructions/common/AGENTS.md")
        let original = try String(contentsOf: common, encoding: .utf8)
        try "사용자 공통 배경\n".write(to: common, atomically: true, encoding: .utf8)
        let second = try InstructionSources.load(dataDirectory: base, role: .hird)
        #expect(second.background.contains("사용자 공통 배경"))
        #expect(!second.background.contains(original.split(separator: "\n").first ?? ""))
        #expect(try String(contentsOf: common, encoding: .utf8) == "사용자 공통 배경\n")
    }

    @Test func composesCommonThenRoleThenOnlyThisProject() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        _ = try InstructionSources.load(dataDirectory: base, role: .stallari)
        try write("프로젝트 A 배경\n", base.appendingPathComponent("instructions/projects/a/AGENTS.md"))
        try write("프로젝트 B 배경\n", base.appendingPathComponent("instructions/projects/b/AGENTS.md"))
        try write("프로젝트 A 규칙\n", base.appendingPathComponent("instructions/projects/a/RULES.md"))
        let a = try InstructionSources.load(dataDirectory: base, role: .stallari, projectID: "a")
        let b = try InstructionSources.load(dataDirectory: base, role: .stallari, projectID: "b")
        #expect(a.background.contains("프로젝트 A 배경"))
        #expect(!a.background.contains("프로젝트 B 배경"))
        #expect(a.rules.contains("프로젝트 A 규칙"))
        #expect(!b.rules.contains("프로젝트 A 규칙"))
        // Common and role text stay identical across projects.
        #expect(a.background.hasPrefix(b.background.components(separatedBy: "\n\n").first ?? ""))
        let none = try InstructionSources.load(dataDirectory: base, role: .stallari, projectID: "missing")
        #expect(!none.background.contains("프로젝트 A 배경"))
        #expect(none.prompt.isEmpty == false)
    }

    @Test func composeDropsAnotherProjectsSources() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        _ = try InstructionSources.load(dataDirectory: base, role: .stallari, projectID: "a")
        let set = try InstructionSources.load(dataDirectory: base, role: .stallari, projectID: "b")
        let foreign = InstructionSource(path: "/x", role: .project, projectID: "a", kind: .agents,
                                        text: "외부 프로젝트 전용 표식 QZ", version: "v", migratedFrom: nil)
        let composed = InstructionSources.compose(role: .stallari, projectID: "b", sources: set.sources + [foreign])
        #expect(!composed.background.contains("외부 프로젝트 전용 표식 QZ"))
        #expect(!composed.rules.contains("외부 프로젝트 전용 표식 QZ"))
    }

    @Test func rejectsSymlinksPathsAndOversizedFiles() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        _ = try InstructionSources.load(dataDirectory: base, role: .stallari)
        let rules = base.appendingPathComponent("instructions/stallari/RULES.md")
        let external = base.appendingPathComponent("outside.md")
        try "밖의 파일\n".write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: rules)
        try FileManager.default.createSymbolicLink(at: rules, withDestinationURL: external)
        #expect(throws: InstructionSourceError.self) { _ = try InstructionSources.load(dataDirectory: base, role: .stallari) }
        // Saving cannot follow it either, and the target is untouched.
        #expect(throws: InstructionSourceError.self) {
            _ = try InstructionSources.save(dataDirectory: base, role: .stallari, kind: .rules, projectID: nil,
                                            text: "x", expectedHash: "0")
        }
        #expect(try String(contentsOf: external, encoding: .utf8) == "밖의 파일\n")
        #expect(throws: InstructionSourceError.self) {
            _ = try InstructionSources.url(dataDirectory: base, role: .project, kind: .rules, projectID: "../escape")
        }
        try FileManager.default.removeItem(at: rules)
        try write(String(repeating: "a", count: InstructionSources.maximumBytes + 1), rules)
        #expect(throws: InstructionSourceError.tooLarge(rules.path)) { _ = try InstructionSources.load(dataDirectory: base, role: .stallari) }
    }

    @Test func emptyOrNonUTF8RulesFailClosedAndAreNotRewritten() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        _ = try InstructionSources.load(dataDirectory: base, role: .stallari)
        let rules = base.appendingPathComponent("instructions/stallari/RULES.md")
        try "  \n".write(to: rules, atomically: true, encoding: .utf8)
        #expect(throws: InstructionSourceError.self) { _ = try InstructionSources.load(dataDirectory: base, role: .stallari) }
        #expect(try String(contentsOf: rules, encoding: .utf8) == "  \n")
        try Data([0xff, 0xfe]).write(to: rules)
        #expect(throws: InstructionSourceError.self) { _ = try InstructionSources.load(dataDirectory: base, role: .stallari) }
        #expect(try Data(contentsOf: rules) == Data([0xff, 0xfe]))
    }

    @Test func saveIsAtomicHashCheckedAndIdempotent() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let set = try InstructionSources.load(dataDirectory: base, role: .stallari)
        let current = try #require(set.source(.rules, role: .stallari))
        let saved = try InstructionSources.save(dataDirectory: base, role: .stallari, kind: .rules, projectID: nil,
                                                text: "새 규칙\n", expectedHash: current.version)
        #expect(saved.version == InstructionSources.digest(Data("새 규칙\n".utf8)))
        let reread = try InstructionSources.read(dataDirectory: base, role: .stallari, kind: .rules, projectID: nil)
        #expect(reread.text == "새 규칙\n")
        #expect(throws: InstructionSourceError.conflict(reread.path)) {
            _ = try InstructionSources.save(dataDirectory: base, role: .stallari, kind: .rules, projectID: nil,
                                            text: "덮어쓰기\n", expectedHash: current.version)
        }
        #expect(try String(contentsOf: base.appendingPathComponent("instructions/stallari/RULES.md"), encoding: .utf8) == "새 규칙\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("instructions/stallari").path)
        #expect(leftovers.filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test func legacyExecutionPolicyAndRulesAreMigratedOnceWithoutChanges() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let policy = base.appendingPathComponent("stallari/execution-policy.md")
        try write("이전 실행 정책\n", policy)
        try write("이전 규칙 하나\n", base.appendingPathComponent("rules/10-first.md"))
        try write("이전 규칙 둘\n", base.appendingPathComponent("rules/20-second.md"))
        let set = try InstructionSources.load(dataDirectory: base, role: .stallari)
        let rules = try #require(set.source(.rules, role: .common))
        let resolved = base.resolvingSymlinksInPath()
        let origins = (rules.migratedFrom ?? "").components(separatedBy: ", ").map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        #expect(origins == [resolved.appendingPathComponent("rules/10-first.md").path, resolved.appendingPathComponent("rules/20-second.md").path])
        #expect(rules.text.contains("이전 규칙 하나"))
        #expect(rules.text.contains("이전 규칙 둘"))
        #expect(rules.text.range(of: "이전 규칙 하나")!.lowerBound < rules.text.range(of: "이전 규칙 둘")!.lowerBound)
        let stallari = try #require(set.source(.rules, role: .stallari))
        #expect(stallari.migratedFrom == policy.path)
        #expect(stallari.text == "이전 실행 정책\n")
        // Originals stay, and a second load neither rewrites nor duplicates them.
        let seeded = try String(contentsOf: base.appendingPathComponent("instructions/common/RULES.md"), encoding: .utf8)
        _ = try InstructionSources.load(dataDirectory: base, role: .stallari)
        #expect(try String(contentsOf: base.appendingPathComponent("instructions/common/RULES.md"), encoding: .utf8) == seeded)
        #expect(try String(contentsOf: policy, encoding: .utf8) == "이전 실행 정책\n")
        #expect(try String(contentsOf: base.appendingPathComponent("rules/10-first.md"), encoding: .utf8) == "이전 규칙 하나\n")
        #expect(!seeded.contains("이전 실행 정책"))
    }

    @Test func userSavedFileWinsOverLegacySource() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        try write("이전 실행 정책\n", base.appendingPathComponent("stallari/execution-policy.md"))
        try write("사용자가 고친 규칙\n", base.appendingPathComponent("instructions/stallari/RULES.md"))
        let set = try InstructionSources.load(dataDirectory: base, role: .stallari)
        #expect(set.rules.contains("사용자가 고친 규칙"))
        #expect(!set.rules.contains("이전 실행 정책"))
    }

    @Test func settingsAndChatUseTheSameSourceAndNextRequestSeesIt() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let f = try await StallariFixture.make()
        do {
            let session = StallariSession(repository: f.repository, rpc: f.rpc, hird: f.hird,
                                          instructionsDirectory: base, instructionProjectID: nil)
            do { _ = try await session.send("안녕", about: nil) } catch { print("SEND ERROR", error) ; throw error }
            let set = try InstructionSources.load(dataDirectory: base, role: .stallari)
            let rules = try #require(set.source(.rules, role: .stallari))
            let saved = try await session.performTool("write_instruction_file", arguments: .object([
                "role": .string("stallari"), "kind": .string("rules"),
                "content": .string(rules.text + "\n추가 규칙\n"), "expectedHash": .string(rules.version)]))
            #expect(saved["version"]?.string == InstructionSources.digest(Data((rules.text + "\n추가 규칙\n").utf8)))
            let sources = try InstructionSources.sources(dataDirectory: base)
            #expect(sources.first { $0.role == .stallari && $0.kind == .rules }?.text.contains("추가 규칙") == true)
            // A stale hash is rejected instead of overwriting the newer save.
            await #expect(throws: (any Error).self) {
                _ = try await session.performTool("write_instruction_file", arguments: .object([
                    "role": .string("stallari"), "kind": .string("rules"),
                    "content": .string("덮어쓰기"), "expectedHash": .string(rules.version)]))
            }
            #expect(try InstructionSources.read(dataDirectory: base, role: .stallari, kind: .rules, projectID: nil).text.contains("추가 규칙"))
            let runtime = try await session.getRuntime()
            // The applied version is the composed set admitted with the last prompt, not the later edit.
            let currentVersion = try InstructionSources.load(dataDirectory: base, role: .stallari).version
            #expect(runtime["appliedInstructionsVersion"]?.string == set.version)
            #expect(currentVersion != set.version)
            #expect(runtime["instructionsDirectory"]?.string == base.appendingPathComponent("instructions").path)
            _ = await session.shutdown()
        } catch { try await f.cleanup(); throw error }
        try await f.cleanup()
    }

    @Test func toolRejectsForeignProjectsAndArbitraryPaths() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let f = try await StallariFixture.make()
        do {
            let session = StallariSession(repository: f.repository, rpc: f.rpc, hird: f.hird,
                                          instructionsDirectory: base, instructionProjectID: "p")
            let set = try InstructionSources.load(dataDirectory: base, role: .stallari)
            let common = try #require(set.source(.agents, role: .common))
            for arguments: OMPJSON in [
                .object(["role": .string("common"), "kind": .string("agents"), "projectID": .string("other"), "content": .string("x"), "expectedHash": .string(common.version)]),
                .object(["role": .string("common"), "kind": .string("agents"), "path": .string("/tmp/x.md"), "content": .string("x"), "expectedHash": .string(common.version)])
            ] {
                await #expect(throws: (any Error).self) { _ = try await session.performTool("write_instruction_file", arguments: arguments) }
            }
            try write("기존 프로젝트 규칙\n", base.appendingPathComponent("instructions/projects/p/RULES.md"))
            let project = try InstructionSources.load(dataDirectory: base, role: .stallari, projectID: "p")
            let projectRules = try #require(project.source(.rules, role: .project, projectID: "p"))
            let saved = try await session.performTool("write_instruction_file", arguments: .object([
                "role": .string("project"), "kind": .string("rules"), "projectID": .string("p"),
                "content": .string("프로젝트 규칙\n"), "expectedHash": .string(projectRules.version)]))
            #expect(saved["path"]?.string?.hasSuffix("instructions/projects/p/RULES.md") == true)
            await #expect(throws: (any Error).self) {
                _ = try await session.performTool("write_instruction_file", arguments: .object([
                    "role": .string("project"), "kind": .string("rules"), "projectID": .string("other"),
                    "content": .string("x"), "expectedHash": .string(projectRules.version)]))
            }
            _ = await session.shutdown()
        } catch { try await f.cleanup(); throw error }
        try await f.cleanup()
    }

    @Test func hirdPromptCarriesOwnedRulesButInspectStaysFixed() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let policy = try HirdPolicyFiles(directory: base.appendingPathComponent("hird")).load()
        let change = policy.prompt(mode: .change, task: "합계 수정")
        #expect(change.contains("Hird 규칙"))
        #expect(change.contains("합계 수정"))
        #expect(policy.userInstructions?.version.isEmpty == false)
        let inspect = policy.prompt(mode: .inspect, task: "조사")
        #expect(!inspect.contains("Hird 규칙"))
        #expect(inspect.contains("조사"))
    }

    @Test func brokenInstructionTreeStopsHirdDispatch() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        _ = try InstructionSources.load(dataDirectory: base, role: .hird)
        try "  \n".write(to: base.appendingPathComponent("instructions/hird/RULES.md"), atomically: true, encoding: .utf8)
        let policy = try HirdPolicyFiles(directory: base.appendingPathComponent("hird")).load()
        #expect(policy.instructionFailure != nil)
        #expect(policy.userInstructions == nil)
    }
}
