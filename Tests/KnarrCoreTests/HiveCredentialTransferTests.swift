import Foundation
import Testing
@testable import KnarrCore

@MainActor private final class HiveTransferVault {
    var values: [String: String] = [:]
    var loads: [String: Int] = [:]
    var insertions: [String: Int] = [:]
    var failLoad: Set<String> = []
    var failInsert: Set<String> = []
    var race: [String: String] = [:]
    func store(_ directory: URL) -> HiveTransferStore {
        HiveTransferStore(vault: self, namespace: HiveConnection.serviceNamespace(dataDirectory: directory))
    }
    func transfer(_ source: URL, _ destination: URL) -> HiveCredentialTransfer {
        HiveCredentialTransfer(sourceDirectory: source, destinationDirectory: destination,
                               sourceStore: store(source), destinationStore: store(destination))
    }
}

@MainActor private final class HiveTransferStore: HiveCredentialStore {
    let vault: HiveTransferVault
    let namespace: String
    init(vault: HiveTransferVault, namespace: String) { self.vault = vault; self.namespace = namespace }
    func load() throws -> String? {
        vault.loads[namespace, default: 0] += 1
        if vault.failLoad.contains(namespace) { throw failure }
        return vault.values[namespace]
    }
    func save(_ key: String) throws { vault.values[namespace] = key }
    func insertIfAbsent(_ key: String) throws -> Bool {
        vault.insertions[namespace, default: 0] += 1
        if vault.failInsert.contains(namespace) { throw failure }
        if let raced = vault.race.removeValue(forKey: namespace) { vault.values[namespace] = raced }
        guard vault.values[namespace] == nil else { return false }
        vault.values[namespace] = key
        return true
    }
    private var failure: NSError {
        NSError(domain: "SyntheticStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "synthetic-sensitive-error-do-not-display"])
    }
    func remove() throws { vault.values.removeValue(forKey: namespace) }
}

@Suite(.serialized) @MainActor struct HiveCredentialTransferTests {
    @Test func confirmedSourceCanPrepareOperatingNamespaceWithoutReentry() throws {
        let source = URL(fileURLWithPath: "/synthetic/verification", isDirectory: true)
        let destination = URL(fileURLWithPath: "/synthetic/operating", isDirectory: true)
        let vault = HiveTransferVault()
        let input = HiveConnection(store: vault.store(source))
        try input.save("synthetic-user-entered-hive-key")
        #expect(input.runtime.isPrepared)
        #expect(HiveConnection(store: vault.store(destination)).status == .missing)
        let transfer = vault.transfer(source, destination)
        transfer.confirm()
        #expect(transfer.status == .completed)
        let operating = HiveConnection(store: vault.store(destination))
        #expect(operating.runtime.isPrepared)
        #expect(operating.status == .prepared)
        #expect(vault.values[vault.store(source).namespace] == "synthetic-user-entered-hive-key")
    }

    @Test func noStoreAccessBeforeApprovalAndCancelIsTerminal() {
        let source = URL(fileURLWithPath: "/synthetic/source")
        let destination = URL(fileURLWithPath: "/synthetic/destination")
        let vault = HiveTransferVault()
        let transfer = vault.transfer(source, destination)
        #expect(vault.loads.isEmpty && vault.insertions.isEmpty)
        transfer.cancel()
        transfer.confirm()
        #expect(transfer.status == .cancelled)
        #expect(!transfer.canConfirm)
        #expect(vault.loads.isEmpty && vault.insertions.isEmpty && vault.values.isEmpty)
    }

    @Test func equivalentAndNonFileDomainsCannotOpenStores() {
        let source = URL(fileURLWithPath: "/synthetic/source")
        for destination in [source.appendingPathComponent("child/.."), URL(string: "https://example.invalid/source")!] {
            let vault = HiveTransferVault()
            let transfer = vault.transfer(source, destination)
            #expect(!transfer.canConfirm)
            transfer.confirm()
            #expect(transfer.status == .failed)
            #expect(vault.loads.isEmpty && vault.insertions.isEmpty)
        }
    }

    @Test func reversedDomainsDoNotOverwriteTheOriginal() throws {
        let source = URL(fileURLWithPath: "/synthetic/source")
        let destination = URL(fileURLWithPath: "/synthetic/destination")
        let vault = HiveTransferVault()
        try vault.store(source).save("synthetic-original")
        let transfer = vault.transfer(destination, source)
        #expect(transfer.sourceDirectory.path == destination.path)
        #expect(transfer.destinationDirectory.path == source.path)
        transfer.confirm()
        #expect(transfer.status == .failed)
        #expect(vault.values == [vault.store(source).namespace: "synthetic-original"])
        #expect(vault.insertions.isEmpty)
    }

    @Test(arguments: [false, true]) func conflictAndConcurrentInsertBothPreserveDestination(raced: Bool) throws {
        let source = URL(fileURLWithPath: "/synthetic/source")
        let destination = URL(fileURLWithPath: "/synthetic/destination")
        let vault = HiveTransferVault()
        let sourceStore = vault.store(source), target = vault.store(destination)
        try sourceStore.save("synthetic-source")
        if raced { vault.race[target.namespace] = "synthetic-existing-target" }
        else { try target.save("synthetic-existing-target") }
        let transfer = vault.transfer(source, destination)
        transfer.confirm()
        #expect(transfer.status == .conflict)
        #expect(!transfer.canConfirm)
        #expect(vault.values[sourceStore.namespace] == "synthetic-source")
        #expect(vault.values[target.namespace] == "synthetic-existing-target")
        #expect(!transfer.message.contains("synthetic-source"))
        #expect(!transfer.message.contains("synthetic-existing-target"))
        transfer.cancel()
        transfer.confirm()
        #expect(vault.insertions[target.namespace] == 1)
        #expect(vault.values[target.namespace] == "synthetic-existing-target")
    }

    @Test(arguments: [false, true]) func storeFailuresPreserveBothValuesAndNeverSurfaceRawError(atSource: Bool) throws {
        let source = URL(fileURLWithPath: "/synthetic/source")
        let destination = URL(fileURLWithPath: "/synthetic/destination")
        let vault = HiveTransferVault()
        let from = vault.store(source), to = vault.store(destination)
        try from.save("synthetic-original")
        try to.save("synthetic-prior-target")
        let before = vault.values
        if atSource { vault.failLoad.insert(from.namespace) }
        else { vault.failInsert.insert(to.namespace) }
        let transfer = vault.transfer(source, destination)
        transfer.confirm()
        #expect(transfer.status == .failed)
        #expect(vault.values == before)
        #expect(!transfer.message.contains("synthetic-sensitive-error"))
        #expect(!transfer.message.contains("synthetic-original"))
        #expect(!String(reflecting: transfer).contains("synthetic-original"))
    }

    @Test(arguments: [false, true]) func missingOrInvalidSourceNeverCreatesDestination(invalid: Bool) throws {
        let source = URL(fileURLWithPath: "/synthetic/source")
        let destination = URL(fileURLWithPath: "/synthetic/destination")
        let vault = HiveTransferVault()
        if invalid { try vault.store(source).save("synthetic-invalid\nheader") }
        let before = vault.values
        let transfer = vault.transfer(source, destination)
        transfer.confirm()
        #expect(transfer.status == .failed)
        #expect(vault.values == before)
        #expect(vault.insertions.isEmpty)
    }

    @Test func explicitRetryCanCommitOnceWithoutDeletingSource() throws {
        let source = URL(fileURLWithPath: "/synthetic/source")
        let destination = URL(fileURLWithPath: "/synthetic/destination")
        let vault = HiveTransferVault()
        let from = vault.store(source), to = vault.store(destination)
        try from.save("synthetic-source")
        vault.failInsert.insert(to.namespace)
        let transfer = vault.transfer(source, destination)
        transfer.confirm()
        #expect(vault.values[to.namespace] == nil)
        #expect(transfer.canConfirm)
        vault.failInsert.remove(to.namespace)
        transfer.confirm()
        #expect(transfer.status == .completed)
        try from.save("synthetic-later-source")
        transfer.confirm()
        transfer.cancel()
        #expect(transfer.status == .completed)
        #expect(vault.values[to.namespace] == "synthetic-source")
        #expect(vault.values[from.namespace] == "synthetic-later-source")
        #expect(vault.insertions[to.namespace] == 2)
    }
}
