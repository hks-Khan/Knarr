import Foundation

/// The same packaged/runtime-file convention as HirdPolicyFiles; loaded once, never polled.
public struct ProjectSessionPolicy: Codable, Sendable, Hashable {
    public let panelDefaultWidth: Double
    public let panelMinimumWidth: Double
    public let panelDefaultCollapsed: Bool
    public let panelTitle: String
    public let panelOpenLabel: String
    public let panelCloseLabel: String
    public let composerPlaceholder: String
    public let ownershipInstructions: String
    public let roleInstructions: String
    public let handoffTemplate: String
    public let handoffMaximumCharacters: Int
    public let handoffSectionCharacters: Int
    public let handoffIssueCharacters: Int
    public let openIssueLimit: Int
    public let recentIssueLimit: Int
    public let issueHandoffMaximumCharacters: Int
    public let mirrorMaximumCharacters: Int
    public let wrongProjectMessage: String
    public let mainReadOnlyMirrorMessage: String
    /// File-owned role guidance. Older runtime files use the packaged contract until updated.
    public let transferInstructions: String?

    public static let current = try! decode(HirdPolicyFiles.resource("project-session.json"))

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.panelMinimumWidth.isFinite, value.panelMinimumWidth > 0,
              value.panelDefaultWidth.isFinite, value.panelDefaultWidth >= value.panelMinimumWidth,
              value.handoffMaximumCharacters > 0, value.handoffSectionCharacters > 0,
              value.handoffIssueCharacters > 0, value.openIssueLimit >= 0, value.recentIssueLimit >= 0,
              value.issueHandoffMaximumCharacters > 0, value.mirrorMaximumCharacters > 0,
              !value.ownershipInstructions.isEmpty, !value.roleInstructions.isEmpty, !value.handoffTemplate.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    static func load(directory: URL) throws -> Self {
        let fallback = try HirdPolicyFiles.resource("project-session.json")
        let directoryIsLink = (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        guard !directoryIsLink else { return try decode(fallback) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("project-session.json")
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                do { try fallback.write(to: file, options: [.withoutOverwriting]) }
                catch let error as CocoaError where error.code == .fileWriteFileExists { }
            }
            let attributes = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard attributes.isSymbolicLink != true, attributes.isRegularFile == true else { throw CocoaError(.fileReadNoPermission) }
            let data = try Data(contentsOf: file)
            let policy = try decode(data)
            // SHA-256 of the previous packaged ownershipInstructions; custom text stays intact.
            if ResponseRulesFile.version(of: policy.ownershipInstructions) == "4b284ff75ff5abca8cc0f87ced2630de37117bcb6279c9d9adb5f1078700c950",
               var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object["ownershipInstructions"] = current.ownershipInstructions
                let upgraded = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                // Readable settings remain usable even if the default-text upgrade cannot be saved.
                if (try? Data(contentsOf: file)) == data { try? upgraded.write(to: file, options: .atomic) }
                return try decode(upgraded)
            }
            return policy
        } catch {
            // Atomic replacement does not follow a final-component symlink.
            try? fallback.write(to: file, options: [.atomic])
            return try decode(fallback)
        }
    }

    func handoff(project: StoredProject, snapshot: PersistenceSnapshot) -> String {
        func section(_ lines: [String]) -> String { String(lines.joined(separator: "\n").prefix(handoffSectionCharacters)) }
        let issues = snapshot.issues.filter { snapshot.issueProjects[$0.id] == project.id }
        let open = issues.filter { $0.archivedAt == nil && $0.displayStatus != .completed && $0.displayStatus != .cancelled }
            .sorted { ($0.startedAt, $0.id.rawValue) > ($1.startedAt, $1.id.rawValue) }
        let recent = IssueCards.history(issues: issues)
        func summary(_ issue: Issue) -> String {
            String("issueID=\(issue.id.rawValue) · \(issue.title) · \(issue.statusLine) · \(issue.latestResult?.summary ?? issue.headline)".prefix(handoffIssueCharacters))
        }
        let replacements: [(String, String)] = [
            ("projectID", project.id), ("name", project.name), ("path", project.absolutePath),
            ("memo", String(project.settings.memo.prefix(handoffSectionCharacters))),
            ("verification", section(project.settings.verification.map { "\($0.name): \($0.command) (\($0.timing.english))" })),
            ("criteria", section(project.settings.criteria.map { "- " + $0 })),
            ("openIssues", section(open.prefix(openIssueLimit).map(summary))),
            ("recentIssues", section(recent.prefix(recentIssueLimit).map(summary)))
        ]
        let values = Dictionary(uniqueKeysWithValues: replacements)
        var text = ""
        var cursor = handoffTemplate.startIndex
        while let opening = handoffTemplate.range(of: "{{", range: cursor..<handoffTemplate.endIndex),
              let closing = handoffTemplate.range(of: "}}", range: opening.upperBound..<handoffTemplate.endIndex) {
            text.append(contentsOf: handoffTemplate[cursor..<opening.lowerBound])
            let key = String(handoffTemplate[opening.upperBound..<closing.lowerBound])
            text.append(contentsOf: values[key] ?? String(handoffTemplate[opening.lowerBound..<closing.upperBound]))
            cursor = closing.upperBound
        }
        text.append(contentsOf: handoffTemplate[cursor...])
        return String(text.prefix(handoffMaximumCharacters))
    }
}
