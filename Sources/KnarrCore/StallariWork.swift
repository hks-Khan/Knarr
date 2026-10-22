import Foundation

/// Live OMP child activity. Deliberately not Codable: RPC generations never restore workers.
public struct SubagentWork: Identifiable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var currentCommand: String?
    public let startedAt: Date
    public var lastActivityAt: Date

    public init(id: String, name: String, currentCommand: String?, startedAt: Date, lastActivityAt: Date) {
        self.id = id; self.name = name; self.currentCommand = currentCommand
        self.startedAt = startedAt; self.lastActivityAt = lastActivityAt
    }
}
