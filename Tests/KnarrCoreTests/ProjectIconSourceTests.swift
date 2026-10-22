import Foundation
import Testing
@testable import KnarrCore
@testable import KnarrUI

struct ProjectIconSourceTests {
    @MainActor @Test func bundledKnarrArtworkLoads() {
        #expect(AppArtwork.logo.isValid)
        #expect(AppArtwork.logo.size.width > 0)
    }
    @Test func usesDeclaredDefaultAppIconAndSkipsWatchAndWorktrees() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-logo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ path: String, _ text: String = "image") throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let catalog = "ios/App/Assets.xcassets/AppIcon.appiconset/"
        try file(catalog + "Contents.json", #"{"images":[{"filename":"dark.png","size":"1024x1024","appearances":[{"appearance":"luminosity","value":"dark"}]},{"filename":"actual.png","size":"1024x1024"}]}"#)
        try file(catalog + "actual.png")
        try file(catalog + "dark.png")
        for excluded in ["Watch App", ".worktrees/old", "outputs", "node_modules/library"] {
            try file(excluded + "/AppIcon.appiconset/Contents.json", #"{"images":[{"filename":"wrong.png"}]}"#)
            try file(excluded + "/AppIcon.appiconset/wrong.png")
        }
        #expect(ProjectIconSource.candidates(in: root).map(\.lastPathComponent) == ["actual.png"])
        try file("assets/app-icon.png")
        #expect(ProjectIconSource.candidates(in: root).first == root.appendingPathComponent("assets/app-icon.png").resolvingSymlinksInPath())
    }

    @Test func missingArtworkAndEscapingManifestDoNotUseUnrelatedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-logo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        #expect(ProjectIconSource.candidates(in: project).isEmpty)
        try Data("unrelated image".utf8).write(to: root.appendingPathComponent("outside.png"))
        try Data(#"{"expo":{"icon":"../outside.png"}}"#.utf8).write(to: project.appendingPathComponent("app.json"))
        #expect(ProjectIconSource.candidates(in: project).isEmpty)
    }
}
