import Foundation
import CryptoKit

/// Stallari points at screenshots with ordinary Markdown. Knarr decides which of those paths it
/// will read, serves them to the web transcript under its own scheme, and keeps a durable copy
/// beside the app's records so a restart still shows the picture.
public enum ChatImageSource {
    /// The scheme the transcript asks for; the file bytes never travel through the page script.
    public static let scheme = "chat-image"
    /// One inline screenshot; larger files stay out of the transcript and the copy.
    public static let maximumBytes = 10_000_000
    /// Extensions Knarr renders. Anything else stays plain text, so no HTML or script is opened.
    public static let types: [String: String] = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "heic": "image/heic"]
    /// Folders whose contents hold credentials; a picture from one of them is never shown.
    private static let denied: Set<String> = [".ssh", ".aws", ".gnupg", ".config", ".env", "credentials", ".netrc"]
    private static let deniedSuffixes = [".env", ".pem", ".key", ".p12", ".pfx"]

    /// A transcript image URL for a readable local image, or nil when Knarr must not read it.
    /// Only resolved absolute paths inside this Mac's file system qualify.
    public static func url(forPath path: String) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.utf8.contains(where: { $0 < 0x20 }) else { return nil }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        guard types[url.pathExtension.lowercased()] != nil, !name.hasPrefix("."),
              !deniedSuffixes.contains(where: { name.hasSuffix($0) }) else { return nil }
        // A linked file hides where the bytes really come from; a linked directory can hide it too.
        guard let linked = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), linked.isSymbolicLink != true else { return nil }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !resolved.pathComponents.dropFirst().contains(where: { denied.contains($0.lowercased()) }) else { return nil }
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= maximumBytes else { return nil }
        return resolved
    }

    public static func mimeType(for url: URL) -> String? { types[url.pathExtension.lowercased()] }

    /// A URL that depends only on the path, so the same screenshot keeps one address.
    public static func identifier(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Rewrites `![설명](/절대/경로)` Markdown. Anything Knarr will not read keeps its original text,
    /// and the alt text, title and every other byte survive untouched. Fenced blocks and code spans
    /// are copied verbatim: a path shown as an example is a path the reader is told to type.
    public static func rewriting(_ text: String, _ transform: (String) -> String?) -> String {
        guard text.contains("![") else { return text }
        var fence: (character: Character, length: Int)?
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let open = fence {
                if isFenceLine(line, character: open.character, minimum: open.length) { fence = nil }
                return String(line)
            }
            if let open = fenceOpening(line) { fence = open; return String(line) }
            return rewriteInline(String(line), transform)
        }
        return lines.joined(separator: "\n")
    }

    /// A fence-opening line: up to three spaces, then three or more backticks or tildes, then nothing
    /// but the info string (which may not hold another backtick when the marker is a backtick).
    private static func fenceOpening(_ line: Substring) -> (character: Character, length: Int)? {
        let body = line.drop { $0 == " " }
        let trimmed = body.last == "\r" ? body.dropLast() : body
        guard line.count - body.count <= 3, let character = trimmed.first, character == "`" || character == "~" else { return nil }
        let marker = trimmed.prefix { $0 == character }
        guard marker.count >= 3, character != "`" || !trimmed.dropFirst(marker.count).contains("`") else { return nil }
        return (character, marker.count)
    }

    /// A fence-closing line: the same marker, at least as long as the opening one, nothing else.
    private static func isFenceLine(_ line: Substring, character: Character, minimum: Int) -> Bool {
        let body = line.drop { $0 == " " }
        let trimmed = body.last == "\r" ? body.dropLast() : body
        guard line.count - body.count <= 3 else { return false }
        let marker = trimmed.prefix { $0 == character }
        return marker.count >= minimum && trimmed.dropFirst(marker.count).allSatisfy { $0 == " " }
    }

    /// One line without a fence: images are rewritten, code spans are left alone.
    private static func rewriteInline(_ line: String, _ transform: (String) -> String?) -> String {
        guard line.contains("![") else { return line }
        let characters = Array(line)
        var result = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "`" {
                var openCount = 0
                while index + openCount < characters.count, characters[index + openCount] == "`" { openCount += 1 }
                var cursor = index + openCount
                var close = -1
                while cursor < characters.count, close < 0 {
                    guard characters[cursor] == "`" else { cursor += 1; continue }
                    var count = 0
                    while cursor + count < characters.count, characters[cursor + count] == "`" { count += 1 }
                    if count == openCount { close = cursor; break }
                    cursor += count
                }
                guard close >= 0 else { result += String(characters[index]); index += 1; continue }
                result += String(characters[index..<(close + openCount)])
                index = close + openCount
                continue
            }
            if characters[index] == "!", index + 1 < characters.count, characters[index + 1] == "[",
               let image = inlineImage(characters, from: index, transform) {
                result += image.rewritten
                index = image.next
                continue
            }
            result += String(characters[index])
            index += 1
        }
        return result
    }

    /// One `![alt](destination)` starting at `start`, already past every code span. `next` is the
    /// offset to continue scanning from.
    private static func inlineImage(_ characters: [Character], from start: Int, _ transform: (String) -> String?) -> (rewritten: String, next: Int)? {
        guard let labelEnd = characters[start...].firstIndex(of: "]"), labelEnd + 1 < characters.count,
              characters[labelEnd + 1] == "(" else { return nil }
        let destinationStart = labelEnd + 2
        var cursor = destinationStart, nesting = 1
        var angle = false
        var quote: Character?
        var closing: Int?
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\\" { cursor += 2; continue }
            if angle {
                if character == ">" { angle = false }
            } else if let delimiter = quote {
                if character == delimiter { quote = nil }
            } else if character == "<", cursor == destinationStart {
                angle = true
            } else if (character == "\"" || character == "'"), cursor > destinationStart,
                      characters[cursor - 1].isWhitespace {
                quote = character
            } else if character == "(" {
                nesting += 1
            } else if character == ")" {
                nesting -= 1
                if nesting == 0 { closing = cursor; break }
            }
            cursor += 1
        }
        guard let close = closing else { return nil }
        let label = String(characters[(start + 2)..<labelEnd])
        let destination = String(characters[(labelEnd + 2)..<close])
        return (rewrite(prefix: "![", label: label, destination: destination, suffix: ")", transform), close + 1)
    }

    private static func rewrite(prefix: String, label: String, destination: String, suffix: String, _ transform: (String) -> String?) -> String {
        guard label.range(of: "`") == nil else { return prefix + label + "]" + "(" + destination + suffix }
        // Text after a quoted title is Markdown's title, but a real path can hold spaces too.
        // Try the title reading first, then the whole destination as the path.
        var readings = [(path: destination, trailer: "")]
        if let range = destination.range(of: " \"", options: .backwards) ?? destination.range(of: " '", options: .backwards) {
            readings.insert((String(destination[destination.startIndex..<range.lowerBound]), String(destination[range.lowerBound...])), at: 0)
        }
        for var reading in readings {
            if reading.path.hasPrefix("<"), reading.path.hasSuffix(">"), reading.path.count >= 2 {
                reading.path = String(reading.path.dropFirst().dropLast())
            }
            guard !reading.path.isEmpty, let replacement = transform(reading.path) else { continue }
            // Any character that would end the destination early needs the angle-bracket form.
            let bare = !replacement.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" || $0 == ">" })
            return prefix + label + "](" + (bare ? replacement : "<" + replacement + ">") + reading.trailer + suffix
        }
        return prefix + label + "](" + destination + suffix
    }

    /// The durable copy's address. Attachment copies live beside the runtime's own records.
    public static func storageRoot(forDataDirectory dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("attachments/stallari", isDirectory: true)
    }

    /// Copies every referenced local image into `root` and points the text at the copy. A path
    /// that cannot be read or copied keeps its original markdown, so a reply is never lost.
    public static func persisting(_ text: String, root: URL?) -> String {
        guard let root else { return text }
        let manager = FileManager.default
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        return rewriting(text) { path in
            guard let source = url(forPath: path) else { return nil }
            // Already beside the records; saving the same reply twice must not pile up copies.
            guard !source.path.hasPrefix(base + "/") else { return source.path }
            // A reused screenshot path may contain a new picture. Keep an immutable
            // content-addressed snapshot so both earlier and later replies stay correct.
            guard let bytes = try? Data(contentsOf: source), bytes.count <= maximumBytes else { return nil }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let name = "_" + digest + "." + source.pathExtension.lowercased()
            let destination = root.appendingPathComponent(name)
            if !manager.fileExists(atPath: destination.path) {
                do {
                    try manager.createDirectory(at: root, withIntermediateDirectories: true)
                    try bytes.write(to: destination, options: .atomic)
                } catch { return nil }
            }
            return destination.path
        }
    }
}

/// Serves the images one transcript was shown. Identifiers name the file they were minted for,
/// so the page keeps asking for what it displayed instead of probing arbitrary paths.
@MainActor public final class ChatImageResolver {
    private var table: [String: URL] = [:]
    /// Rewritten Markdown by source text. Validation touches the file system, so the same reply is
    /// only rewritten once even when the transcript is rebuilt around it.
    private var rewritten: [String: String] = [:]
    private var rewrittenOrder: [String] = []
    /// Enough for several transcripts; the names are small compared with the row images.
    private static let rewriteLimit = 800
    public init() {}
    /// Remembers one validated path under its identifier.
    public func register(_ url: URL) -> String {
        let id = ChatImageSource.identifier(for: url)
        table[id] = url
        return ChatImageSource.scheme + "://image/" + id
    }
    /// The text with its local images pointed at addresses this resolver serves.
    public func rewriting(_ text: String) -> String {
        if let cached = rewritten[text] { return cached }
        let shown = ChatImageSource.rewriting(text) { path in
            ChatImageSource.url(forPath: path).map(self.register)
        }
        rewritten[text] = shown
        rewrittenOrder.append(text)
        if rewrittenOrder.count > Self.rewriteLimit {
            let drop = rewrittenOrder.count - Self.rewriteLimit
            for key in rewrittenOrder.prefix(drop) { rewritten[key] = nil }
            rewrittenOrder.removeFirst(drop)
        }
        return shown
    }
    /// The file behind one served address, re-checked against the rules that admitted it.
    public func resolve(_ url: URL) -> URL? {
        guard url.scheme == ChatImageSource.scheme, url.host == "image" else { return nil }
        let key = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !key.isEmpty, !key.contains("/"), let cached = table[key], ChatImageSource.url(forPath: cached.path) == cached else { return nil }
        return cached
    }
}
