import Foundation
import Observation
import Testing
@testable import KnarrCore
@testable import KnarrUI

@MainActor private final class HiveStoreFixture: HiveCredentialStore {
    var credential: String?
    var failure: Error?
    var writes = 0
    var deletes = 0
    init(_ credential: String? = nil) { self.credential = credential }
    func load() throws -> String? { if let failure { throw failure }; return credential }
    func save(_ key: String) throws {
        if let failure { throw failure }
        credential = key; writes += 1
    }
    func insertIfAbsent(_ key: String) throws -> Bool {
        if let failure { throw failure }
        guard credential == nil else { return false }
        credential = key; writes += 1
        return true
    }
    func remove() throws {
        if let failure { throw failure }
        credential = nil; deletes += 1
    }
}

private struct HiveSyntheticFailure: LocalizedError {
    let secret: String
    var errorDescription: String? { "fixture failure: \(secret)" }
}

@MainActor private final class HiveVerificationGate {
    private var release: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation {
            release = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilPaused() async {
        guard release == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func resume() {
        release?.resume()
        release = nil
    }
}

@Suite(.serialized) @MainActor struct HiveConnectionTests {
    @Test func cancelledAndEmptyInputPreserveCredential() throws {
        let store = HiveStoreFixture("synthetic-original")
        let connection = HiveConnection(store: store)
        let form = HiveCredentialForm()
        form.input = "synthetic-cancelled"
        form.cancel()
        #expect(form.input.isEmpty)
        #expect(!form.hasInput)
        #expect(store.credential == "synthetic-original")
        #expect(throws: HiveConnectionError.self) { try form.save(to: connection) }
        #expect(form.input.isEmpty)
        #expect(store.writes == 0)
        #expect(connection.status == .prepared)
        #expect(connection.runtime.isPrepared)
    }

    @Test func failedOverwriteAndDeleteKeepPriorPreparedCredential() throws {
        let store = HiveStoreFixture("synthetic-original")
        let connection = HiveConnection(store: store)
        store.failure = HiveSyntheticFailure(secret: "synthetic-replacement")
        let form = HiveCredentialForm()
        form.input = "synthetic-replacement"
        #expect(throws: HiveConnectionError.self) { try form.save(to: connection) }
        #expect(form.input.isEmpty)
        #expect(!form.hasInput)
        #expect(store.credential == "synthetic-original")
        #expect(connection.status == .prepared)
        #expect(connection.runtime.isPrepared)
        #expect(!connection.message.contains("synthetic-replacement"))
        #expect(throws: HiveConnectionError.self) { try connection.remove() }
        #expect(store.credential == "synthetic-original")
        #expect(connection.status == .prepared)
        #expect(connection.runtime.isPrepared)
        #expect(!connection.message.contains("synthetic-replacement"))
    }

    @Test func preparedIsNotVerifiedAndRemoveClearsRuntime() async throws {
        let store = HiveStoreFixture()
        let connection = HiveConnection(store: store)
        #expect(connection.status == .missing)
        var calls = 0
        await connection.verify { calls += 1 }
        #expect(calls == 0)
        let form = HiveCredentialForm()
        form.input = "synthetic-new"
        try form.save(to: connection)
        #expect(form.input.isEmpty)
        #expect(connection.status == .prepared)
        await connection.verify {
            #expect(connection.status == .verifying)
            calls += 1
        }
        #expect(connection.status == .verified)
        #expect(calls == 1)
        try connection.remove()
        #expect(connection.status == .missing)
        #expect(!connection.runtime.isPrepared)
        #expect(store.credential == nil)
    }

    @Test func failuresAreGenericAndReplacementRequiresFreshVerification() async throws {
        let secret = "synthetic-do-not-echo"
        let store = HiveStoreFixture(secret)
        let connection = HiveConnection(store: store)
        await connection.verify { throw HiveSyntheticFailure(secret: secret) }
        #expect(connection.status == .failed)
        #expect(connection.runtime.isPrepared)
        #expect(!connection.message.contains(secret))
        await connection.verify {}
        #expect(connection.status == .verified)
        try connection.save("synthetic-replacement")
        #expect(connection.status == .prepared)
        store.failure = HiveSyntheticFailure(secret: secret)
        #expect(throws: HiveConnectionError.self) { try connection.save("synthetic-other") }
        #expect(!connection.message.contains(secret))
        let failedLoad = HiveConnection(store: store)
        #expect(failedLoad.status == .failed)
        #expect(!failedLoad.runtime.isPrepared)
        #expect(!failedLoad.message.contains(secret))
    }

    @Test func invalidInputNeverWritesAndDisappearClearsTransientForm() throws {
        let store = HiveStoreFixture("synthetic-original")
        let connection = HiveConnection(store: store)
        let form = HiveCredentialForm()
        for key in ["", "   ", "synthetic\ninvalid", "synthetic\u{0}invalid",
                    String(repeating: "x", count: 4096), String(repeating: "가", count: 1366)] {
            form.input = key
            #expect(throws: HiveConnectionError.self) { try form.save(to: connection) }
            #expect(form.input.isEmpty)
            #expect(!form.hasInput)
        }
        #expect(store.writes == 0)
        #expect(store.credential == "synthetic-original")
        form.input = "synthetic-disappear"
        form.clear()
        #expect(form.input.isEmpty)
    }

    @Test func cancelledOrSupersededVerificationCannotVerifyAnotherCredential() async throws {
        let store = HiveStoreFixture("synthetic-first")
        let connection = HiveConnection(store: store)
        await connection.verify { throw CancellationError() }
        #expect(connection.status == .prepared)
        await connection.verify { try connection.save("synthetic-second") }
        #expect(connection.status == .prepared)
        await connection.verify { try connection.remove() }
        #expect(connection.status == .missing)
    }

    @Test func boundedCredentialIsSavedIntactAndInvalidStoredCredentialIsNotPrepared() throws {
        let store = HiveStoreFixture()
        let connection = HiveConnection(store: store)
        let form = HiveCredentialForm()
        let key = String(repeating: "x", count: 4095)
        form.input = key
        try form.save(to: connection)
        #expect(store.credential == key)
        #expect(store.writes == 1)
        #expect(form.input.isEmpty)
        #expect(connection.status == .prepared)

        store.credential = "synthetic\ninvalid"
        let reloaded = HiveConnection(store: store, runtime: connection.runtime)
        #expect(reloaded.status == .failed)
        #expect(!reloaded.runtime.isPrepared)
        #expect(!reloaded.message.contains("synthetic"))
    }

    @Test func suspendedVerificationCannotAuthenticateReplacementOrDeletedKey() async throws {
        let store = HiveStoreFixture("synthetic-first")
        let connection = HiveConnection(store: store)
        let replacementGate = HiveVerificationGate()
        let replacementProbe = Task {
            await connection.verify { await replacementGate.pause() }
        }
        await replacementGate.waitUntilPaused()
        #expect(connection.status == .verifying)
        try connection.save("synthetic-second")
        replacementGate.resume()
        await replacementProbe.value
        #expect(connection.status == .prepared)
        #expect(store.credential == "synthetic-second")

        let deletionGate = HiveVerificationGate()
        let deletionProbe = Task {
            await connection.verify {
                await deletionGate.pause()
                throw HiveSyntheticFailure(secret: "synthetic-first")
            }
        }
        await deletionGate.waitUntilPaused()
        try connection.remove()
        deletionGate.resume()
        await deletionProbe.value
        #expect(connection.status == .missing)
        #expect(!connection.runtime.isPrepared)
        #expect(!connection.message.contains("synthetic-first"))
    }

    @Test func taskCancellationAndNewerVerificationWinOverSuspendedProbe() async {
        let connection = HiveConnection(store: HiveStoreFixture("synthetic-key"))
        let cancelledGate = HiveVerificationGate()
        let cancelledProbe = Task {
            await connection.verify { await cancelledGate.pause() }
        }
        await cancelledGate.waitUntilPaused()
        cancelledProbe.cancel()
        cancelledGate.resume()
        await cancelledProbe.value
        #expect(connection.status == .prepared)

        let olderGate = HiveVerificationGate()
        let olderProbe = Task {
            await connection.verify {
                await olderGate.pause()
                throw HiveSyntheticFailure(secret: "synthetic-key")
            }
        }
        await olderGate.waitUntilPaused()
        await connection.verify {}
        #expect(connection.status == .verified)
        olderGate.resume()
        await olderProbe.value
        #expect(connection.status == .verified)
        #expect(!connection.message.contains("synthetic-key"))
    }

    @Test func modelGroupsIncludeHiveAndAllUnknownProviders() {
        let catalog = ["anthropic/claude-opus", "openai/gpt", "openai-codex/gpt-codex",
                       "hive/deepseek-ai/deepseek-v4.1-flash-1017", "z-provider/model-b", "other/model-a", "other/model-b"]
        let groups = ModelControls.groups(catalog)
        #expect(groups.map(\.name) == ["Claude", "GPT", "Hive", "other", "z-provider"])
        #expect(groups.first { $0.name == "GPT" }?.models.count == 2)
        #expect(groups.first { $0.name == "other" }?.models.count == 2)
        #expect(Set(groups.flatMap(\.models)) == Set(catalog))
        #expect(!ModelControls.groups(["openai/gpt"]).contains { $0.name == "Hive" })
    }
}
