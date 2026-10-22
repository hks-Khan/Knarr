import Foundation
import Darwin

/// Local snapshot-tool ownership journal. Never discovers or signals processes by name.
enum MenuSmokeLifetime {
    struct Identity: Codable, Equatable {
        var pid: Int32
        var parent: Int32
        var seconds: UInt64
        var microseconds: UInt64
        var role: String
    }
    struct Context: Codable {
        var supervisor: Identity
        var suite: String
        var fault: String?
    }
    struct Cleanup: Codable {
        var reason: String
        var records: [Identity]
        var excludedPID: Int32?
        var remaining: [Int32]
    }
    enum Failure: Error { case missingIdentity(Int32), invalidOwnership, remaining([Int32]) }

    static func authorizeChild(out: URL, role: String) throws -> Context {
        let context = try JSONDecoder().decode(Context.self, from: Data(contentsOf: out.appendingPathComponent("menu-lifetime.json")))
        guard context.suite.hasPrefix("knarr-issue-menu-smoke-"), matches(context.supervisor) else { throw Failure.invalidOwnership }
        let parentFile = out.appendingPathComponent("menu-process-\(getppid()).json")
        let parent = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: parentFile))
        guard parent.pid == getppid(), matches(parent),
              role == "worker" ? parent == context.supervisor : (parent.role == "worker" && parent.parent == context.supervisor.pid && context.fault != nil)
        else { throw Failure.invalidOwnership }
        if role == "worker" {
            // Parent records ownership before the worker is allowed to spawn a capture.
            let file = out.appendingPathComponent("menu-process-\(getpid()).json")
            let deadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: file.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let own = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: file))
            guard own.pid == getpid(), own.parent == parent.pid, own.role == role, matches(own) else { throw Failure.invalidOwnership }
        }
        return context
    }

    static func info(_ pid: Int32) -> proc_bsdinfo? {
        var value = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size ? value : nil
    }
    @discardableResult static func record(_ pid: Int32, role: String, out: URL) throws -> Identity {
        guard let info = info(pid), info.pbi_ppid == UInt32(pid == getpid() ? getppid() : getpid()) else {
            throw Failure.missingIdentity(pid)
        }
        let identity = Identity(pid: pid, parent: Int32(info.pbi_ppid), seconds: info.pbi_start_tvsec,
                                microseconds: info.pbi_start_tvusec, role: role)
        try JSONEncoder().encode(identity).write(to: out.appendingPathComponent("menu-process-\(pid).json"), options: .atomic)
        print("MENU OWNED role=\(role) pid=\(pid) ppid=\(identity.parent) birth=\(identity.seconds).\(identity.microseconds)")
        fflush(stdout)
        return identity
    }
    static func exited(_ process: Process, out: URL) throws {
        let result = ["pid": process.processIdentifier, "status": process.terminationStatus,
                      "reason": Int32(process.terminationReason.rawValue)]
        try JSONEncoder().encode(result).write(to: out.appendingPathComponent("menu-exit-\(process.processIdentifier).json"), options: .atomic)
        print("MENU REAP pid=\(process.processIdentifier) status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)")
    }
    static func matches(_ identity: Identity) -> Bool {
        guard let info = info(identity.pid) else {
            // Treat an uninspectable extant PID as a cleanup failure, never permission to signal it.
            return kill(identity.pid, 0) == 0 || errno == EPERM
        }
        return info.pbi_start_tvsec == identity.seconds && info.pbi_start_tvusec == identity.microseconds
    }
    private static func signal(_ identity: Identity, _ signal: Int32) {
        guard let current = info(identity.pid), current.pbi_start_tvsec == identity.seconds,
              current.pbi_start_tvusec == identity.microseconds else { return }
        let result = kill(identity.pid, signal)
        print("MENU SIGNAL role=\(identity.role) pid=\(identity.pid) signal=\(signal) result=\(result)")
        fflush(stdout)
    }
    static func reclaim(out: URL, external: Bool, reason: String) throws -> Cleanup {
        let context = try JSONDecoder().decode(Context.self, from: Data(contentsOf: out.appendingPathComponent("menu-lifetime.json")))
        let root = context.supervisor
        guard context.suite.hasPrefix("knarr-issue-menu-smoke-"), root.role == "supervisor",
              external ? root.parent == getppid() : root.pid == getpid() else { throw Failure.invalidOwnership }
        let urls = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        let records = try urls.filter { $0.lastPathComponent.hasPrefix("menu-process-") && $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(Identity.self, from: Data(contentsOf: $0)) }
        guard records.contains(root), Set(records.map(\.pid)).count == records.count else { throw Failure.invalidOwnership }
        for record in records where record != root {
            guard record.pid != getpid(), record.pid != getppid(),
                  let parent = records.first(where: { $0.pid == record.parent }),
                  (record.role == "worker" && parent == root) || (record.role == "capture" && parent.role == "worker"),
                  record.seconds >= parent.seconds else { throw Failure.invalidOwnership }
        }
        let order = ["capture": 0, "worker": 1, "supervisor": 2]
        let owned = records.filter { external || $0.pid != root.pid }.sorted { order[$0.role, default: 3] < order[$1.role, default: 3] }
        // Leaves first: their still-living Process owner can reap them before that owner is stopped.
        for identity in owned where matches(identity) {
            signal(identity, SIGTERM)
            var deadline = Date().addingTimeInterval(0.25)
            while matches(identity) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if matches(identity) { signal(identity, SIGKILL) }
            deadline = Date().addingTimeInterval(2)
            while matches(identity) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        }
        UserDefaults.standard.removePersistentDomain(forName: context.suite)
        let cleanup = Cleanup(reason: reason, records: records.sorted { $0.pid < $1.pid },
                              excludedPID: external ? nil : root.pid, remaining: owned.filter(matches).map(\.pid))
        try JSONEncoder().encode(cleanup).write(to: out.appendingPathComponent(external ? "menu-external-cleanup.json" : "menu-cleanup.json"), options: .atomic)
        print("MENU CLEANUP reason=\(reason) owned=\(owned.map(\.pid)) remaining=\(cleanup.remaining)")
        fflush(stdout)
        guard cleanup.remaining.isEmpty else { throw Failure.remaining(cleanup.remaining) }
        return cleanup
    }
}
