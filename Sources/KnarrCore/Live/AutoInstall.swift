import Foundation
import Darwin

/// File-owned wording and limits. No Swift literal carries the little it shows or the paths it uses.
public struct AutoInstallPolicy: Decodable, Sendable {
    public let title: String
    let sourceScript: String
    let sourceMarkers: [String]
    let buildTimeoutSeconds: Double
    let verifyTimeoutSeconds: Double
    let rootDirectoryName: String
    let worktreeDirectoryName: String
    let buildDirectoryName: String
    let candidateDirectoryName: String
    let linkedDirectories: [String]
    let candidateRelativePath: String
    let statuses: [String: String]
    let reasons: [String: String]

    static let statusKeys = ["off", "unavailable", "current", "waiting", "building", "installing", "failed"]
    static let reasonKeys = ["bundle", "version", "script", "main", "worktree", "command", "timeout", "signature", "candidate", "mismatch", "install"]

    public static let current = try! decode(HirdPolicyFiles.resource("auto-install.json"))

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.buildTimeoutSeconds.isFinite, value.buildTimeoutSeconds > 0,
              value.verifyTimeoutSeconds.isFinite, value.verifyTimeoutSeconds > 0,
              !value.title.isEmpty, !value.sourceScript.isEmpty, !value.candidateRelativePath.isEmpty,
              !value.rootDirectoryName.isEmpty, !value.worktreeDirectoryName.isEmpty,
              !value.buildDirectoryName.isEmpty, !value.candidateDirectoryName.isEmpty,
              value.linkedDirectories.count == 2,
              !value.sourceMarkers.isEmpty, value.sourceMarkers.allSatisfy({ !$0.isEmpty }),
              statusKeys.allSatisfy({ !(value.statuses[$0] ?? "").isEmpty }),
              reasonKeys.allSatisfy({ !(value.reasons[$0] ?? "").isEmpty }) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    public func status(_ key: String, _ values: [String: String] = [:]) -> String {
        var text = statuses[key] ?? ""
        for (name, value) in values { text = text.replacingOccurrences(of: "{" + name + "}", with: value) }
        return text
    }

    public func reason(_ key: String) -> String { reasons[key] ?? "" }

    /// True when a status line is the failure wording, so Settings can use the error color.
    public func isFailureLine(_ text: String) -> Bool {
        guard let template = statuses["failed"], let marker = template.firstIndex(of: "{") else { return false }
        let prefix = String(template[..<marker])
        return !prefix.isEmpty && text.hasPrefix(prefix)
    }
}

// MARK: - Waiting gate

/// Pure decision input. Never touches the app bundle, so tests exercise it without a process.
enum AutoInstallGate {
    struct Inputs: Sendable, Equatable {
        let runsBusy: Bool
        let activeHirds: Bool
        let conversationsBusy: Bool
        let hasDraft: Bool
        /// Knarr is the frontmost app; restarting would interrupt whoever is looking at it.
        var appActive = false
    }

    static func allows(_ inputs: Inputs) -> Bool {
        !inputs.runsBusy && !inputs.activeHirds && !inputs.conversationsBusy && !inputs.hasDraft && !inputs.appActive
    }
}

// MARK: - Artifact inspection

/// Reads a candidate app the current process is not running, so `Bundle` cannot be used.
enum AutoInstallArtifact {
    static func version(ofAppAt url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = value as? [String: Any] else { return nil }
        return (dictionary["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// build-app.sh appends `-dirty` whenever the tree it built had local changes, so the
    /// commit comparison always strips that suffix from both sides.
    static func normalized(_ version: String) -> String {
        version.hasSuffix("-dirty") ? String(version.dropLast("-dirty".count)) : version
    }

    static func matches(candidateVersion: String, commit: String) -> Bool {
        let base = normalized(candidateVersion)
        return !base.isEmpty && commit.hasPrefix(base)
    }
}

enum AutoInstallSource {
    static func find(in roots: [URL], policy: AutoInstallPolicy = .current) -> URL? {
        roots.first { root in
            ([policy.sourceScript] + policy.sourceMarkers).allSatisfy {
                FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
            }
        }
    }
}

// MARK: - Candidate

struct AutoInstallCandidate: Sendable, Equatable {
    let app: URL
    let version: String
    let commit: String
}

enum AutoInstallFailure: Error, Sendable {
    case reason(String)
}

protocol AutoInstallBuilding: Sendable {
    func build(commit: String) async throws -> AutoInstallCandidate
    func discard(_ candidate: AutoInstallCandidate) async
}

// MARK: - Default builder

private struct AutoInstallCleanupFailure: Error { let remainingProcessIDs: [Int32] }

private final class AutoInstallDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    func expire() { lock.withLock { expired = true } }
    var timedOut: Bool { lock.withLock { expired } }
}

struct DefaultAutoInstallBuilder: AutoInstallBuilding {
    let sourceRoot: URL
    let root: URL
    let policy: AutoInstallPolicy

    init(sourceRoot: URL, root: URL, policy: AutoInstallPolicy) {
        self.sourceRoot = sourceRoot
        self.root = root
        self.policy = policy
    }

    func build(commit: String) async throws -> AutoInstallCandidate {
        guard commit.count == 40 else { throw AutoInstallFailure.reason(policy.reason("mismatch")) }
        let script = sourceRoot.appendingPathComponent(policy.sourceScript)
        guard FileManager.default.isExecutableFile(atPath: sourceRoot.path), FileManager.default.fileExists(atPath: script.path) else {
            throw AutoInstallFailure.reason(policy.reason("script"))
        }
        try HirdSecureFile.checkAncestors(root)
        try HirdSecureFile.createDirectory(root)
        let slot = root.appendingPathComponent(UUID().uuidString.lowercased())
        try HirdSecureFile.createDirectory(slot)
        let worktree = slot.appendingPathComponent(policy.worktreeDirectoryName)
        let scratch = slot.appendingPathComponent(policy.buildDirectoryName)
        let candidateApp = slot.appendingPathComponent(policy.candidateDirectoryName)
        var added = false
        func unlinkWorktree() async throws {
            guard added else { return }
            added = false
            _ = try? await HirdWorkspace.git(["worktree", "remove", "--force", worktree.path], at: sourceRoot)
            try? FileManager.default.removeItem(at: worktree)
            try? FileManager.default.removeItem(at: scratch)
        }
        do {
            _ = try await HirdWorkspace.git(["worktree", "add", "--detach", worktree.path, commit], at: sourceRoot)
            added = true
            for relative in policy.linkedDirectories {
                let target = sourceRoot.appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: target.path) else { throw AutoInstallFailure.reason(policy.reason("worktree")) }
                let link = worktree.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            }
            try await run(executable: URL(fileURLWithPath: "/bin/bash"),
                          arguments: [worktree.appendingPathComponent(policy.sourceScript).path],
                          workingDirectory: worktree, extraEnvironment: ["KNARR_BUILD_ROOT": scratch.path],
                          timeout: policy.buildTimeoutSeconds, reason: "command")
            let built = worktree.appendingPathComponent(policy.candidateRelativePath)
            guard FileManager.default.fileExists(atPath: built.appendingPathComponent("Contents/MacOS/Knarr").path) else {
                throw AutoInstallFailure.reason(policy.reason("candidate"))
            }
            guard let version = AutoInstallArtifact.version(ofAppAt: built) else { throw AutoInstallFailure.reason(policy.reason("candidate")) }
            guard AutoInstallArtifact.matches(candidateVersion: version, commit: commit) else {
                throw AutoInstallFailure.reason(policy.reason("mismatch"))
            }
            try await run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                          arguments: ["--verify", "--strict", built.path],
                          workingDirectory: slot, extraEnvironment: [:],
                          timeout: policy.verifyTimeoutSeconds, reason: "signature")
            try? FileManager.default.removeItem(at: candidateApp)
            try FileManager.default.copyItem(at: built, to: candidateApp)
            try await unlinkWorktree()
            return AutoInstallCandidate(app: candidateApp, version: version, commit: commit)
        } catch let failure as AutoInstallCleanupFailure {
            // Preserve the worktree and exact residual IDs until cleanup can be confirmed.
            let report: [String: Any] = ["remainingProcessIDs": failure.remainingProcessIDs, "worktree": worktree.path, "scratch": scratch.path]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
                try? data.write(to: slot.appendingPathComponent("cleanup-failure.json"), options: .atomic)
            }
            throw AutoInstallFailure.reason(policy.reason("command"))
        } catch {
            try? await unlinkWorktree()
            try? FileManager.default.removeItem(at: slot)
            throw error
        }
    }

    func discard(_ candidate: AutoInstallCandidate) async {
        try? FileManager.default.removeItem(at: candidate.app.deletingLastPathComponent())
    }

    /// Runs one bounded command. Output is drained but not retained; the policy line names the cause.
    private func run(executable: URL, arguments: [String], workingDirectory: URL,
                     extraEnvironment: [String: String], timeout: Double, reason: String) async throws {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ShellPath.merged(current: environment["PATH"], login: ShellPath.login, home: NSHomeDirectory())
        for (key, value) in extraEnvironment { environment[key] = value }
        let process: OwnedOMPProcess
        do {
            process = try OwnedOMPProcess(.init(executable: executable, workingDirectory: workingDirectory,
                                                arguments: arguments, environment: environment))
        } catch { throw AutoInstallFailure.reason(policy.reason(reason)) }
        process.closeInput()
        let state = AutoInstallDeadline()
        let deadline = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
                state.expire()
                process.signalOwnedGroup(SIGTERM)
                process.signalOwnedGroup(SIGKILL)
            } catch {}
        }
        defer { deadline.cancel() }
        var status: Int32 = -1
        var remaining: [Int32] = []
        await withTaskCancellationHandler {
            for await event in process.output {
                switch event {
                case .bytes, .failure: break
                case .exit(let value, let residual): status = value; remaining = residual
                }
            }
        } onCancel: {
            process.signalOwnedGroup(SIGTERM)
            process.signalOwnedGroup(SIGKILL)
        }
        guard remaining.isEmpty else { throw AutoInstallCleanupFailure(remainingProcessIDs: remaining) }
        try Task.checkCancellation()
        if state.timedOut { throw AutoInstallFailure.reason(policy.reason("timeout")) }
        guard status == 0 else { throw AutoInstallFailure.reason(policy.reason(reason)) }
    }
}

// MARK: - Coordinator

/// Owns one in-flight build, one verified candidate, and the waiting gate. No timer: the
/// store calls `resumeIfWaiting()` when a conversation or run becomes idle.
@MainActor final class AutoInstaller {
    enum Phase: Sendable, Equatable {
        case off
        case unavailable(String)
        case current(installed: String, main: String)
        case waiting(installed: String, main: String)
        case building(main: String)
        case installing(main: String)
        case failed(String)
    }

    private let policy: AutoInstallPolicy
    private let builder: (any AutoInstallBuilding)?
    private let install: @MainActor (AutoInstallCandidate) async throws -> Void
    private let gate: @MainActor () async -> AutoInstallGate.Inputs
    let source: URL?

    private var installTask: Task<Void, Never>?
    private(set) var phase: Phase = .off { didSet { if phase != oldValue { onPhaseChange?() } } }
    var onPhaseChange: (@MainActor () -> Void)?

    private var installed: String?
    private var enabled: Bool
    private var working: Task<Void, Never>?
    private var pendingInstall: AutoInstallCandidate?
    private var builtCommit: String?
    private var installing = false
    private var latestCommit: String?
    private var generation = UUID()
    private(set) var failedCommit: String?
    private(set) var failedReason: String?

    init(policy: AutoInstallPolicy = .current, target: URL, installedVersion: String?, source: URL?,
         builder: (any AutoInstallBuilding)?,
         install: @escaping @MainActor (AutoInstallCandidate) async throws -> Void,
         gate: @escaping @MainActor () async -> AutoInstallGate.Inputs,
         enabled: Bool,
         failedCommit: String? = nil, failedReason: String? = nil) {
        self.policy = policy
        self.builder = builder
        self.install = install
        self.gate = gate
        self.source = source
        self.enabled = enabled
        self.failedCommit = failedCommit
        self.failedReason = failedReason
        if target.pathExtension != "app" || !FileManager.default.fileExists(atPath: target.path) {
            phase = .unavailable(policy.reason("bundle"))
        } else if let installedVersion, !installedVersion.isEmpty {
            installed = installedVersion
            phase = .current(installed: short(installedVersion), main: short(installedVersion))
        } else {
            phase = .unavailable(policy.reason("version"))
        }
        if case .unavailable = phase {} else if source == nil || builder == nil {
            phase = .unavailable(policy.reason("script"))
        } else if !enabled {
            phase = .off
        }
    }

    /// Detection entry point. Called at start, on app activation, and after an approval commits.
    func check(mainCommit: String?) {
        if case .unavailable = phase { return }
        guard enabled else { phase = .off; return }
        guard let installed, source != nil else { return }
        guard let mainCommit, mainCommit.count == 40 else { phase = .failed(policy.reason("main")); return }
        if latestCommit != mainCommit {
            latestCommit = mainCommit
            invalidatePendingWork()
        }
        if installing || working != nil { return }
        if mainCommit.hasPrefix(AutoInstallArtifact.normalized(installed)) {
            phase = .current(installed: short(installed), main: short(mainCommit)); return
        }
        if failedCommit == mainCommit, let failedReason { phase = .failed(failedReason); return }
        if let candidate = pendingInstall, builtCommit == mainCommit {
            beginInstall(main: mainCommit); return
        }
        startBuild(commit: mainCommit)
    }

    func enabledChanged(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            // Turning the switch back on is the manual retry for a failed commit.
            failedCommit = nil
            failedReason = nil
            return
        }
        invalidatePendingWork()
        phase = .off
    }

    private func invalidatePendingWork() {
        generation = UUID()
        working?.cancel(); working = nil
        installTask?.cancel(); installTask = nil
        installing = false
        if let candidate = pendingInstall, let builder {
            Task { await builder.discard(candidate) }
        }
        pendingInstall = nil; builtCommit = nil
    }

    /// The only release path for a waiting install. Called when busy state changes; never on a timer.
    func resumeIfWaiting() {
        guard enabled, working == nil, !installing, let candidate = pendingInstall, candidate.commit == latestCommit else { return }
        beginInstall(main: candidate.commit)
    }

    func statusLine() -> String {
        switch phase {
        case .off: policy.status("off")
        case .unavailable(let reason): policy.status("unavailable", ["reason": reason])
        case .current(let installed, let main): policy.status("current", ["installed": installed, "main": main])
        case .waiting(let installed, let main): policy.status("waiting", ["installed": installed, "main": main])
        case .building(let main): policy.status("building", ["main": main])
        case .installing(let main): policy.status("installing", ["main": main])
        case .failed(let reason): policy.status("failed", ["reason": reason])
        }
    }

    private func startBuild(commit: String) {
        guard let builder else { return }
        let token = generation
        phase = .building(main: short(commit))
        working = Task { [weak self] in
            guard let self else { return }
            do {
                let candidate = try await builder.build(commit: commit)
                guard !Task.isCancelled, self.generation == token else { await builder.discard(candidate); return }
                self.finishBuild(candidate: candidate, commit: commit, failure: nil)
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                let text = (error as? AutoInstallFailure).flatMap { if case .reason(let value) = $0 { value } else { nil } } ?? self.policy.reason("command")
                self.finishBuild(candidate: nil, commit: commit, failure: text)
            }
        }
    }

    private func finishBuild(candidate: AutoInstallCandidate?, commit: String, failure: String?) {
        working = nil
        if let failure {
            failedCommit = commit
            failedReason = failure
            phase = .failed(failure)
            return
        }
        guard let candidate else { return }
        if !enabled { if let builder { Task { await builder.discard(candidate) } }; return }
        pendingInstall = candidate
        builtCommit = commit
        beginInstall(main: commit)
    }

    private func beginInstall(main: String) {
        guard enabled, !installing, main == latestCommit else { return }
        let token = generation
        installing = true
        phase = .waiting(installed: short(installed ?? ""), main: short(main))
        guard let candidate = pendingInstall else { installing = false; return }
        installTask = Task { [self] in
            let inputs = await gate()
            guard !Task.isCancelled, enabled, generation == token, latestCommit == candidate.commit else { return }
            guard AutoInstallGate.allows(inputs) else {
                // Stay waiting: `resumeIfWaiting()` re-enters when the busy state clears.
                installing = false
                installTask = nil
                return
            }
            phase = .installing(main: short(main))
            do {
                try await install(candidate)
            } catch {
                guard !Task.isCancelled, enabled, generation == token else { return }
                installing = false
                if let error = error as? LiveKnarrError, case .installBusy = error {
                    installTask = nil
                    phase = .waiting(installed: short(installed ?? ""), main: short(main))
                    beginInstall(main: main)
                    return
                }
                installTask = nil
                pendingInstall = nil
                builtCommit = nil
                if let builder { await builder.discard(candidate) }
                phase = .failed(policy.reason("install"))
                return
            }
            guard !Task.isCancelled, enabled, generation == token else { return }
            // Production never returns here: the install helper terminates the app.
            installing = false
            installTask = nil
            pendingInstall = nil
            installed = candidate.commit
            builtCommit = nil
            phase = .current(installed: short(candidate.commit), main: short(main))
        }
    }

    private func short(_ commit: String) -> String { String(commit.prefix(7)) }
}
