import Foundation
import KnarrCore
import KnarrSync
import Testing
@testable import KnarrMirror

@MainActor @Suite struct PhoneAdmissionTests {
    @Test func messageAdmissionFailureReachesCloudReceiver() async {
        let suite = "knarr-phone-admission-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveKnarrStore(preferences: defaults)
        // The engine is unavailable. A phone request must remain pending, not be acknowledged.
        await #expect(throws: Error.self) {
            try await MobileRequestApplier.apply(.message(text: "폰 요청 보존", project: nil), to: store)
        }
        let exit = await store.shutdown()
        #expect(exit.remainingProcessIDs.isEmpty)
    }
}
