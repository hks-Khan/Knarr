import AppKit
import KnarrCore

/// Synthetic .app probe. No OMP, CloudKit, live store, authentication or signing-store access.
@MainActor final class Probe: NSObject, NSApplicationDelegate {
    let native: MacNotificationClient
    let root: URL
    var service: DesktopNotificationService?
    var repository: SQLiteKnarrRepository?
    var window: NSWindow?
    var exitCode: Int32 = 2
    var routed = false
    var foreground = false
    init(native: MacNotificationClient, root: URL) { self.native = native; self.root = root }
    func record(_ event: String) {
        let row: [String: String] = ["at": ISO8601DateFormatter().string(from: .now), "event": event]
        do {
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data("\n".utf8)
            let url = root.appendingPathComponent("events.jsonl")
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
            print(String(decoding: data, as: UTF8.self), terminator: "")
        } catch { print("QA evidence write failed code=\((error as NSError).code)"); exitCode = 3 }
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        native.observed = { [weak self] event in
            if event.hasPrefix("foreground-banner-list-sound:") { self?.foreground = true }
            self?.record(event)
        }
        native.installDelegate()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 620, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Knarr Notification QA — synthetic only"
        let label = NSTextField(labelWithString: "합성 이슈 알림 QA · 사용자 DB / OMP / CloudKit 미사용\n권한 요청이 나타나면 macOS에서 직접 선택하세요.")
        label.frame = .init(x: 20, y: 40, width: 580, height: 100)
        window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        Task {
            do {
                record("probe-start:pid=\(ProcessInfo.processInfo.processIdentifier)")
                if CommandLine.arguments.contains("--status-only") {
                    let authorization = await native.authorizationStatus()
                    record("permission-check:\(authorization)")
                    exitCode = authorization == .authorized ? 0 : 2
                    stop()
                    return
                }
                let repository = try await SQLiteKnarrRepository.open(at: root.appendingPathComponent("synthetic.db"))
                self.repository = repository
                try await repository.saveProject(.init(id: "notification-qa", name: "Synthetic", absolutePath: root.path))
                let service = try DesktopNotificationService(client: native, ledgerURL: root.appendingPathComponent("receipts.json"))
                self.service = service
                service.observed = { [weak self] in self?.record($0) }
                service.currentSnapshot = { try await repository.snapshot(includeHistory: false) }
                service.activate = { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
                service.selectThread = { [weak self] thread in
                    self?.routed = true
                    label.stringValue = "native 클릭으로 소유 대화 선택: \(thread)\n승인·실행·취소 동작 없음"
                    self?.record("selected-thread:\(thread)")
                }
                native.onOpen = { [weak service] id in Task { await service?.open(id) } }
                await service.observe(try await repository.snapshot(includeHistory: false))
                await service.refreshAuthorization()
                record("initial-authorization:\(service.status.rawValue)")
                // The persisted fixture has a single stable proposal; restart must not post it twice.
                if try await repository.snapshot(includeHistory: false).issues.isEmpty {
                    var issue = Issue(id: "synthetic-approval", title: "Synthetic", projectName: "Synthetic", state: .awaitingApproval,
                                      headline: "", detail: "", acceptance: [], hirds: [], events: [], startedAt: .now)
                    issue.proposal = .init(instruction: "synthetic only; do not execute", model: "synthetic/no-execution")
                    try await repository.saveIssue(issue, projectID: "notification-qa")
                }
                await service.observe(try await repository.snapshot(includeHistory: false))
                record("probe-status:\(service.status.rawValue)")
                // A single bounded interactive observation window, never busy polling.
                try await Task.sleep(for: .seconds(20))
                record("probe-result:accepted=\(service.deliveredIDs.count):foreground=\(foreground):routed=\(routed)")
                exitCode = service.status == .ready && !service.deliveredIDs.isEmpty ? 0 : 2
                try await repository.close()
                self.repository = nil
            } catch {
                record("probe-failed:\((error as NSError).domain):\((error as NSError).code)")
                exitCode = 3
                try? await repository?.close()
            }
            stop()
        }
    }
    private func stop() {
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
    }
}

let app = NSApplication.shared
guard Bundle.main.bundleIdentifier == "com.kyen.knarr.notifications.qa",
      let path = Bundle.main.object(forInfoDictionaryKey: "KnarrNotificationQARoot") as? String,
      let native = MacNotificationClient.makeIfUsable() else {
    print("CLI guard: native center unavailable; use the isolated QA .app")
    exit(2)
}
let root = URL(fileURLWithPath: path, isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let probe = Probe(native: native, root: root)
app.delegate = probe
app.run()
exit(probe.exitCode)
