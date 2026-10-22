import Foundation
import Darwin

public struct ProjectDocument: Identifiable, Sendable, Hashable {
    public enum GitStatus: Sendable, Hashable { case clean, uncommitted, new }

    public var id: String { relativePath }
    public let relativePath: String
    public let text: String
    public let modifiedAt: Date
    public let gitStatus: GitStatus

    public init(relativePath: String, text: String, modifiedAt: Date, gitStatus: GitStatus) {
        self.relativePath = relativePath
        self.text = text
        self.modifiedAt = modifiedAt
        self.gitStatus = gitStatus
    }
}

/// A point-in-time read. The document text is retained for rendering and searching without more disk reads.
public struct ProjectDocumentLibrary: Sendable {
    public let documents: [ProjectDocument]
    public let problem: String?

    public init(documents: [ProjectDocument], problem: String? = nil) {
        self.documents = documents
        self.problem = problem
    }

    public static func read(root: URL) async -> Self {
        await Task.detached(priority: .userInitiated) {
            await load(root: root)
        }.value
    }

    public func search(_ query: String) -> [ProjectDocument] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return documents }
        return documents.filter {
            $0.relativePath.range(of: query, options: .caseInsensitive) != nil ||
                $0.text.range(of: query, options: .caseInsensitive) != nil
        }
    }

    private struct FileText {
        let path: String
        let text: String
        let modifiedAt: Date
    }

    private static func load(root: URL) async -> Self {
        let descriptor: Int32
        do { descriptor = try HirdSecureFile.openDirectory(root) }
        catch { return .init(documents: [], problem: "프로젝트 폴더를 읽지 못했어요") }
        defer { _ = Darwin.close(descriptor) }
        async let gitStatus = status(root: root)
        var files: [FileText] = []
        var problems: [String] = []
        collect(directory: descriptor, prefix: "", files: &files, problems: &problems)
        let statuses = await gitStatus
        if statuses == nil { problems.append("문서의 Git 상태를 읽지 못했어요") }
        let documents = files.map {
            ProjectDocument(relativePath: $0.path, text: $0.text, modifiedAt: $0.modifiedAt,
                            gitStatus: statuses?.changes[$0.path] ?? (statuses?.tracked.contains($0.path) == false ? .new : .clean))
        }.sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.relativePath < $1.relativePath : $0.modifiedAt > $1.modifiedAt
        }
        return .init(documents: documents, problem: problems.isEmpty ? nil : problems.joined(separator: "\n"))
    }

    private static let excludedDirectories: Set<String> = [
        ".git", ".build", "node_modules", "outputs", ".worktrees", ".claude"
    ]

    /// Descriptor-relative traversal never follows a symlink, even if a directory is replaced while reading.
    private static func collect(directory: Int32, prefix: String, files: inout [FileText], problems: inout [String]) {
        let copy = dup(directory)
        guard copy >= 0 else { problems.append("문서 폴더를 읽지 못했어요: \(prefix)"); return }
        guard let stream = fdopendir(copy) else {
            _ = Darwin.close(copy)
            problems.append("문서 폴더를 읽지 못했어요: \(prefix)")
            return
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { problems.append("문서 목록을 읽지 못했어요: \(prefix)") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let lowered = name.lowercased()
            let path = prefix.isEmpty ? name : prefix + "/" + name
            // Rules and environment files are not project documents and their bodies are never opened.
            if lowered == "agents.md" || lowered == "claude.md" || lowered.hasPrefix(".env") ||
                path.lowercased() == ".github/copilot-instructions.md" { continue }
            var metadata = stat()
            guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                problems.append("문서 정보를 읽지 못했어요: \(path)")
                continue
            }
            let kind = metadata.st_mode & S_IFMT
            if kind == S_IFDIR {
                guard !excludedDirectories.contains(lowered) else { continue }
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else { problems.append("문서 폴더를 읽지 못했어요: \(path)"); continue }
                collect(directory: child, prefix: path, files: &files, problems: &problems)
                _ = Darwin.close(child)
            } else if kind == S_IFREG && (name as NSString).pathExtension.lowercased() == "md" {
                do {
                    let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                    guard descriptor >= 0 else { throw HirdError.workspace }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    defer { try? handle.close() }
                    var opened = stat()
                    guard fstat(descriptor, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG else { throw HirdError.workspace }
                    let bytes = try handle.readToEnd() ?? Data()
                    guard let text = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                    let modifiedAt = Date(timeIntervalSince1970: Double(opened.st_mtimespec.tv_sec) + Double(opened.st_mtimespec.tv_nsec) / 1_000_000_000)
                    files.append(.init(path: path, text: text, modifiedAt: modifiedAt))
                } catch {
                    problems.append("문서를 읽지 못했어요: \(path)")
                }
            }
        }
    }

    private static func status(root: URL) async -> (changes: [String: ProjectDocument.GitStatus], tracked: Set<String>)? {
        guard let text = try? await HirdWorkspace.git([
            "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=no", "--", "."
        ], at: root) else { return nil }
        // Ignored Markdown still belongs in the document library. The index distinguishes
        // committed/tracked files from ignored untracked documents without walking ignored build output.
        guard let tracked = try? await HirdWorkspace.git(["ls-files", "-z", "--cached", "--", "."], at: root) else { return nil }
        // -z emits the rename destination first, followed by the old name in its own NUL field.
        let records = text.split(separator: "\0", omittingEmptySubsequences: false)
        var result: [String: ProjectDocument.GitStatus] = [:]
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.utf8.count >= 4 else { continue }
            let code = record.prefix(2)
            let path = String(record.dropFirst(3))
            result[path] = code == "??" || code.contains("A") ? .new : .uncommitted
            if code.contains("R") || code.contains("C") { index += 1 }
        }
        return (result, Set(tracked.split(separator: "\0").map(String.init)))
    }
}
