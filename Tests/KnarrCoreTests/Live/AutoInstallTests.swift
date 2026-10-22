import Foundation
import Testing
@testable import KnarrCore

/// Auto install detection, waiting gate, build failure and repeat suppression.
/// Nothing here replaces the installed app, launches a real build, or restarts a process.
@MainActor
@Suite(.serialized) struct AutoInstallTests {
    private let policy = AutoInstallPolicy.current

    // MARK: - Fixtures

    /// Records what the coordinator asked for, in order, without building anything.
    private final class RecordingBuilder: AutoInstallBuilding, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        private var discarded: [String] = []
        private let result: @Sendable (String) throws -> AutoInstallCandidate
        init(result: @escaping @Sendable (String) throws -> AutoInstallCandidate = { commit in
            AutoInstallCandidate(app: URL(fileURLWithPath: "/tmp/candidate.app"), version: commit, commit: commit)
        }) { self.result = result }

        var committed: [String] { lock.withLock { calls } }
        var discardedCommits: [String] { lock.withLock { discarded } }

        func build(commit: String) async throws -> AutoInstallCandidate {
            lock.withLock { calls.append(commit) }
            return try result(commit)
        }
        func discard(_ candidate: AutoInstallCandidate) async {
            lock.withLock { discarded.append(candidate.commit) }
        }
        func waitForCallCount(_ count: Int, timeout: Duration = .seconds(3)) async {
            let deadline = ContinuousClock.now + timeout
            while committed.count < count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    private final class InstallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var installed: [AutoInstallCandidate] = []
        private var error: (any Error)?
        var candidates: [AutoInstallCandidate] { lock.withLock { installed } }
        var failure: (any Error)? { lock.withLock { error } }
        func record(_ candidate: AutoInstallCandidate) throws {
            if let error = lock.withLock({ error }) { throw error }
            lock.withLock { installed.append(candidate) }
        }
        func fail(with error: any Error) { lock.withLock { self.error = error } }
    }

    /// A real repository whose installed app bundle and main ref are disposable.
    private struct Fixture {
        let root: URL
        let target: URL
        let source: URL
        let defaults: UserDefaults
        let suite: String

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(installedVersion: String? = "ec489d3", commit: String = "ec489d3c771c52b9564702bb0cdbc0eafe0e0815") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-auto-" + UUID().uuidString)
        let target = root.appendingPathComponent("Knarr.app")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        var plist: [String: String] = ["CFBundleIdentifier": "com.kyen.knarr", "CFBundleExecutable": "Knarr", "CFBundlePackageType": "APPL"]
        if let installedVersion { plist["CFBundleVersion"] = installedVersion }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: target.appendingPathComponent("Contents/Info.plist"))
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try run("/usr/bin/git", ["init", "-q", "-b", "main"], at: source)
        try run("/usr/bin/git", ["config", "user.email", "auto@example.com"], at: source)
        try run("/usr/bin/git", ["config", "user.name", "Auto Install"], at: source)
        try "let value = 1\n".write(to: source.appendingPathComponent("file.swift"), atomically: true, encoding: .utf8)
        try run("/usr/bin/git", ["add", "."], at: source)
        try run("/usr/bin/git", ["commit", "-q", "-m", "fixture"], at: source)
        // Pin the ref so the fixture commit is known without depending on commit metadata.
        let ref = source.appendingPathComponent(".git/refs/heads/main")
        try FileManager.default.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (commit + "\n").write(to: ref, atomically: true, encoding: .utf8)
        let suite = "knarr-auto-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return Fixture(root: root, target: target, source: source, defaults: defaults, suite: suite)
    }

    private func run(_ executable: String, _ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func makeInstaller(_ fixture: Fixture, builder: any AutoInstallBuilding,
                               installations: InstallRecorder,
                               gate: @escaping @MainActor () async -> AutoInstallGate.Inputs = {
                                   .init(runsBusy: false, activeHirds: false, conversationsBusy: false, hasDraft: false)
                               },
                               enabled: Bool = true, policy: AutoInstallPolicy? = nil) -> AutoInstaller {
        AutoInstaller(policy: policy ?? self.policy, target: fixture.target,
            installedVersion: AutoInstallArtifact.version(ofAppAt: fixture.target),
            source: fixture.source, builder: builder,
            install: { try installations.record($0) }, gate: gate, enabled: enabled)
    }

    private func commit(_ fixture: Fixture, _ sha: String) throws {
        try (sha + "\n").write(to: fixture.source.appendingPathComponent(".git/refs/heads/main"), atomically: true, encoding: .utf8)
    }

    /// Reads the ref the coordinator compares against, matching the store's read path.
    private func mainRef(_ fixture: Fixture) -> String? {
        try? String(contentsOf: fixture.source.appendingPathComponent(".git/refs/heads/main"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func sourceDiscoverySkipsOtherProjectsWithTheSameBuildScript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-source-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("Other"), knarr = root.appendingPathComponent("Knarr")
        for folder in [other, knarr] {
            let script = folder.appendingPathComponent("scripts/build-app.sh")
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: script)
        }
        for marker in ["Sources/KnarrApp/KnarrApp.swift", "Sources/KnarrCore/KnarrStore.swift"] {
            let file = knarr.appendingPathComponent(marker)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        #expect(AutoInstallSource.find(in: [other, knarr]) == knarr)
        #expect(AutoInstallSource.find(in: [other]) == nil)
    }

    // MARK: - Detection

    @Test func installedVersionEqualToMainBuildsNothing() throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        let builder = RecordingBuilder()
        let installations = InstallRecorder()
        let installer = makeInstaller(fixture, builder: builder, installations: installations)
        installer.check(mainCommit: mainRef(fixture))
        #expect(builder.committed.isEmpty)
        #expect(installations.candidates.isEmpty)
        if case .current = installer.phase {} else { Issue.record("expected current, got \(installer.phase)") }
        #expect(installer.statusLine().contains("ec489d3"))
    }

    @Test func dirtySuffixOnInstalledVersionStillMatchesMain() throws {
        let fixture = try makeFixture(installedVersion: "ec489d3-dirty"); defer { fixture.clean() }
        let builder = RecordingBuilder()
        let installations = InstallRecorder()
        let installer = makeInstaller(fixture, builder: builder, installations: installations)
        installer.check(mainCommit: mainRef(fixture))
        #expect(builder.committed.isEmpty)
        #expect(installations.candidates.isEmpty)
    }

    @Test func newerMainBuildsExactlyOnceAndPinsTheCommit() async throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        let main = "4a91b2c0d3e4f5061728394a5b6c7d8e9f001122"
        try commit(fixture, main)
        let builder = RecordingBuilder()
        let installations = InstallRecorder()
        let installer = makeInstaller(fixture, builder: builder, installations: installations)
        installer.check(mainCommit: main)
        await builder.waitForCallCount(1)
        // A second detection while the build is in flight must not start another.
        installer.check(mainCommit: main)
        try await Task.sleep(for: .milliseconds(200))
        #expect(builder.committed == [main])
        #expect(installations.candidates.map(\.commit) == [main])
    }

    @Test func buildFailureInstallsNothingAndKeepsOneLineReason() async throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        let main = "4a91b2c0d3e4f5061728394a5b6c7d8e9f001122"
        try commit(fixture, main)
        let reason = policy.reason("signature")
        let builder = RecordingBuilder(result: { _ in throw AutoInstallFailure.reason(reason) })
        let installations = InstallRecorder()
        let installer = makeInstaller(fixture, builder: builder, installations: installations)
        installer.check(mainCommit: main)
        await builder.waitForCallCount(1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(installations.candidates.isEmpty)
        if case .failed(let text) = installer.phase { #expect(text == reason) } else { Issue.record("expected failed, got \(installer.phase)") }
        #expect(installer.statusLine().contains(reason))
        // The same commit must not rebuild.
        installer.check(mainCommit: main)
        try await Task.sleep(for: .milliseconds(200))
        #expect(builder.committed.count == 1)
        #expect(installer.failedCommit == main)
    }

    @Test func reEnablingClearsTheFailureAndRebuildsTheSameCommit() async throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        let main = "4a91b2c0d3e4f5061728394a5b6c7d8e9f001122"
        try commit(fixture, main)
        let builder = RecordingBuilder(result: { commit in
            throw AutoInstallFailure.reason(AutoInstallPolicy.current.reason("command"))
        })
        let installer = makeInstaller(fixture, builder: builder, installations: InstallRecorder())
        installer.check(mainCommit: main)
        await builder.waitForCallCount(1)
        try await Task.sleep(for: .milliseconds(200))
        installer.check(mainCommit: main)
        try await Task.sleep(for: .milliseconds(200))
        #expect(builder.committed.count == 1)
        // The switch is the manual retry path.
        installer.enabledChanged(false)
        installer.enabledChanged(true)
        installer.check(mainCommit: main)
        await builder.waitForCallCount(2)
        #expect(builder.committed.count == 2)
    }

    @Test func missingMainRefIsReportedNotGuessed() throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        let builder = RecordingBuilder()
        let installer = makeInstaller(fixture, builder: builder, installations: InstallRecorder())
        installer.check(mainCommit: nil)
        if case .failed(let text) = installer.phase { #expect(text == policy.reason("main")) } else { Issue.record("expected failed, got \(installer.phase)") }
        #expect(builder.committed.isEmpty)
    }

    // MARK: - Waiting gate

    @Test(arguments: [
        AutoInstallGate.Inputs(runsBusy: true, activeHirds: false, conversationsBusy: false, hasDraft: false),
        AutoInstallGate.Inputs(runsBusy: false, activeHirds: true, conversationsBusy: false, hasDraft: false),
        AutoInstallGate.Inputs(runsBusy: false, activeHirds: false, conversationsBusy: true, hasDraft: false),
        AutoInstallGate.Inputs(runsBusy: false, activeHirds: false, conversationsBusy: false, hasDraft: true),
        AutoInstallGate.Inputs(runsBusy: false, activeHirds: false, conversationsBusy: false, hasDraft: false, appActive: true),
    ])
    func gateBlocksEveryBusyInput(inputs: AutoInstallGate.Inputs) {
        #expect(!AutoInstallGate.allows(inputs))
        #expect(AutoInstallGate.allows(.init(runsBusy: false, activeHirds: false, conversationsBusy: false, hasDraft: false)))
    }

    @Test func installWaitsForTheGateThenRunsOnce() async throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        let main = "4a91b2c0d3e4f5061728394a5b6c7d8e9f001122"
        try commit(fixture, main)
        let builder = RecordingBuilder()
        let installations = InstallRecorder()
        let busy = BusyBox()
        let installer = makeInstaller(fixture, builder: builder, installations: installations,
            gate: { busy.inputs })
        installer.check(mainCommit: main)
        await builder.waitForCallCount(1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(installations.candidates.isEmpty)
        if case .waiting = installer.phase {} else { Issue.record("expected waiting, got \(installer.phase)") }
        // Idle transitions release the wait; no timer is involved.
        busy.inputs = .init(runsBusy: false, activeHirds: false, conversationsBusy: false, hasDraft: false)
        installer.resumeIfWaiting()
        try await Task.sleep(for: .milliseconds(200))
        #expect(installations.candidates.count == 1)
        #expect(builder.committed == [main])
    }

    private final class BusyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = AutoInstallGate.Inputs(runsBusy: true, activeHirds: false, conversationsBusy: false, hasDraft: false)
        var inputs: AutoInstallGate.Inputs {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    @Test func disablingWhileGateSuspendsDoesNotInstall() async throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        let builder = RecordingBuilder(), installations = InstallRecorder()
        var release: CheckedContinuation<Void, Never>?
        let installer = makeInstaller(fixture, builder: builder, installations: installations, gate: {
            await withCheckedContinuation { release = $0 }
            return .init(runsBusy: false, activeHirds: false, conversationsBusy: false, hasDraft: false)
        })
        installer.check(mainCommit: String(repeating: "a", count: 40))
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        let continuation = try #require(release)
        installer.enabledChanged(false)
        continuation.resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(installations.candidates.isEmpty)
        #expect(installer.phase == .off)
    }

    @Test func newerMainWhileGateSuspendsSupersedesCandidate() async throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        let builder = RecordingBuilder(), installations = InstallRecorder()
        var release: CheckedContinuation<Void, Never>?
        var first = true
        let installer = makeInstaller(fixture, builder: builder, installations: installations, gate: {
            if first { first = false; await withCheckedContinuation { release = $0 } }
            return .init(runsBusy: false, activeHirds: false, conversationsBusy: false, hasDraft: false)
        })
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        installer.check(mainCommit: a)
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        let continuation = try #require(release)
        installer.check(mainCommit: b)
        continuation.resume()
        try await Task.sleep(for: .milliseconds(200))
        #expect(installations.candidates.map(\.commit) == [b])
        #expect(builder.discardedCommits.contains(a))
    }

    @Test func busyDuringPreparationRechecksIdleGate() async throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        var attempts = 0
        let installer = AutoInstaller(target: fixture.target, installedVersion: "ec489d3", source: fixture.source,
            builder: RecordingBuilder(), install: { _ in
                attempts += 1
                if attempts == 1 { throw LiveKnarrError.installBusy }
            }, gate: { .init(runsBusy: false, activeHirds: false, conversationsBusy: false, hasDraft: false) }, enabled: true)
        installer.check(mainCommit: String(repeating: "a", count: 40))
        try await Task.sleep(for: .milliseconds(200))
        #expect(attempts == 2)
        if case .current = installer.phase {} else { Issue.record("installer did not resume") }
    }

    @Test func auxiliaryDraftsBlockUntilEveryComposerIsClear() throws {
        let suite = "knarr-install-drafts-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = LiveKnarrStore(preferences: preferences)
        store.setAppActive(false)
        let a = UUID(), b = UUID()
        #expect(store.localInstallIsIdle)
        store.setAuxiliaryComposerBusy(a, busy: true)
        store.setAuxiliaryComposerBusy(b, busy: true)
        #expect(!store.localInstallIsIdle)
        store.setAuxiliaryComposerBusy(a, busy: false)
        #expect(!store.localInstallIsIdle)
        store.setAuxiliaryComposerBusy(b, busy: false)
        #expect(store.localInstallIsIdle)
        store.setAutoInstall(false)
        #expect(!store.localInstallIsIdle)
    }

    /// Restarting under the user's hands loses what they were doing; wait until they switch away.
    @Test func frontmostAppDefersInstallUntilItResignsActive() throws {
        let suite = "knarr-install-active-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = LiveKnarrStore(preferences: preferences)
        #expect(!store.localInstallIsIdle)
        store.setAppActive(false)
        #expect(store.localInstallIsIdle)
        store.setAppActive(true)
        #expect(!store.localInstallIsIdle)
    }

    @Test func resigningActiveReleasesTheWaitingInstall() async throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        let main = "4a91b2c0d3e4f5061728394a5b6c7d8e9f001122"
        try commit(fixture, main)
        let builder = RecordingBuilder(), installations = InstallRecorder()
        let busy = BusyBox()
        busy.inputs = .init(runsBusy: false, activeHirds: false, conversationsBusy: false, hasDraft: false, appActive: true)
        let installer = makeInstaller(fixture, builder: builder, installations: installations, gate: { busy.inputs })
        installer.check(mainCommit: main)
        await builder.waitForCallCount(1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(installations.candidates.isEmpty)
        busy.inputs = .init(runsBusy: false, activeHirds: false, conversationsBusy: false, hasDraft: false, appActive: false)
        installer.resumeIfWaiting()
        try await Task.sleep(for: .milliseconds(200))
        #expect(installations.candidates.count == 1)
    }

    // MARK: - Artifact checks

    @Test func currencyOnlyCounterpartIsAccepted() {
        #expect(AutoInstallArtifact.matches(candidateVersion: "ec489d3-dirty", commit: "ec489d3c771c52b9564702bb0cdbc0eafe0e0815"))
        #expect(!AutoInstallArtifact.matches(candidateVersion: "4a91b2c-dirty", commit: "ec489d3c771c52b9564702bb0cdbc0eafe0e0815"))
        #expect(!AutoInstallArtifact.matches(candidateVersion: "", commit: "ec489d3c771c52b9564702bb0cdbc0eafe0e0815"))
    }

    // MARK: - Unavailable and off

    @Test func nonBundleTargetIsUnavailableAndNeverBuilds() async throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        let main = "4a91b2c0d3e4f5061728394a5b6c7d8e9f001122"
        try commit(fixture, main)
        let builder = RecordingBuilder()
        let installations = InstallRecorder()
        let installer = AutoInstaller(policy: policy, target: fixture.source,
            installedVersion: "ec489d3", source: fixture.source, builder: builder,
            install: { try installations.record($0) },
            gate: { .init(runsBusy: false, activeHirds: false, conversationsBusy: false, hasDraft: false) }, enabled: true)
        installer.check(mainCommit: main)
        try await Task.sleep(for: .milliseconds(200))
        if case .unavailable(let text) = installer.phase { #expect(text == policy.reason("bundle")) } else { Issue.record("expected unavailable, got \(installer.phase)") }
        #expect(builder.committed.isEmpty)
        #expect(installations.candidates.isEmpty)
    }

    @Test func disabledSwitchDetectsButBuildsNothing() async throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        let main = "4a91b2c0d3e4f5061728394a5b6c7d8e9f001122"
        try commit(fixture, main)
        let builder = RecordingBuilder()
        let installations = InstallRecorder()
        let installer = makeInstaller(fixture, builder: builder, installations: installations, enabled: false)
        installer.check(mainCommit: main)
        try await Task.sleep(for: .milliseconds(200))
        #expect(installer.phase == .off)
        #expect(builder.committed.isEmpty)
        #expect(installations.candidates.isEmpty)
        #expect(installer.statusLine() == policy.status("off"))
    }

    @Test func serviceUnavailableInstallIsReportedAndDiscardsCandidate() async throws {
        let fixture = try makeFixture(); defer { fixture.clean() }
        let main = "4a91b2c0d3e4f5061728394a5b6c7d8e9f001122"
        try commit(fixture, main)
        let builder = RecordingBuilder()
        let installations = InstallRecorder()
        installations.fail(with: LiveKnarrError.installUnavailable)
        let installer = makeInstaller(fixture, builder: builder, installations: installations)
        installer.check(mainCommit: main)
        await builder.waitForCallCount(1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(installer.statusLine().contains(policy.reason("install")))
        #expect(builder.discardedCommits == [main])
    }

    // MARK: - Policy file

    @Test func policyFilesCarryEveryStatusAndReason() throws {
        let data = try HirdPolicyFiles.resource("auto-install.json")
        let value = try AutoInstallPolicy.decode(data)
        for key in AutoInstallPolicy.statusKeys { #expect(!value.status(key).isEmpty) }
        for key in AutoInstallPolicy.reasonKeys { #expect(!value.reason(key).isEmpty) }
        #expect(value.linkedDirectories.count == 2)
        #expect(value.isFailureLine(value.status("failed", ["reason": "x"])))
        #expect(!value.isFailureLine(value.status("current", ["installed": "a", "main": "b"])))
        #expect(throws: (any Error).self) { try AutoInstallPolicy.decode(Data("{}".utf8)) }
    }
}
