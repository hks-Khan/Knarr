import Foundation
import CryptoKit

/// Explicit discovery only: a validated bundle URL or the versioned installation root.
/// Does not use PATH, download executables, read credentials, or run login flows.
public struct OMPInstallation: Sendable {
    public static let version = "18.7.0"
    public static let revision = "18.7.0-knarr.2"
    public static let releaseURL = URL(string: "https://github.com/can1357/oh-my-pi/releases/tag/v18.7.0")!
    #if arch(arm64)
    public static let asset = "omp-darwin-arm64"
    public static let sha256 = "50fde055d40af38c6165b94990fe80397f495f5b384976995610f4a06e2a1e1e"
    #else
    public static let asset = "omp-darwin-x64"
    public static let sha256 = "ba9106e05c07be261898c7dabe662e9343776141c4a6821bcb20fa9a5ea814a4"
    #endif
    public let executable: URL
    public init(executable: URL) throws {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path),
              let data = try? Data(contentsOf: executable, options: .mappedIfSafe) else { throw OMPRPCError.launchFailed(ENOENT) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.sha256 else { throw OMPRPCError.invalidFrame("OMP release checksum mismatch") }
        self.executable = executable
    }
    public static func installed(in root: URL) throws -> OMPInstallation {
        try OMPInstallation(executable: root.appendingPathComponent(version).appendingPathComponent("omp"))
    }
}
