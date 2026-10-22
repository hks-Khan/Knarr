import Foundation

/// App-owned, in-memory credential preparation shared by every owned OMP launch.
/// A prepared credential is not a verified connection.
public final class HiveProviderRuntime: @unchecked Sendable, CustomDebugStringConvertible, CustomReflectable {
    public static let modelIdentifier = "hive/deepseek-ai/deepseek-v4.1-flash-1017"

    /// Upgrade defaults/new proposals only; persisted proposal and run records retain their model.
    static func currentModelIdentifier(_ model: String) -> String {
        model == "hive/deepseek-ai/deepseek-v4.1-flash" ? modelIdentifier : model
    }
    private let lock = NSLock()
    private var credential: HiveLaunchCredential?
    private let baseURL: URL

    public convenience init() {
        self.init(baseURL: URL(string: "https://api-cdn.thehive.ai/api/v3")!)
    }

    // Only local protocol fixtures may replace the production endpoint.
    init(baseURL: URL) { self.baseURL = baseURL }

    public var isPrepared: Bool { lock.withLock { credential != nil } }

    public static func validateCredential(_ key: String) throws {
        guard key.contains(where: { !$0.isWhitespace }),
              key.utf8.count <= 4095,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HiveProviderError.invalidCredential
        }
    }

    public func replaceCredential(_ key: String?) throws {
        if let key { try Self.validateCredential(key) }
        let replacement = key.map { HiveLaunchCredential(bytes: Data($0.utf8)) }
        lock.withLock { credential = replacement }
    }

    func configure(_ configuration: OMPLaunchConfiguration) throws -> OMPLaunchConfiguration {
        guard let snapshot = lock.withLock({ credential }) else { return configuration }
        let resource = Bundle.main.url(forResource: "provider", withExtension: "ts", subdirectory: "hive")
            ?? Bundle.module.url(forResource: "provider", withExtension: "ts", subdirectory: "hive")
        guard let resource else { throw HiveProviderError.unavailableResource }
        let endpoint = String(decoding: try JSONEncoder().encode(baseURL.absoluteString), as: UTF8.self)
        let source = try String(contentsOf: resource, encoding: .utf8)
            .replacingOccurrences(of: "__KNARR_HIVE_BASE_URL__", with: endpoint)
        let configIndex = configuration.arguments.firstIndex(of: "--config")
        let directory: URL
        if let configIndex, configIndex + 1 < configuration.arguments.count {
            directory = URL(fileURLWithPath: configuration.arguments[configIndex + 1]).deletingLastPathComponent()
        } else {
            directory = configuration.workingDirectory
        }
        let provider = directory.appendingPathComponent("hive-provider.ts")
        try source.write(to: provider, atomically: true, encoding: .utf8)
        var result = configuration
        result.arguments += ["--trusted-extension", provider.path]
        result.hiveCredential = snapshot
        return result
    }

    public var debugDescription: String { "HiveProviderRuntime(prepared: \(isPrepared))" }
    public var customMirror: Mirror { Mirror(self, children: ["prepared": isPrepared]) }
}

public enum HiveProviderError: Error, LocalizedError, Sendable {
    case invalidCredential
    case unavailableResource

    public var errorDescription: String? {
        switch self {
        case .invalidCredential: "Hive API 키 형식을 확인해 주세요. 제어 문자 없이 1~4095바이트로 입력해 주세요."
        case .unavailableResource: "앱에 포함된 Hive 공급자를 불러오지 못했어요."
        }
    }
}

/// Never expose credential bytes through configuration or reflection diagnostics.
struct HiveLaunchCredential: Sendable, CustomDebugStringConvertible, CustomReflectable {
    let bytes: Data
    var debugDescription: String { "<redacted>" }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}
