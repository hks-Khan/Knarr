import Foundation
import Observation

/// Explicit, app-owned copy between two Hive data-domain namespaces.
/// Never exposes a credential or opens a store until the person confirms.
@MainActor @Observable
public final class HiveCredentialTransfer {
    public enum Status: Sendable, Equatable {
        case awaitingConfirmation, completed, conflict, cancelled, failed
    }

    public let sourceDirectory: URL
    public let destinationDirectory: URL
    public private(set) var status: Status = .awaitingConfirmation
    public private(set) var message = "출처와 대상을 확인한 뒤 연결 복사를 승인해 주세요. 원본 인증은 유지돼요."
    @ObservationIgnored private let sourceStore: any HiveCredentialStore
    @ObservationIgnored private let destinationStore: any HiveCredentialStore
    private let validDomains: Bool

    public var canConfirm: Bool {
        validDomains && (status == .awaitingConfirmation || status == .failed)
    }

    public convenience init(sourceDirectory: URL, destinationDirectory: URL) {
        self.init(sourceDirectory: sourceDirectory, destinationDirectory: destinationDirectory,
                  sourceStore: KeychainHiveCredentialStore(serviceNamespace: HiveConnection.serviceNamespace(dataDirectory: sourceDirectory)),
                  destinationStore: KeychainHiveCredentialStore(serviceNamespace: HiveConnection.serviceNamespace(dataDirectory: destinationDirectory)))
    }

    /// Injected stores are for synthetic validation; production binds only the app's fixed Hive account.
    init(sourceDirectory: URL, destinationDirectory: URL,
         sourceStore: any HiveCredentialStore, destinationStore: any HiveCredentialStore) {
        self.sourceDirectory = sourceDirectory.standardizedFileURL
        self.destinationDirectory = destinationDirectory.standardizedFileURL
        self.sourceStore = sourceStore
        self.destinationStore = destinationStore
        validDomains = sourceDirectory.isFileURL && destinationDirectory.isFileURL &&
            self.sourceDirectory.path != self.destinationDirectory.path
        if !validDomains {
            status = .failed
            message = "서로 다른 두 데이터 영역을 지정해 주세요. 인증은 변경하지 않았어요."
        }
    }

    public func confirm() {
        guard canConfirm else { return }
        do {
            guard let key = try sourceStore.load() else {
                status = .failed
                message = "출처 영역에 저장된 Hive 인증이 없어요. 출처 경로를 확인해 주세요. 대상은 변경하지 않았어요."
                return
            }
            try HiveProviderRuntime.validateCredential(key)
            // All fallible validation precedes this atomic, insert-only commit.
            // A conflict/race must never become an overwrite or a delete-then-save rollback.
            guard try destinationStore.insertIfAbsent(key) else {
                status = .conflict
                message = "대상에 기존 Hive 인증이 있어 복사하지 않았어요. 기존 대상과 원본 인증을 모두 유지했어요."
                return
            }
            status = .completed
            message = "대상의 Hive 인증을 준비했어요. 원본은 유지했으며 새 실행부터 사용할 수 있어요. 대상의 실제 연결 확인은 별도로 해 주세요."
        } catch {
            status = .failed
            message = "인증을 복사하지 못했어요. 원본과 대상의 기존 인증은 유지돼요. 키체인 접근을 확인한 뒤 다시 시도해 주세요."
        }
    }

    public func cancel() {
        guard status != .completed else { return }
        status = .cancelled
        message = "연결 복사를 취소했어요. 원본과 대상 인증은 변경하지 않았어요."
    }
}
