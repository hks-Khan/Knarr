import Foundation
import CryptoKit

/// One socket path rule shared by the app host and the stdio bridge. The socket lives inside
/// the person's private Knarr data folder; when that path is too long for `sun_path`, both
/// sides fall back to the same per-user file in the temporary directory.
public enum MCPPaths {
    public static let socketFileName = "knarr.sock"
    public static let directoryName = "mcp"
    /// macOS allows 104 bytes including the terminating NUL.
    static let maximumSocketPathBytes = 100

    public static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["KNARR_DATA_DIRECTORY"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Knarr", isDirectory: true)
    }

    public static func socketPath(dataDirectory: URL,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["KNARR_MCP_SOCKET"], override.hasPrefix("/") { return override }
        let preferred = dataDirectory.appendingPathComponent(directoryName).appendingPathComponent(socketFileName).path
        if preferred.utf8.count <= maximumSocketPathBytes { return preferred }
        let hash = SHA256.hash(data: Data(dataDirectory.standardizedFileURL.path.utf8))
            .prefix(10).map { String(format: "%02x", $0) }.joined()
        return "/tmp/knarr-mcp-\(getuid())-\(hash)/knarr.sock"
    }
}
