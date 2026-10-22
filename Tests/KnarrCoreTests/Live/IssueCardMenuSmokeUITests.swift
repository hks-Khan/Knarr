import Foundation
import Testing
import Darwin

/// AppKit tracking and lifecycle faults run in fresh, explicitly owned processes.
@Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct IssueCardMenuSmokeUITests {
    private struct Identity: Decodable {
        var pid: Int32
        var parent: Int32
        var seconds: UInt64
        var microseconds: UInt64
        var role: String
    }
    private struct Cleanup: Decodable {
        var records: [Identity]
        var remaining: [Int32]
        var reason: String
    }
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private struct ExitWaitFailure: Error {
        var pid: Int32
    }
    private struct ExitWaitEvidence: Encodable {
        var pid: Int32
        var waiter: Int32
        var parent: UInt32?
        var seconds: UInt64?
        var microseconds: UInt64?
        var role: String
        var remaining: Bool
    }
    /// Never turn a cleanup deadline into an unconditional wait after SIGKILL.
    private func finish(_ process: Process, out: URL, role: String, stop: Bool = false) throws {
        if stop && process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !process.isRunning else {
            let pid = process.processIdentifier
            var info = proc_bsdinfo()
            let inspected = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size
            let evidence = ExitWaitEvidence(pid: pid, waiter: getpid(), parent: inspected ? info.pbi_ppid : nil,
                                           seconds: inspected ? info.pbi_start_tvsec : nil,
                                           microseconds: inspected ? info.pbi_start_tvusec : nil,
                                           role: role, remaining: kill(pid, 0) == 0 || errno == EPERM)
            let file = out.appendingPathComponent("menu-wait-timeout-\(pid).json")
            try JSONEncoder().encode(evidence).write(to: file, options: .atomic)
            print("MENU WAIT TIMEOUT role=\(role) pid=\(pid) waiter=\(getpid()) remaining=\(evidence.remaining) evidence=\(file.path)")
            throw ExitWaitFailure(pid: pid)
        }
        // Foundation has observed termination; only now is the unbounded API safe to call.
        process.waitUntilExit()
    }
    private func reclaim(_ process: Process, executable: URL, out: URL) throws {
        if FileManager.default.fileExists(atPath: out.appendingPathComponent("menu-lifetime.json").path) {
            let cleanup = Process()
            cleanup.executableURL = executable
            cleanup.arguments = [out.path, "issue-card-menu-internal-reclaim"]
            try cleanup.run()
            print("MENU CALLER RECLAIMER pid=\(cleanup.processIdentifier) ppid=\(getpid())")
            defer {
                do { try finish(cleanup, out: out, role: "reclaimer", stop: true) }
                catch { Issue.record("Reclaimer exit was not observed: \(error); evidence retained at \(out.path)") }
            }
            let deadline = Date().addingTimeInterval(15)
            while cleanup.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            try #require(!cleanup.isRunning, "Owned menu recovery exceeded its deadline; evidence: \(out.path)")
            try finish(cleanup, out: out, role: "reclaimer")
            print("MENU CALLER RECLAIMER END pid=\(cleanup.processIdentifier) exit=\(cleanup.terminationStatus)")
            try #require(cleanup.terminationStatus == 0)
            #expect(kill(cleanup.processIdentifier, 0) == -1 && errno == ESRCH)
        }
        try finish(process, out: out, role: "supervisor", stop: true)
    }
    private func exercise(_ fault: String?) throws {
        let executable = root.appendingPathComponent(".build/debug/knarr-snapshot")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path), "Build knarr-snapshot first")
        let retained = ProcessInfo.processInfo.environment["KNARR_MENU_SMOKE_EVIDENCE"]
        let base = retained.map { root.appendingPathComponent($0) } ?? root.appendingPathComponent(".build")
        try #require(base.standardizedFileURL.path.hasPrefix(root.appendingPathComponent(".build").path))
        let out = base.appendingPathComponent("issue-menu-\(fault ?? "normal")-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("MENU CALLER evidence=\(out.path)")
        let process = Process()
        process.executableURL = executable
        process.arguments = [out.path, fault == nil ? "issue-card-menu-smoke" : "issue-card-menu-internal-fault"] + (fault.map { [$0] } ?? [])
        var started = false
        var recovered = false
        var passed = false
        defer {
            if started && !recovered {
                do { try reclaim(process, executable: executable, out: out) }
                catch { Issue.record("Menu cleanup failed: \(error); evidence retained at \(out.path)") }
            }
            if passed && retained == nil { try? FileManager.default.removeItem(at: out) }
        }
        try process.run()
        started = true
        print("MENU CALLER START pid=\(process.processIdentifier) ppid=\(getpid()) fault=\(fault ?? "none")")
        var deadline = Date().addingTimeInterval(65)
        if fault == "external-deadline" {
            let ready = out.appendingPathComponent("menu-open-entered")
            let startup = Date().addingTimeInterval(10)
            while process.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < startup {
                Thread.sleep(forTimeInterval: 0.02)
            }
            try #require(FileManager.default.fileExists(atPath: ready.path), "Fault never entered the menu-open closure")
            // The same external-deadline cleanup as the normal test, with a deterministic short deadline.
            deadline = Date().addingTimeInterval(0.2)
        }
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let timedOut = process.isRunning
        if fault == "external-deadline" {
            // Reproduce the old supervisor-only hard stop, then exercise recovery of its orphans.
            try finish(process, out: out, role: "external-supervisor", stop: true)
            let files = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            let children = try files.filter { $0.lastPathComponent.hasPrefix("menu-process-") }
                .map { try JSONDecoder().decode(Identity.self, from: Data(contentsOf: $0)) }
                .filter { $0.role != "supervisor" }
            try #require(children.count == 2)
            for child in children {
                #expect(kill(child.pid, 0) == 0, "Fault did not leave the expected owned child")
            }
            print("MENU EXTERNAL HARD STOP supervisor=\(process.processIdentifier) survivingOwnedChildren=\(children.map(\.pid).sorted())")
        }
        try reclaim(process, executable: executable, out: out)
        recovered = true
        print("MENU CALLER END pid=\(process.processIdentifier) exit=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) externalDeadline=\(timedOut)")
        try JSONEncoder().encode(["pid": process.processIdentifier, "status": process.terminationStatus,
                                  "reason": Int32(process.terminationReason.rawValue)])
            .write(to: out.appendingPathComponent("menu-caller-exit.json"))
        #expect(timedOut == (fault == "external-deadline"))
        #expect(kill(process.processIdentifier, 0) == -1 && errno == ESRCH)
        let cleanup = try JSONDecoder().decode(Cleanup.self, from: Data(contentsOf: out.appendingPathComponent("menu-external-cleanup.json")))
        try #require(cleanup.remaining.isEmpty)
        try #require(cleanup.records.count == 3, "Expected supervisor, worker and capture, not an empty/partial run")
        let supervisor = try #require(cleanup.records.first { $0.role == "supervisor" })
        let worker = try #require(cleanup.records.first { $0.role == "worker" })
        let capture = try #require(cleanup.records.first { $0.role == "capture" })
        #expect(supervisor.pid == process.processIdentifier && supervisor.parent == getpid())
        #expect(worker.parent == supervisor.pid && capture.parent == worker.pid)
        for record in cleanup.records {
            #expect(record.seconds > 0)
            #expect(kill(record.pid, 0) == -1 && errno == ESRCH, "Recorded child still exists: \(record.pid)")
        }
        let contextData = try Data(contentsOf: out.appendingPathComponent("menu-lifetime.json"))
        let context = try #require(JSONSerialization.jsonObject(with: contextData) as? [String: Any])
        let suite = try #require(context["suite"] as? String)
        #expect(UserDefaults.standard.persistentDomain(forName: suite) == nil)
        let successFile = out.appendingPathComponent("issue-card-menu.json")
        if let fault {
            #expect(process.terminationStatus != 0)
            #expect(!FileManager.default.fileExists(atPath: successFile.path), "Fault must never report six successful scenarios")
            if fault != "external-deadline" {
                let own = try JSONDecoder().decode(Cleanup.self, from: Data(contentsOf: out.appendingPathComponent("menu-cleanup.json")))
                #expect(own.reason == (fault == "no-menu-tracking" ? "workerDeadline" : "workerExit"))
                let status = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("menu-exit-\(worker.pid).json"))) as? [String: Int32])
                #expect(status["status"] == (fault == "worker-exit" ? 42 : fault == "no-menu-tracking" ? SIGKILL : 1))
            }
            if fault == "capture-timeout" {
                let status = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("menu-exit-\(capture.pid).json"))) as? [String: Int32])
                #expect(status["status"] == SIGKILL)
            }
        } else {
            #expect(process.terminationStatus == 0)
            let evidence = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: successFile)) as? [String: Any])
            #expect(evidence["completedScenarios"] as? Int == 6)
            #expect(evidence["parentProcessID"] as? Int32 == process.processIdentifier)
        }
        passed = true
    }
    @Test func displayedPopupAndRightClickApplyAllSixActions() throws { try exercise(nil) }

    @Test(arguments: ["no-menu-tracking", "capture-timeout", "worker-exit", "external-deadline"])
    func interruptedMenusReclaimTheSameRecordedProcessSet(fault: String) throws { try exercise(fault) }
}
