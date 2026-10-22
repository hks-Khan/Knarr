import Foundation
import CryptoKit
import Observation
import Security

/// Only app-owned UI/runtime code may load a saved credential. Never expose this store as a tool.
@MainActor
public protocol HiveCredentialStore {
    func load() throws -> String?
    func save(_ key: String) throws
    /// Atomic insert only. False means an existing credential was preserved.
    func insertIfAbsent(_ key: String) throws -> Bool
    func remove() throws
}

public enum HiveConnectionError: Error, LocalizedError, Sendable {
    case invalidCredential, storageUnavailable, missingCredential, verificationFailed, unsupported

    public var message: String {
        switch self {
        case .invalidCredential:
            "API 키를 확인해 주세요. 공백·줄바꿈 없이 4,095바이트 이하로 입력해 주세요."
        case .storageUnavailable:
            "API 키를 키체인에서 읽거나 변경하지 못했어요. 키체인 접근을 확인하고 다시 시도해 주세요."
        case .missingCredential:
            "Hive API 키를 먼저 저장해 주세요."
        case .verificationFailed:
            "Hive 연결을 확인하지 못했어요. API 키와 네트워크를 확인하고 다시 시도해 주세요."
        case .unsupported:
            "이 환경에서는 Hive 연결을 확인하거나 모델 목록을 새로 읽을 수 없어요."
        }
    }

    public var errorDescription: String? { message }
}

/// A successful save means prepared, not authenticated. Only an explicit provider probe verifies it.
@MainActor @Observable
public final class HiveConnection {
    public enum Status: Sendable, Equatable {
        case missing, prepared, verifying, verified, failed
    }

    public let runtime: HiveProviderRuntime
    public private(set) var status: Status = .missing
    public private(set) var message = "Hive API 키를 저장하면 사용할 준비가 돼요."
    @ObservationIgnored private let store: any HiveCredentialStore
    /// Stable per-data-directory namespace shared by Settings and the isolated entry window.
    public static func serviceNamespace(dataDirectory: URL) -> String {
        let digest = SHA256.hash(data: Data(dataDirectory.standardizedFileURL.path.utf8))
        return "com.kyen.knarr.hive." + digest.map { String(format: "%02x", $0) }.joined()
    }

    @ObservationIgnored private var generation: UInt64 = 0

    public convenience init(serviceNamespace: String, runtime: HiveProviderRuntime = .init()) {
        self.init(store: KeychainHiveCredentialStore(serviceNamespace: serviceNamespace), runtime: runtime)
    }

    /// Synthetic stores keep tests and visual QA entirely separate from the person's Keychain.
    public init(store: any HiveCredentialStore, runtime: HiveProviderRuntime = .init()) {
        self.store = store
        self.runtime = runtime
        do {
            let key = try store.load()
            if let key { try HiveProviderRuntime.validateCredential(key) }
            try runtime.replaceCredential(key)
            if key != nil {
                status = .prepared
                message = "API 키가 저장돼 있어요. 연결 확인은 아직 하지 않았어요."
            }
        } catch {
            // Clearing has no validation failure; a failed load must not retain an injected runtime key.
            try? runtime.replaceCredential(nil)
            status = .failed
            message = HiveConnectionError.storageUnavailable.message
        }
    }

    public func save(_ key: String) throws {
        do { try HiveProviderRuntime.validateCredential(key) }
        catch {
            message = HiveConnectionError.invalidCredential.message
            throw HiveConnectionError.invalidCredential
        }
        do { try store.save(key) }
        catch {
            message = HiveConnectionError.storageUnavailable.message
            throw HiveConnectionError.storageUnavailable
        }
        // Validation already succeeded. Keychain commit precedes changing the active runtime snapshot.
        try runtime.replaceCredential(key)
        generation &+= 1
        status = .prepared
        message = "API 키를 저장했어요. 연결 확인은 아직 하지 않았어요."
    }

    public func remove() throws {
        do { try store.remove() }
        catch {
            message = HiveConnectionError.storageUnavailable.message
            throw HiveConnectionError.storageUnavailable
        }
        try runtime.replaceCredential(nil)
        generation &+= 1
        status = .missing
        message = "Hive API 키를 삭제했어요."
    }

    public func verify(using probe: @MainActor () async throws -> Void) async {
        guard runtime.isPrepared else {
            message = HiveConnectionError.missingCredential.message
            return
        }
        generation &+= 1
        let attempt = generation
        status = .verifying
        message = "Hive 연결을 확인하고 있어요."
        do {
            try Task.checkCancellation()
            try await probe()
            try Task.checkCancellation()
            guard generation == attempt else { return }
            status = .verified
            message = "Hive 연결을 확인했어요."
        } catch {
            guard generation == attempt else { return }
            if error is CancellationError || Task.isCancelled {
                status = .prepared
                message = "연결 확인을 취소했어요. 저장된 키는 유지돼요."
            } else {
                status = .failed
                message = HiveConnectionError.verificationFailed.message
            }
        }
    }
}

/// Transient entry only: saved keys are never loaded back into this form.
@MainActor @Observable
public final class HiveCredentialForm {
    public var input = ""
    public var hasInput: Bool { input.contains { !$0.isWhitespace } }

    public init() {}

    public func save(to connection: HiveConnection) throws {
        defer { clear() }
        try connection.save(input)
    }

    public func cancel() { clear() }
    public func clear() { input = "" }
}

@MainActor
final class KeychainHiveCredentialStore: HiveCredentialStore {
    private let serviceNamespace: String

    init(serviceNamespace: String) { self.serviceNamespace = serviceNamespace }

    // Use the macOS login Keychain and its normal application ACL. The isolated
    // SwiftPM executable has no Data Protection access-group entitlement.
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceNamespace,
            kSecAttrAccount as String: "hive-api-key",
        ]
    }

    func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw HiveConnectionError.storageUnavailable
        }
        return key
    }

    func save(_ key: String) throws {
        do { try HiveProviderRuntime.validateCredential(key) }
        catch { throw HiveConnectionError.invalidCredential }
        let value = Data(key.utf8)
        var item = query
        item[kSecValueData as String] = value
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else { throw HiveConnectionError.storageUnavailable }
        // SecItemUpdate replaces the value atomically; never delete a working key before replacement.
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        guard updated == errSecSuccess else { throw HiveConnectionError.storageUnavailable }
    }

    func insertIfAbsent(_ key: String) throws -> Bool {
        do { try HiveProviderRuntime.validateCredential(key) }
        catch { throw HiveConnectionError.invalidCredential }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem { return false }
        guard added == errSecSuccess else { throw HiveConnectionError.storageUnavailable }
        return true
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HiveConnectionError.storageUnavailable
        }
    }
}
