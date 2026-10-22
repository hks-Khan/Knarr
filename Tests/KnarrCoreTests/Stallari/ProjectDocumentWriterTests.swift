import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct ProjectDocumentWriterTests {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-documents-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func createsNestedMarkdownAndOverwritesWholeContentIncludingEmptyUTF8() throws {
        try withRoot { root in
            let content = "# 문서\n한글 내용\n"
            let first = try StallariDocumentWriter.write(root: root, path: "docs/notes/plan.md", content: content)
            #expect(first.path == "docs/notes/plan.md")
            #expect(first.created)
            #expect(first.byteCount == content.utf8.count)
            #expect(first.hash == SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined())
            let file = root.appendingPathComponent(first.path)
            let initialText = try String(contentsOf: file, encoding: .utf8)
            #expect(initialText == content)
            let second = try StallariDocumentWriter.write(root: root, path: first.path, content: "짧음", expectedHash: first.hash)
            #expect(!second.created)
            #expect(second.byteCount == 6)
            let replacedText = try String(contentsOf: file, encoding: .utf8)
            #expect(replacedText == "짧음")
            let empty = try StallariDocumentWriter.write(root: root, path: first.path, content: "", expectedHash: second.hash)
            #expect(!empty.created && empty.byteCount == 0)
            let emptyBytes = try Data(contentsOf: file)
            #expect(emptyBytes.isEmpty)
        }
    }

    @Test(arguments: ["", "/absolute.md", "../escape.md", "docs/../../escape.md", "docs/../escape.md", "docs//note.md", "./note.md", "docs/./note.md", "note.md/", "notes.txt", "script.swift", "note.markdown", "note.md\0other", "docs\\note.md"])
    func rejectsInvalidPathsAndNonMarkdown(path: String) throws {
        try withRoot { root in
            #expect(throws: (any Error).self) { try StallariDocumentWriter.write(root: root, path: path, content: "거부") }
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(entries.isEmpty)
        }
    }

    @Test(arguments: [".git/config.md", ".build/log.md", "node_modules/package/readme.md", "outputs/run.md", ".worktrees/task/note.md", "docs/.git/note.md", "docs/.build/note.md", "docs/node_modules/note.md", "docs/outputs/note.md", "docs/.worktrees/note.md", "AGENTS.md", "docs/AGENTS.md", "CLAUDE.md", "docs/CLAUDE.md", ".github/copilot-instructions.md", "docs/.github/copilot-instructions.md", ".claude/notes.md", "docs/.claude/notes.md", "agents.MD", "Docs/.GIT/note.md"])
    func rejectsExcludedDirectoriesAndInstructionFiles(path: String) throws {
        try withRoot { root in
            #expect(throws: (any Error).self) { try StallariDocumentWriter.write(root: root, path: path, content: "거부") }
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(entries.isEmpty)
        }
    }

    @Test func rejectsHashConflictMissingFileAndMalformedHashWithoutChangingContent() throws {
        try withRoot { root in
            let first = try StallariDocumentWriter.write(root: root, path: "note.md", content: "기존")
            for hash in [String(repeating: "0", count: 64), "bad", "", String(repeating: "g", count: 64)] {
                #expect(throws: (any Error).self) { try StallariDocumentWriter.write(root: root, path: "note.md", content: "변경", expectedHash: hash) }
                let unchangedText = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
                #expect(unchangedText == "기존")
            }
            #expect(throws: (any Error).self) { try StallariDocumentWriter.write(root: root, path: "missing.md", content: "생성", expectedHash: first.hash) }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing.md").path))
            let result = try StallariDocumentWriter.write(root: root, path: "note.md", content: "변경", expectedHash: first.hash.uppercased())
            #expect(!result.created)
        }
    }

    @Test func rejectsSymlinkEscapesExcludedAliasesRuleAliasesAndEvenInternalAliases() throws {
        try withRoot { root in
            try withRoot { outside in
                let fm = FileManager.default
                try "보존".write(to: outside.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
                try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
                try fm.createSymbolicLink(at: root.appendingPathComponent("outside.md"), withDestinationURL: outside.appendingPathComponent("outside.md"))
                for directory in [".git", ".build", "node_modules", "outputs", ".worktrees", ".claude", ".github", "docs"] {
                    try fm.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
                    let alias = "alias-" + directory.replacingOccurrences(of: ".", with: "")
                    try fm.createSymbolicLink(at: root.appendingPathComponent(alias), withDestinationURL: root.appendingPathComponent(directory))
                    #expect(throws: (any Error).self) { try StallariDocumentWriter.write(root: root, path: alias + "/note.md", content: "거부") }
                }
                for (index, rule) in ["AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md", ".claude/rules.md"].enumerated() {
                    try "규칙 보존".write(to: root.appendingPathComponent(rule), atomically: true, encoding: .utf8)
                    let alias = "rule-\(index).md"
                    try fm.createSymbolicLink(at: root.appendingPathComponent(alias), withDestinationURL: root.appendingPathComponent(rule))
                    #expect(throws: (any Error).self) { try StallariDocumentWriter.write(root: root, path: alias, content: "거부") }
                    let preservedRule = try String(contentsOf: root.appendingPathComponent(rule), encoding: .utf8)
                    #expect(preservedRule == "규칙 보존")
                }
                for path in ["escape/new.md", "outside.md"] {
                    #expect(throws: (any Error).self) { try StallariDocumentWriter.write(root: root, path: path, content: "거부") }
                }
                try fm.createSymbolicLink(atPath: root.appendingPathComponent("dangling.md").path, withDestinationPath: "missing.md")
                #expect(throws: (any Error).self) { try StallariDocumentWriter.write(root: root, path: "dangling.md", content: "거부") }
                let preservedOutside = try String(contentsOf: outside.appendingPathComponent("outside.md"), encoding: .utf8)
                #expect(preservedOutside == "보존")
                #expect(!fm.fileExists(atPath: outside.appendingPathComponent("new.md").path))
            }
        }
    }

    @Test func rejectsHardlinksDirectoriesAndSpecialFilesWithoutTruncation() throws {
        try withRoot { root in
            let fm = FileManager.default
            let original = root.appendingPathComponent("AGENTS.md")
            try "규칙".write(to: original, atomically: true, encoding: .utf8)
            try fm.linkItem(at: original, to: root.appendingPathComponent("alias.md"))
            try fm.createDirectory(at: root.appendingPathComponent("directory.md"), withIntermediateDirectories: false)
            #expect(mkfifo(root.appendingPathComponent("pipe.md").path, 0o600) == 0)
            for path in ["alias.md", "directory.md", "pipe.md"] {
                #expect(throws: (any Error).self) { try StallariDocumentWriter.write(root: root, path: path, content: "거부") }
            }
            let preservedOriginal = try String(contentsOf: original, encoding: .utf8)
            #expect(preservedOriginal == "규칙")
        }
    }

    private func arguments(projectID: String = "p", path: String = "docs/note.md", content: String = "문서") -> OMPJSON {
        .object(["projectID": .string(projectID), "path": .string(path), "content": .string(content)])
    }

    @Test func mainSelectsRegisteredProjectsAndProjectThreadCannotEscapeOrSpoofOwnership() async throws {
        let f = try await StallariFixture.make()
        let otherRoot = f.directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try await f.repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: otherRoot.path))
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let project = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: thread.id)
        let stranger = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: UUID().uuidString)
        do {
            let main = try await f.session.performTool("write_project_document", arguments: arguments(projectID: "other", content: ""))
            #expect(main["created"]?.bool == true && main["byteCount"]?.integer == 0)
            #expect(main["path"]?.string == "docs/note.md")
            #expect(main["hash"]?.string?.count == 64)
            let local = try await project.performTool("write_project_document", arguments: arguments())
            #expect(local["byteCount"]?.integer == 6)
            await #expect(throws: (any Error).self) { _ = try await project.performTool("write_project_document", arguments: arguments(projectID: "other")) }
            await #expect(throws: (any Error).self) { _ = try await stranger.performTool("write_project_document", arguments: arguments()) }
            for key in ["threadID", "originThreadID", "issueID"] {
                var fields: [String: OMPJSON] = ["projectID": .string("p"), "path": .string("spoof.md"), "content": .string("거부")]
                fields[key] = .string(ConversationThread.defaultID)
                let spoofed = OMPJSON.object(fields)
                await #expect(throws: (any Error).self) { _ = try await project.performTool("write_project_document", arguments: spoofed) }
            }
            await #expect(throws: (any Error).self) { _ = try await f.session.performTool("write_project_document", arguments: arguments(projectID: "missing")) }
            await #expect(throws: (any Error).self) { _ = try await f.session.performTool("write_project_document", arguments: arguments(projectID: StoredProject.hubID)) }
            await #expect(throws: (any Error).self) { _ = try await f.session.performTool("write_project_document", arguments: .object(["path": .string("note.md"), "content": .string("거부")])) }
            _ = await project.shutdown(); _ = await stranger.shutdown(); try await f.cleanup()
        } catch {
            _ = await project.shutdown(); _ = await stranger.shutdown(); try await f.cleanup(); throw error
        }
    }

    @Test func issueThreadIsBoundToItsStoredProjectAndArchivedThreadsStayReadOnly() async throws {
        let f = try await StallariFixture.make()
        try await f.repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: f.directory.path))
        let id = try await f.session.createIssue(id: "document-owner", title: "문서", criteria: ["문서"], instruction: "문서", projectID: "p")
        let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == id })
        let owner = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: issue.conversationThreadID)
        do {
            _ = try await owner.performTool("write_project_document", arguments: arguments())
            await #expect(throws: (any Error).self) { _ = try await owner.performTool("write_project_document", arguments: arguments(projectID: "other")) }
            _ = try await f.session.performTool("close_issue", arguments: .object(["issueID": .string(id.rawValue), "reason": .string("cancelled"), "note": .string("닫기")]))
            await #expect(throws: (any Error).self) { _ = try await owner.performTool("write_project_document", arguments: arguments(content: "거부")) }
            var p = try #require(try await f.repository.snapshot().projects.first { $0.id == "other" })
            p.archivedAt = .now
            try await f.repository.saveProject(p)
            await #expect(throws: (any Error).self) { _ = try await f.session.performTool("write_project_document", arguments: arguments(projectID: "other")) }
            _ = await owner.shutdown(); try await f.cleanup()
        } catch { _ = await owner.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func routeValidatesArgumentsAndPropagatesExpectedHash() async throws {
        let f = try await StallariFixture.make()
        do {
            let initial = try await f.session.performTool("write_project_document", arguments: arguments())
            let hash = try #require(initial["hash"]?.string)
            let updated = try await f.session.performTool("write_project_document", arguments: .object([
                "projectID": .string("p"), "path": .string("docs/note.md"),
                "content": .string("새 문서"), "expectedHash": .string(hash)]))
            #expect(updated["created"]?.bool == false)
            #expect(updated["hash"]?.string != hash)
            await #expect(throws: (any Error).self) {
                _ = try await f.session.performTool("write_project_document", arguments: .object([
                    "projectID": .string("p"), "path": .string("docs/note.md"),
                    "content": .string("오래된 내용"), "expectedHash": .string(hash)]))
            }
            for invalid in [
                OMPJSON.object(["projectID": .string("p"), "path": .string("new.md")]),
                .object(["projectID": .string("p"), "path": .string("new.md"), "content": .number(1)]),
                .object(["projectID": .string("p"), "path": .string("new.md"), "content": .string(""), "expectedHash": .null])
            ] {
                await #expect(throws: (any Error).self) { _ = try await f.session.performTool("write_project_document", arguments: invalid) }
            }
            let savedText = try String(contentsOf: f.directory.appendingPathComponent("docs/note.md"), encoding: .utf8)
            #expect(savedText == "새 문서")
            #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("new.md").path))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func projectOriginIssueUsesOnlyItsStoredProject() async throws {
        let f = try await StallariFixture.make()
        try await f.repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: f.directory.path))
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let project = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: thread.id)
        var owner: StallariSession?
        do {
            let id = try await project.createIssue(id: "project-document", title: "문서", criteria: ["문서"], instruction: "문서")
            let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == id })
            let session = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: issue.conversationThreadID)
            owner = session
            let result = try await session.performTool("write_project_document", arguments: arguments())
            #expect(result["created"]?.bool == true)
            await #expect(throws: (any Error).self) {
                _ = try await session.performTool("write_project_document", arguments: arguments(projectID: "other"))
            }
            _ = await session.shutdown(); _ = await project.shutdown(); try await f.cleanup()
        } catch {
            if let owner { _ = await owner.shutdown() }
            _ = await project.shutdown(); try await f.cleanup(); throw error
        }
    }
}
