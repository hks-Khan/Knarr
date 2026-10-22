import Foundation

/// App-owned handoff data; no model tool can schedule installation.
public enum InstallRestart {
    public struct Job: Sendable {
        public let directory: URL
        public let candidate: URL
        public let target: URL
        public let database: URL
        public let parentPID: Int32
        public var arguments: [String] {
            [directory.appendingPathComponent("install-restart.sh").path, String(parentPID), candidate.path,
             target.path, database.path, directory.path, "/usr/bin/open"]
        }
        public func markNormalShutdown() throws {
            try Data().write(to: directory.appendingPathComponent("shutdown-ready"), options: .atomic)
        }
        /// Intentionally detached: the helper must outlive this app, never terminate it.
        public func launch() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
    }

    public static func prepare(candidate: URL, target: URL, database: URL, root: URL,
                               parentPID: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> Job {
        let fm = FileManager.default
        guard candidate.standardizedFileURL != target.standardizedFileURL,
              candidate.pathExtension == "app", target.pathExtension == "app",
              fm.fileExists(atPath: candidate.appendingPathComponent("Contents/MacOS/Knarr").path),
              fm.fileExists(atPath: target.appendingPathComponent("Contents/Info.plist").path),
              fm.fileExists(atPath: database.path),
              let script = Bundle.main.url(forResource: "install-restart", withExtension: "sh") ?? Bundle.module.url(forResource: "install-restart", withExtension: "sh") else {
            throw LiveKnarrError.installUnavailable
        }
        let directory = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let staged = directory.appendingPathComponent("candidate.app")
            try fm.copyItem(at: candidate, to: staged)
            try fm.copyItem(at: script, to: directory.appendingPathComponent("install-restart.sh"))
            return Job(directory: directory, candidate: staged, target: target, database: database, parentPID: parentPID)
        } catch { try? fm.removeItem(at: directory); throw error }
    }
}
