import Foundation
import Darwin

/// Explicit app-owned modules, not an OMP replacement loader or an OS sandbox.
public struct KnarrExtensions: Sendable {
    public enum Role: String, Sendable { case stallari, hird }
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }
    public func directory(_ role: Role) -> URL { root.appendingPathComponent("extensions/" + role.rawValue, isDirectory: true) }

    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // The retired `rules/` folder is left untouched; its Markdown is migrated once into
        // `instructions/common/RULES.md` by InstructionSources.
        for path in [root.appendingPathComponent("extensions"), directory(.stallari), directory(.hird), root.appendingPathComponent("skills")] {
            if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw StallariError.invalidArguments }
            try fm.createDirectory(at: path, withIntermediateDirectories: true)
        }
    }
    public func files(for role: Role) throws -> [URL] {
        try prepare()
        let parent = directory(role)
        var files: [URL] = []
        for url in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let suffix = url.pathExtension
            guard suffix == "ts" || suffix == "js" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw StallariError.invalidArguments }
            // Foundation may canonicalize /var to /private/var during enumeration.
            // Keep the injected root's path identity in launch arguments and errors.
            if values.isRegularFile == true { files.append(parent.appendingPathComponent(url.lastPathComponent)) }
        }
        files.sort { $0.lastPathComponent < $1.lastPathComponent }
        return files
    }
    public func arguments(for role: Role, policy: URL? = nil) throws -> [String] {
        let files = try files(for: role)
        var arguments: [String] = []
        arguments.reserveCapacity((files.count + (policy == nil ? 0 : 1)) * 2)
        if let policy { arguments.append("--trusted-extension"); arguments.append(policy.path) }
        for file in files { arguments.append("--trusted-extension"); arguments.append(file.path) }
        return arguments
    }
    @discardableResult public func writeStallari(name: String, source: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains(".."), !name.contains("\0"),
              ["ts", "js"].contains(URL(fileURLWithPath: name).pathExtension) else { throw StallariError.invalidArguments }
        try prepare()
        // Pin each owned directory without following symlinks, including parent replacement races.
        let owner = open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard owner >= 0 else { throw StallariError.invalidArguments }
        defer { close(owner) }
        let container = openat(owner, "extensions", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard container >= 0 else { throw StallariError.invalidArguments }
        defer { close(container) }
        let parent = openat(container, "stallari", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw StallariError.invalidArguments }
        defer { close(parent) }
        let file = openat(parent, name, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw StallariError.invalidArguments }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, ftruncate(file, 0) == 0 else { throw StallariError.invalidArguments }
        var text = source
        try text.withUTF8 { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw StallariError.invalidArguments }
                offset += written
            }
        }
        return directory(.stallari).appendingPathComponent(name)
    }
}
