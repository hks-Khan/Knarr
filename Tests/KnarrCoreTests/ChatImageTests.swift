import Foundation
import Testing
@testable import KnarrCore

/// Local images Stallari points at: what Knarr will read, and the durable copy it keeps.
@MainActor @Suite struct ChatImageTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-image-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ name: String, in root: URL, bytes: Int = 32) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @Test func acceptsOnlyRegularImageFilesOutsideCredentialDirectories() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = try write("shot.png", in: root)
        #expect(ChatImageSource.url(forPath: shot.path) == shot)
        // Only the picture formats Knarr renders; anything else stays plain text.
        for name in ["shot.jpg", "shot.jpeg", "shot.gif", "shot.webp", "shot.heic"] {
            let allowed = try write(name, in: root)
            #expect(ChatImageSource.url(forPath: allowed.path) == allowed, "\(name) must be allowed")
        }
        for name in ["shot.tiff", "shot.bmp", "shot.pdf", "shot.svg", "shot.txt"] {
            let refused = try write(name, in: root)
            #expect(ChatImageSource.url(forPath: refused.path) == nil, "\(name) must be refused")
        }
        #expect(ChatImageSource.url(forPath: "shot.png") == nil)
        #expect(ChatImageSource.url(forPath: root.appendingPathComponent("run.sh").path) == nil)
        #expect(ChatImageSource.url(forPath: root.appendingPathComponent("missing.png").path) == nil)
        let secret = try write(".ssh/id_rsa.png", in: root)
        #expect(ChatImageSource.url(forPath: secret.path) == nil)
        let environment = try write(".env.png", in: root)
        #expect(ChatImageSource.url(forPath: environment.path) == nil)
        let huge = try write("huge.png", in: root, bytes: ChatImageSource.maximumBytes + 1)
        #expect(ChatImageSource.url(forPath: huge.path) == nil)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shot)
        #expect(ChatImageSource.url(forPath: link.path) == nil)
    }

    @Test func identifierIsStablePerPathAndFollowsTheExtension() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = try write("shot.jpeg", in: root)
        #expect(ChatImageSource.identifier(for: shot) == ChatImageSource.identifier(for: shot))
        #expect(ChatImageSource.identifier(for: shot) != ChatImageSource.identifier(for: try write("other.jpeg", in: root)))
        #expect(ChatImageSource.mimeType(for: shot) == "image/jpeg")
    }

    @Test func persistingCopiesImagesOnceAndRewritesOnlyTheirMarkdown() throws {
        let root = try directory(), store = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store) }
        let shot = try write("shot.png", in: root, bytes: 64)
        let text = "결과입니다.\n\n![확인 화면](\(shot.path))\n\n![없는 파일](/nope/gone.png)\n"
        let first = ChatImageSource.persisting(text, root: store)
        #expect(!first.contains(shot.path))
        #expect(first.contains("![확인 화면](/"))
        #expect(first.contains("![없는 파일](/nope/gone.png)"))
        let copied = try #require(first.split(separator: "(").dropFirst().first.map { String($0.prefix(while: { $0 != ")" })) })
        #expect(FileManager.default.contents(atPath: copied) == FileManager.default.contents(atPath: shot.path))
        #expect(copied.hasSuffix(".png"))
        let second = ChatImageSource.persisting(first, root: store)
        #expect(second == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.path).count == 1)
    }

    @Test func persistingWithoutARootKeepsTheOriginalText() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "![그림](\(try write("shot.png", in: root).path))"
        #expect(ChatImageSource.persisting(text, root: nil) == text)
    }

    @Test func rewritingReplacesOnlyValidatedPaths() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = try write("shot.png", in: root)
        func transform(_ path: String) -> String? { ChatImageSource.url(forPath: path) == nil ? nil : "chat-image://image/deadbeef" }
        #expect(ChatImageSource.rewriting("![화면](\(shot.path))", transform) == "![화면](chat-image://image/deadbeef)")
        #expect(ChatImageSource.rewriting("![화면](</\(shot.path.dropFirst())>)", transform) == "![화면](chat-image://image/deadbeef)")
        #expect(ChatImageSource.rewriting("![화면](/etc/passwd)", transform) == "![화면](/etc/passwd)")
        #expect(ChatImageSource.rewriting("보통 문장 ![화면](\(shot.path) \"제목\")", transform) == "보통 문장 ![화면](chat-image://image/deadbeef \"제목\")")
        #expect(ChatImageSource.rewriting("[링크](\(shot.path))", transform) == "[링크](\(shot.path))")
        #expect(ChatImageSource.rewriting("![](\(shot.path))", transform) == "![](chat-image://image/deadbeef)")
        #expect(ChatImageSource.rewriting("![미완성](\(shot.path)", transform) == "![미완성](\(shot.path)")
        #expect(ChatImageSource.rewriting("![백틱`포함](\(shot.path))", transform) == "![백틱`포함](\(shot.path))")
        #expect(ChatImageSource.rewriting("![화면](https://example.com/a.png)", transform) == "![화면](https://example.com/a.png)")
        let spaced = try write("my screen.png", in: root)
        let insert: (String) -> String? = { path in path == spaced.path ? "chat-image://image/cafe" : nil }
        #expect(ChatImageSource.rewriting("![화면](\(spaced.path))", insert) == "![화면](chat-image://image/cafe)")
        #expect(ChatImageSource.rewriting("![화면](\(spaced.path) \"제목\")", insert) == "![화면](chat-image://image/cafe \"제목\")")
        let keep: (String) -> String? = { _ in "/copy/내 화면.png" }
        #expect(ChatImageSource.rewriting("![화면](\(shot.path))", keep) == "![화면](</copy/내 화면.png>)")
        // A stored copy lives under a path with spaces, so knarr writes it in the angle-bracket form.
        let spacing: (String) -> String? = { path in path == spaced.path ? "chat-image://image/cafe" : nil }
        #expect(ChatImageSource.rewriting("![화면](<\(spaced.path)>)", spacing) == "![화면](chat-image://image/cafe)")
    }

    @Test func rewritingLeavesCodeAndInlineCodeUntouched() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = try write("shot.png", in: root)
        let keep: (String) -> String? = { _ in "chat-image://image/cafe" }
        // An example the reader is told to type must keep showing the path itself.
        #expect(ChatImageSource.rewriting("보세요:\n\n```\n![화면](\(shot.path))\n```\n", keep) == "보세요:\n\n```\n![화면](\(shot.path))\n```\n")
        #expect(ChatImageSource.rewriting("인라인 `![화면](\(shot.path))` 입니다", keep) == "인라인 `![화면](\(shot.path))` 입니다")
        #expect(ChatImageSource.rewriting("`` `![화면](\(shot.path))` ``", keep) == "`` `![화면](\(shot.path))` ``")
        // Windows line endings must still close the fence.
        #expect(ChatImageSource.rewriting("```\r\n![화면](\(shot.path))\r\n```\r\n", keep) == "```\r\n![화면](\(shot.path))\r\n```\r\n")
        // A real image beside the example still renders, and a longer fence closes only at its own length.
        #expect(ChatImageSource.rewriting("![A](\(shot.path))\n\n````\n![B](x)\n```\n````\n![C](\(shot.path))", keep)
            == "![A](chat-image://image/cafe)\n\n````\n![B](x)\n```\n````\n![C](chat-image://image/cafe)")
    }

    @Test func persistingChangedContentsAtSamePathKeepsBothVersions() throws {
        let root = try directory(), store = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store) }
        let shot = try write("shot.png", in: root, bytes: 32)
        let markdown = "![화면](\(shot.path))"
        let first = ChatImageSource.persisting(markdown, root: store)
        try Data(repeating: 0x42, count: 32).write(to: shot)
        let second = ChatImageSource.persisting(markdown, root: store)
        #expect(first != second)
        #expect(ChatImageSource.persisting(markdown, root: store) == second)
        let copies = try FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil)
        #expect(copies.count == 2)
        let contents = try copies.map { try Data(contentsOf: $0) }
        #expect(contents.contains(Data(repeating: 0x41, count: 32)))
        #expect(contents.contains(Data(repeating: 0x42, count: 32)))
    }

    @Test func rewritingParenthesizedImagePathsPreservesTitles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = try write("shot (1).png", in: root)
        let insert: (String) -> String? = { $0 == shot.path ? "chat-image://image/cafe" : nil }
        #expect(ChatImageSource.rewriting("![화면](<\(shot.path)>)", insert) == "![화면](chat-image://image/cafe)")
        #expect(ChatImageSource.rewriting("![화면](<\(shot.path)> \"제목 (확인)\")", insert) == "![화면](chat-image://image/cafe \"제목 (확인)\")")
        let nested = try write("shot(1(2)).png", in: root)
        #expect(ChatImageSource.rewriting("![화면](\(nested.path))") { $0 == nested.path ? "chat-image://image/cafe" : nil } == "![화면](chat-image://image/cafe)")
    }

    @Test func transcriptServesOnlyImagesItWasShown() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = try write("shot.png", in: root)
        let hidden = try write("other.png", in: root)
        let resolver = ChatImageResolver()
        let address = resolver.register(try #require(ChatImageSource.url(forPath: shot.path)))
        #expect(address.hasPrefix("chat-image://image/"))
        #expect(resolver.resolve(try #require(URL(string: address))) == shot)
        #expect(resolver.resolve(URL(string: "chat-image://image/" + ChatImageSource.identifier(for: hidden))!) == nil)
        #expect(resolver.resolve(URL(fileURLWithPath: shot.path)) == nil)
        #expect(resolver.resolve(URL(string: "chat-image://other/" + ChatImageSource.identifier(for: shot))!) == nil)
    }
}
