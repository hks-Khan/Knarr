import Foundation

/// Public RPC projections only. Never persist system-prompt bodies or extension code.
public struct HirdRuntimeResources: Codable, Sendable, Hashable {
    public let contextFiles: [String]
    public let skills: [String]
    /// 18.7.0 exposes registered commands, not a complete extension-module manifest.
    public let extensionCommands: [String]
    /// Explicit CLI allowlist; successful trusted imports are required by OMP startup.
    public let trustedExtensions: [String]
    public let externalExtensionsDisabled: Bool
    public let capturedAt: Date

    static func capture(state: OMPJSON, commands: OMPJSON, trustedExtensions: [String], at: Date) -> Self {
        let prompt = (state["systemPrompt"]?.array ?? []).compactMap(\.string).joined(separator: "\n")
        var paths: [String] = []
        if let section = prompt.range(of: "<repo-rules>"), let end = prompt.range(of: "</repo-rules>", range: section.upperBound..<prompt.endIndex) {
            let rules = String(prompt[section.upperBound..<end.lowerBound])
            if let regex = try? NSRegularExpression(pattern: #"<file path="([^"]+)">"#) {
                paths = regex.matches(in: rules, range: NSRange(rules.startIndex..., in: rules)).compactMap {
                    Range($0.range(at: 1), in: rules).map { String(rules[$0]) }
                }
            }
        }
        var skills: [String] = []
        if let start = prompt.range(of: "<skills>"), let end = prompt.range(of: "</skills>", range: start.upperBound..<prompt.endIndex) {
            skills = prompt[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { line in
                guard line.hasPrefix("- "), let colon = line.firstIndex(of: ":") else { return nil }
                return String(line[line.index(line.startIndex, offsetBy: 2)..<colon])
            }
        }
        let entries = commands["commands"]?.array ?? []
        return .init(contextFiles: Array(Set(paths)).sorted(), skills: Array(Set(skills)).sorted(),
                     extensionCommands: entries.filter { $0["source"]?.string == "extension" }.compactMap { $0["name"]?.string }.sorted(),
                     trustedExtensions: trustedExtensions, externalExtensionsDisabled: true, capturedAt: at)
    }
}

public struct HirdLSPRecord: Codable, Sendable, Hashable {
    public let action: String
    public let file: String?
    public let server: String?
    public let succeeded: Bool
    public let logPath: String
    public let finishedAt: Date
}
