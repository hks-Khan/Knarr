import Foundation
import Testing
@testable import KnarrCore

@Suite struct ProjectLaunchTests {
    @Test func aFolderBecomesAProjectWithAStableID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Knarr Pick \(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try StoredProject.at(path: dir.path), b = try StoredProject.at(path: dir.path + "/")
        #expect(a.name == dir.lastPathComponent)
        #expect(a.id == b.id)
        #expect(a.id.hasPrefix("project-"))
    }

    @Test func missingOrRelativeFolderIsRefused() {
        #expect(throws: LiveKnarrError.self) { try StoredProject.at(path: "/nonexistent/knarr-\(UUID())") }
        #expect(throws: LiveKnarrError.self) { try StoredProject.at(path: "relative/path") }
    }

    @Test func developmentPathIsAddedButNotRequired() throws {
        let dir = FileManager.default.temporaryDirectory
        let none = LiveKnarrConfiguration.standard(environment: ["HOME": "/Users/x"], arguments: ["Knarr"], loginPath: nil)
        #expect(none.projects.isEmpty)
        let one = LiveKnarrConfiguration.standard(environment: ["KNARR_PROJECT_PATH": dir.path], arguments: ["Knarr"], loginPath: nil)
        #expect(one.projects.map(\.absolutePath) == [dir.resolvingSymlinksInPath().standardizedFileURL.path])
        let skip = LiveKnarrConfiguration.standard(environment: ["KNARR_SKIP_JITDECK_IMPORT": "1"], arguments: ["Knarr"], loginPath: nil)
        #expect(skip.jitdeckDatabase == nil)
    }

    @Test func finderLaunchGetsTheLoginShellPath() {
        let c = LiveKnarrConfiguration.standard(environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/x"], arguments: ["Knarr"],
                                                loginPath: "/opt/homebrew/bin:/usr/bin:/Users/x/.local/bin")
        #expect(c.environment["PATH"] == "/opt/homebrew/bin:/usr/bin:/Users/x/.local/bin:/bin")
        #expect(c.environment["HOME"] == "/Users/x")
    }

    @Test func withoutALoginShellCommonToolFoldersAreAdded() {
        let c = LiveKnarrConfiguration.standard(environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/x"], arguments: ["Knarr"], loginPath: nil)
        #expect(c.environment["PATH"] == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/Users/x/.local/bin")
    }
}
