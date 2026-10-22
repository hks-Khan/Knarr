import Foundation
import KnarrCore

/// Resolves Knarr's admin service on demand so the socket can exist from app launch while the
/// database and Stallari connection are still starting. Until then every call answers with a
/// structured `unavailable` refusal instead of a silent hang.
public final class LazyAdminService: KnarrAdminServing, @unchecked Sendable {
    private let resolve: @MainActor @Sendable () -> (any KnarrAdminServing)?
    public init(resolve: @escaping @MainActor @Sendable () -> (any KnarrAdminServing)?) {
        self.resolve = resolve
    }
    @MainActor
    public func adminCall(_ operation: String, arguments: OMPJSON) async throws -> OMPJSON {
        guard let service = resolve() else {
            throw KnarrAdminError.unavailable("Knarr의 저장소와 Stallari 연결이 아직 준비되지 않았습니다. 잠시 뒤 다시 시도하십시오.")
        }
        return try await service.adminCall(operation, arguments: arguments)
    }
}
