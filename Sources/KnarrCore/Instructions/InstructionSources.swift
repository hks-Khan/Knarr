import Foundation
import CryptoKit

/// The user-owned instruction tree. One loader serves both roles and every editor.
///
/// Layout under `<dataDirectory>`:
///
///     instructions/common/AGENTS.md      background shared by Stallari and Hird
///     instructions/common/RULES.md       short rules carried on every request
///     instructions/stallari/AGENTS.md    Stallari background (launch-time system prompt)
///     instructions/stallari/RULES.md     Stallari operating rules (per request)
///     instructions/hird/AGENTS.md        Hird background (launch-time system prompt)
///     instructions/hird/RULES.md         Hird rules (every worker run)
///     instructions/projects/<id>/AGENTS.md
///     instructions/projects/<id>/RULES.md
///
/// `AGENTS.md` is session background ordered common → role → project. `RULES.md` is sticky rules
/// in the same order, re-read for every Stallari request and every Hird change run. A project's
/// repository `AGENTS.md` is discovered by OMP inside the Hird work copy and is never copied here.
///
/// Files may only change through `save` (atomic, expected-hash checked) or the app-owned
/// `write_instruction_file` tool. Instruction files grant no tools, ownership or approvals.
public enum InstructionRole: String, Sendable, Hashable, CaseIterable {
    case common, stallari, hird, project
}

public enum InstructionKind: String, Sendable, Hashable, CaseIterable {
    case agents = "AGENTS.md"
    case rules = "RULES.md"
    /// Stable tool/UI token; `rawValue` is the file name and never crosses the RPC boundary.
    public var token: String { self == .agents ? "agents" : "rules" }
    public init?(token: String) { self.init(rawValue: token == "agents" ? "AGENTS.md" : token == "rules" ? "RULES.md" : "") }
}

public struct InstructionSource: Sendable, Hashable, Identifiable {
    public let path: String
    public let role: InstructionRole
    public let projectID: String?
    public let kind: InstructionKind
    public let text: String
    public let version: String
    public let migratedFrom: String?

    public var id: String { "\(role.rawValue):\(kind.rawValue):\(projectID ?? "-")" }
    public var title: String {
        switch role {
        case .common: "공통 \(kind == .agents ? "배경" : "규칙")"
        case .stallari: "Stallari \(kind == .agents ? "배경" : "규칙")"
        case .hird: "Hird \(kind == .agents ? "배경" : "규칙")"
        case .project: "프로젝트 \(kind == .agents ? "배경" : "규칙")"
        }
    }
}

public struct InstructionSet: Sendable, Hashable {
    public let role: InstructionRole
    public let projectID: String?
    public let sources: [InstructionSource]
    /// Session background: common, role, project AGENTS.md.
    public let background: String
    /// Sticky rules: common, role, project RULES.md, carried with every request.
    public let rules: String
    public let version: String

    /// Exact text injected as the role's launch-time instruction block.
    public var prompt: String {
        [background, rules].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    public func source(_ kind: InstructionKind, role: InstructionRole, projectID: String? = nil) -> InstructionSource? {
        sources.first { $0.kind == kind && $0.role == role && $0.projectID == projectID }
    }
}

public enum InstructionSourceError: Error, LocalizedError, Sendable, Equatable {
    case unreadable(String)
    case invalidText(String)
    case tooLarge(String)
    case symlink(String)
    case invalidPath(String)
    case conflict(String)
    case missing(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): "지침 파일을 읽지 못했어요: \(path)"
        case .invalidText(let path): "지침 파일이 UTF-8 텍스트가 아니거나 비어 있어요: \(path)"
        case .tooLarge(let path): "지침 파일이 허용 크기를 넘었어요: \(path)"
        case .symlink(let path): "지침 파일 경로에 심볼릭 링크가 있어요: \(path)"
        case .invalidPath(let path): "허용된 지침 파일 경로가 아니에요: \(path)"
        case .conflict(let path): "다른 편집이 먼저 저장됐어요. 다시 읽은 뒤 저장해 주세요: \(path)"
        case .missing(let path): "지침 파일이 없어요: \(path)"
        }
    }
}

public enum InstructionSources {
    public static let directoryName = "instructions"
    /// Fail-closed text for a role whose files exist but cannot be read or validated.
    public static let failure = "The instruction files could not be read. Do not save-and-approve, approve or dispatch new work; ask the user to repair them."
    public static let maximumBytes = 256 * 1024

    /// Loads and seeds one role's tree. Missing files are created from the packaged defaults;
    /// present files are authoritative and are never overwritten. Any invalid present file
    /// throws, so a role never silently falls back to broader packaged guidance.
    public static func load(dataDirectory: URL, role: InstructionRole, projectID: String? = nil,
                            fileManager: FileManager = .default) throws -> InstructionSet {
        let root = dataDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try prepare(root: root, fileManager: fileManager)
        var sources: [InstructionSource] = []

        /// `initial` is written only when the file is absent. `origin` records which legacy
        /// file(s) supplied that text so the settings screen can explain the provenance.
        func read(_ role: InstructionRole, _ kind: InstructionKind, _ directory: URL, projectID: String? = nil,
                  initial: Data? = nil, origin: String? = nil) throws {
            let file = directory.appendingPathComponent(kind.rawValue)
            var migratedFrom: String?
            if !fileManager.fileExists(atPath: file.path), let initial {
                try writeInitial(initial, to: file, fileManager: fileManager)
                migratedFrom = origin
            }
            guard fileManager.fileExists(atPath: file.path) else { return }
            let data = try validatedData(at: file, kind: kind, fileManager: fileManager)
            sources.append(.init(path: file.path, role: role, projectID: projectID, kind: kind,
                                 text: String(decoding: data, as: UTF8.self), version: digest(data), migratedFrom: migratedFrom))
        }
        /// A legacy file only becomes the seed after it validates; a broken one fails the load.
        func legacyInitial(_ file: URL) throws -> Data {
            try validatedData(at: file, kind: .rules, fileManager: fileManager)
        }

        let common = root.appendingPathComponent(InstructionRole.common.rawValue, isDirectory: true)
        try read(.common, .agents, common, initial: packagedData("common/AGENTS.md"))
        // The former `<dataDirectory>/rules/*.md` set is migrated once, in filename order, and
        // the old files stay untouched. Nothing injects both paths afterwards.
        if let legacy = try legacyRules(dataDirectory, fileManager: fileManager) {
            try read(.common, .rules, common, initial: legacy.data, origin: legacy.files.map(\.path).joined(separator: ", "))
        } else {
            try read(.common, .rules, common, initial: packagedData("common/RULES.md"))
        }

        switch role {
        case .stallari:
            let directory = root.appendingPathComponent(InstructionRole.stallari.rawValue, isDirectory: true)
            try read(.stallari, .agents, directory, initial: packagedData("stallari/AGENTS.md"))
            // The pre-hierarchy execution policy is only a migration source; it is never rewritten.
            let policy = dataDirectory.appendingPathComponent("stallari/execution-policy.md")
            if fileManager.fileExists(atPath: policy.path) {
                try read(.stallari, .rules, directory, initial: try legacyInitial(policy), origin: policy.path)
            } else {
                try read(.stallari, .rules, directory, initial: packagedData("stallari/RULES.md"))
            }
        case .hird:
            let directory = root.appendingPathComponent(InstructionRole.hird.rawValue, isDirectory: true)
            // Mode-rendered role policy stays in `hird/instructions.md`; this tree only adds
            // background and sticky rules, so no text is injected twice.
            try read(.hird, .agents, directory, initial: packagedData("hird/AGENTS.md"))
            try read(.hird, .rules, directory, initial: packagedData("hird/RULES.md"))
        case .common, .project:
            break
        }

        if let projectID, validProjectID(projectID) {
            let directory = root.appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(projectID, isDirectory: true)
            try prepareDirectory(directory, fileManager: fileManager)
            try read(.project, .agents, directory, projectID: projectID)
            try read(.project, .rules, directory, projectID: projectID)
        }
        return compose(role: role, projectID: projectID, sources: sources)
    }

    /// Only the packaged defaults, for environments without a data directory (previews and tests).
    public static func packaged(role: InstructionRole) -> InstructionSet {
        var sources: [InstructionSource] = []
        func add(_ role: InstructionRole, _ kind: InstructionKind, _ text: String?) {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let data = Data(text.utf8)
            sources.append(.init(path: "bundle:\(role.rawValue)/\(kind.rawValue)", role: role, projectID: nil,
                                 kind: kind, text: text, version: digest(data), migratedFrom: nil))
        }
        add(.common, .agents, resource("common/AGENTS.md"))
        add(.common, .rules, resource("common/RULES.md"))
        if role == .stallari {
            add(.stallari, .agents, resource("stallari/AGENTS.md"))
            add(.stallari, .rules, resource("stallari/RULES.md"))
        } else if role == .hird {
            add(.hird, .agents, resource("hird/AGENTS.md"))
            add(.hird, .rules, resource("hird/RULES.md"))
        }
        return compose(role: role, projectID: nil, sources: sources)
    }

    /// Common, then the role, then this project's files only. Sources from another project are
    /// never mixed in, even if the caller passes them.
    public static func compose(role: InstructionRole, projectID: String?, sources: [InstructionSource]) -> InstructionSet {
        let ordered: [InstructionRole] = role == .project ? [.common] : [.common, role]
        func text(_ kind: InstructionKind) -> String {
            sources.filter {
                $0.kind == kind && (ordered.contains($0.role) || ($0.role == .project && $0.projectID == projectID))
            }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        }
        let background = text(.agents), rules = text(.rules)
        let version = digest(Data((background + "\n\n" + rules).utf8))
        return .init(role: role, projectID: projectID, sources: sources, background: background, rules: rules, version: version)
    }

    /// Re-reads the sticky rules for the next request. Stallari calls this per follow-up.
    public static func loadRules(dataDirectory: URL, role: InstructionRole, projectID: String?,
                                 fileManager: FileManager = .default) throws -> (text: String, version: String, set: InstructionSet) {
        let set = try load(dataDirectory: dataDirectory, role: role, projectID: projectID, fileManager: fileManager)
        return (set.rules, set.version, set)
    }

    /// Atomic save through the only writable instruction path. `expectedHash` is the version the
    /// caller read; a mismatch or a missing file is a conflict, never an overwrite.
    @discardableResult
    public static func save(dataDirectory: URL, role: InstructionRole, kind: InstructionKind, projectID: String?,
                            text: String, expectedHash: String, fileManager: FileManager = .default) throws -> InstructionSource {
        let root = dataDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try prepare(root: root, fileManager: fileManager)
        let file = try url(dataDirectory: dataDirectory, role: role, kind: kind, projectID: projectID)
        try checkAncestors(file, root: dataDirectory, fileManager: fileManager)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = text.data(using: .utf8), data.count <= maximumBytes, !text.contains("\0") else {
            throw InstructionSourceError.invalidText(file.path)
        }
        guard fileManager.fileExists(atPath: file.path) else { throw InstructionSourceError.missing(file.path) }
        let current = try validatedData(at: file, kind: kind, fileManager: fileManager)
        guard digest(current) == expectedHash else { throw InstructionSourceError.conflict(file.path) }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            defer { try? fileManager.removeItem(at: temporary) }
            _ = try fileManager.replaceItemAt(file, withItemAt: temporary, backupItemName: nil, options: [.usingNewMetadataOnly])
        } catch {
            throw InstructionSourceError.unreadable(file.path)
        }
        return .init(path: file.path, role: role, projectID: projectID, kind: kind,
                     text: text, version: digest(data), migratedFrom: nil)
    }

    public static func read(dataDirectory: URL, role: InstructionRole, kind: InstructionKind,
                            projectID: String?, fileManager: FileManager = .default) throws -> InstructionSource {
        let file = try url(dataDirectory: dataDirectory, role: role, kind: kind, projectID: projectID)
        let data = try validatedData(at: file, kind: kind, fileManager: fileManager)
        return .init(path: file.path, role: role, projectID: projectID, kind: kind,
                     text: String(decoding: data, as: UTF8.self), version: digest(data), migratedFrom: nil)
    }

    /// Every editable file for the settings screen: common, both roles and, when given, one project.
    public static func sources(dataDirectory: URL, projectID: String? = nil,
                               fileManager: FileManager = .default) throws -> [InstructionSource] {
        var result: [InstructionSource] = []
        for role in [InstructionRole.common, .stallari, .hird] where role != .common {
            let set = try load(dataDirectory: dataDirectory, role: role, projectID: projectID, fileManager: fileManager)
            for kind in InstructionKind.allCases {
                if let source = set.source(kind, role: .common) { result.append(source) }
                if let source = set.source(kind, role: role) { result.append(source) }
                if let source = set.source(kind, role: .project, projectID: projectID) { result.append(source) }
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.path).inserted }
    }

    public static func url(dataDirectory: URL, role: InstructionRole, kind: InstructionKind, projectID: String?) throws -> URL {
        let root = dataDirectory.appendingPathComponent(directoryName, isDirectory: true)
        switch role {
        case .common: return root.appendingPathComponent("common").appendingPathComponent(kind.rawValue)
        case .stallari: return root.appendingPathComponent("stallari").appendingPathComponent(kind.rawValue)
        case .hird: return root.appendingPathComponent("hird").appendingPathComponent(kind.rawValue)
        case .project:
            guard let projectID, validProjectID(projectID) else { throw InstructionSourceError.invalidPath(String(describing: projectID)) }
            return root.appendingPathComponent("projects").appendingPathComponent(projectID).appendingPathComponent(kind.rawValue)
        }
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func prepare(root: URL, fileManager: FileManager) throws {
        try prepareDirectory(root, fileManager: fileManager)
        for role in [InstructionRole.common, .stallari, .hird] {
            try prepareDirectory(root.appendingPathComponent(role.rawValue), fileManager: fileManager)
        }
        try prepareDirectory(root.appendingPathComponent("projects"), fileManager: fileManager)
    }
    private static func prepareDirectory(_ url: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: url.path) {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isSymbolicLink != true, values?.isDirectory == true else { throw InstructionSourceError.symlink(url.path) }
            return
        }
        do { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { throw InstructionSourceError.unreadable(url.path) }
    }
    /// Rejects symlinked role/project directories before a write can follow them.
    private static func checkAncestors(_ file: URL, root: URL, fileManager: FileManager) throws {
        var current = file.deletingLastPathComponent()
        while current.path.count > root.path.count {
            let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isSymbolicLink != true, values?.isDirectory == true else { throw InstructionSourceError.symlink(current.path) }
            current.deleteLastPathComponent()
        }
    }
    private static func writeInitial(_ data: Data, to file: URL, fileManager: FileManager) throws {
        do { try data.write(to: file, options: .withoutOverwriting) }
        catch {
            // A concurrent creator wins; the existing file is authoritative.
            guard fileManager.fileExists(atPath: file.path) else { throw InstructionSourceError.unreadable(file.path) }
        }
    }
    private static func validatedData(at file: URL, kind: InstructionKind, fileManager: FileManager) throws -> Data {
        let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values?.isSymbolicLink != true, values?.isRegularFile == true else { throw InstructionSourceError.symlink(file.path) }
        guard let data = try? Data(contentsOf: file) else { throw InstructionSourceError.unreadable(file.path) }
        guard data.count <= maximumBytes else { throw InstructionSourceError.tooLarge(file.path) }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw InstructionSourceError.invalidText(file.path)
        }
        if kind == .rules, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw InstructionSourceError.invalidText(file.path)
        }
        return data
    }
    private static func validProjectID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\") && !id.contains("\0")
    }
    private static func packagedData(_ name: String) -> Data? {
        (Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "instructions")
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "instructions"))
            .flatMap { try? Data(contentsOf: $0) }
    }
    private static func resource(_ name: String) -> String? {
        packagedData(name).map { String(decoding: $0, as: UTF8.self) }
    }
    /// Concatenates the retired `<dataDirectory>/rules/*.md` files once. Unreadable or invalid
    /// legacy files fail the load rather than being silently dropped.
    private static func legacyRules(_ dataDirectory: URL, fileManager: FileManager) throws -> (data: Data, files: [URL])? {
        let directory = dataDirectory.appendingPathComponent("rules", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path),
              let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return nil }
        let readable = files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !readable.isEmpty else { return nil }
        var parts: [String] = []
        for file in readable {
            let data = try validatedData(at: file, kind: .rules, fileManager: fileManager)
            parts.append("## Knarr owned rule: \(file.lastPathComponent)\n" + String(decoding: data, as: UTF8.self))
        }
        return (Data(parts.joined(separator: "\n\n").utf8), readable)
    }
}
