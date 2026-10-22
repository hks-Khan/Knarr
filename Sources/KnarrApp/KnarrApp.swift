import AppKit
import SwiftUI
import KnarrCore
import KnarrMirror
import KnarrMCP
import KnarrUI

@main
struct KnarrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // One Stallari for every project: projects live in Knarr's database, Jitdeck's are imported on first run.
    @State private var store = LiveKnarrStore()
    // Mirrors the store to the person's iPhone through their private iCloud database.
    @State private var mirror = CloudMirror()
    @State private var qaStore: SampleKnarrStore? = nil
    @State private var hiveConnection: HiveConnection?
    @State private var hiveTransfer: HiveCredentialTransfer?
    private let isHiveTransferMode: Bool
    private let hiveConfiguration: LiveKnarrConfiguration?

    init() {
        let transferLaunch = HiveTransferLaunch(arguments: CommandLine.arguments)
        isHiveTransferMode = HiveTransferLaunch.isRequested(CommandLine.arguments)
        if case let .ready(source, destination) = transferLaunch {
            _hiveTransfer = State(initialValue: HiveCredentialTransfer(sourceDirectory: source, destinationDirectory: destination))
        }
        if !isHiveTransferMode, CommandLine.arguments.contains("--hive-connection") {
            let configuration = LiveKnarrConfiguration.standard()
            hiveConfiguration = configuration
            _hiveConnection = State(initialValue: HiveConnection(serviceNamespace: HiveConnection.serviceNamespace(dataDirectory: configuration.dataDirectory)))
        } else {
            hiveConfiguration = nil
        }
        guard !isHiveTransferMode else { return }
        if Bundle.main.bundleIdentifier == "com.kyen.knarr.qa" {
            let data = ProcessInfo.processInfo.environment["KNARR_DATA_DIRECTORY"] ?? FileManager.default.currentDirectoryPath + "/outputs/qa-candidate/data"
            _qaStore = State(initialValue: SampleKnarrStore(qaProjectPath: URL(fileURLWithPath: data).deletingLastPathComponent().appendingPathComponent("project").path, animated: true))
        } else if ProcessInfo.processInfo.environment["KNARR_CLOUD_SEED_SCHEMA"] == "1" {
            CloudMirror.seedSchemaAndExit()
        }
    }

    var body: some Scene {
        WindowGroup(isHiveTransferMode ? "Hive 연결 복사" : "Knarr") {
            if isHiveTransferMode {
                Group {
                    if let hiveTransfer {
                        HiveCredentialTransferView(transfer: hiveTransfer)
                    } else {
                        HiveCredentialTransferLaunchErrorView()
                    }
                }
                .frame(minWidth: 560, minHeight: 480)
            } else if let hiveConnection, let hiveConfiguration {
                HiveConnectionSettings(connection: hiveConnection, verify: {
                    await hiveConnection.verify {
                        let installation = try OMPInstallation(executable: hiveConfiguration.executable)
                        let root = hiveConfiguration.dataDirectory.appendingPathComponent("hive-verification")
                        let receipt = try await HiveOMPProbe.run(installation: installation, runtime: hiveConnection.runtime, root: root)
                        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("latest.json"), options: .atomic)
                    }
                })
                .padding()
                .frame(minWidth: 560, minHeight: 360)
            } else if let qaStore {
                HomeView(store: qaStore)
                    .frame(minWidth: 720, minHeight: 540)
            } else {
                HomeView(store: store)
                    .frame(minWidth: 720, minHeight: 540)
                    .task {
                        delegate.store = store
                        delegate.mirror = mirror
                        store.installHandoff = { job in try delegate.installAndRestart(job) }
                        let configuration = LiveKnarrConfiguration.standard()
                        delegate.connectNotifications(store: store, dataDirectory: configuration.dataDirectory)
                        store.start(configuration)
                        mirror.start(store: store)
                        delegate.startMCPServer(store: store, configuration: configuration)
                    }
            }
        }
        .defaultSize(width: 1120, height: 780)
        .windowStyle(.hiddenTitleBar)
        MenuBarExtra(isInserted: .constant(!isHiveTransferMode)) {
            MenuBarUsageView(usage: qaStore?.subscriptionUsage ?? store.subscriptionUsage)
        } label: {
            MenuBarUsageLabel(usage: qaStore?.subscriptionUsage ?? store.subscriptionUsage)
        }
        .menuBarExtraStyle(.window)
    }
}

/// These arguments bind credential namespaces; they never carry a credential.
private enum HiveTransferLaunch {
    case absent
    case ready(source: URL, destination: URL)
    case invalid

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { argument in
            ["--hive-transfer", "--hive-source-data-directory", "--hive-destination-data-directory"].contains {
                argument == $0 || argument.hasPrefix($0 + "=")
            }
        }
    }

    init(arguments: [String]) {
        guard Self.isRequested(arguments) else { self = .absent; return }
        let arguments = Array(arguments.dropFirst())
        var index = 0
        var requested = false
        var source: URL?
        var destination: URL?
        while index < arguments.count {
            switch arguments[index] {
            case "--hive-transfer":
                guard !requested else { self = .invalid; return }
                requested = true
            case "--hive-source-data-directory", "--hive-destination-data-directory":
                let isSource = arguments[index] == "--hive-source-data-directory"
                guard index + 1 < arguments.count,
                      arguments[index + 1].hasPrefix("/"),
                      isSource ? source == nil : destination == nil else {
                    self = .invalid
                    return
                }
                index += 1
                let directory = URL(fileURLWithPath: arguments[index], isDirectory: true).standardizedFileURL
                if isSource { source = directory } else { destination = directory }
            default:
                self = .invalid
                return
            }
            index += 1
        }
        guard requested, let source, let destination else { self = .invalid; return }
        self = .ready(source: source, destination: destination)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: LiveKnarrStore?
    var mirror: CloudMirror?
    private var mcpHost: MCPHost?
    private var termination: Task<Void, Never>?
    private let nativeNotifications = HiveTransferLaunch.isRequested(CommandLine.arguments) ? nil : MacNotificationClient.makeIfUsable()
    private var notificationService: DesktopNotificationService?
    /// Native integration QA keeps the real store/host while protecting the user's focus.
    /// This is available only to the separately packaged, unentitled QA application.
    private var backgroundQA: Bool {
        let id = Bundle.main.bundleIdentifier ?? ""
        return (id == "com.kyen.knarr.qa" || id.hasPrefix("com.kyen.knarr.qa."))
            && ProcessInfo.processInfo.environment["KNARR_QA_BACKGROUND"] == "1"
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        if backgroundQA { NSApp.setActivationPolicy(.prohibited) }
        nativeNotifications?.installDelegate()
    }
    func connectNotifications(store: LiveKnarrStore, dataDirectory: URL) {
        guard notificationService == nil, let nativeNotifications else { return }
        do {
            let service = try DesktopNotificationService(client: nativeNotifications,
                ledgerURL: dataDirectory.appendingPathComponent("desktop-notification-receipts.json"))
            service.connect(to: store) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            notificationService = service
            nativeNotifications.onOpen = { [weak service] id in Task { await service?.open(id) } }
            Task { await service.refreshAuthorization() }
        } catch {
            store.desktopNotificationStatus = .failed
            NSLog("Knarr native notification ledger failed: domain=%@ code=%ld", (error as NSError).domain, (error as NSError).code)
        }
    }
    /// Local MCP endpoint for external clients. It carries project/issue calls only; the socket
    /// lives in Knarr's private data folder and accepts only this user's processes.
    func startMCPServer(store: LiveKnarrStore, configuration: LiveKnarrConfiguration) {
        guard mcpHost == nil else { return }
        do {
            let host = try MCPHost(service: LazyAdminService { [weak store] in store?.adminService() },
                                   dataDirectory: configuration.dataDirectory,
                                   environment: configuration.environment)
            try host.start()
            mcpHost = host
        } catch {
            NSLog("Knarr MCP endpoint unavailable: %@", String(describing: error))
        }
    }

    private var installation: InstallRestart.Job?
    func installAndRestart(_ job: InstallRestart.Job) throws {
        try job.launch()
        installation = job
        AppTermination.request { NSApp.terminate(nil) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if backgroundQA {
            NSApp.setActivationPolicy(.prohibited)
            for window in NSApp.windows { window.setFrameOrigin(NSPoint(x: -20000, y: -20000)) }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        guard !HiveTransferLaunch.isRequested(CommandLine.arguments) else { return }
        // CloudKit tells the Mac about phone requests with silent pushes; only signed builds carry the entitlement.
        if Bundle.main.bundleIdentifier != "com.kyen.knarr.qa", CloudMirror.isEntitled { NSApp.registerForRemoteNotifications() }
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await mirror?.pullRequests() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await mirror?.pullRequests() }
        store?.setAppActive(true)
        store?.refreshResultApplications()
        store?.checkAutoInstall()
        Task { await notificationService?.refreshAuthorization() }
    }
    func applicationDidResignActive(_ notification: Notification) {
        store?.setAppActive(false)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        // Quitting stops running Hird work; say so first.
        let working = store.issues.filter { $0.hirds.contains { if case .working = $0.status { true } else if case .waitingOnHuman = $0.status { true } else { false } } }.count
        if termination == nil, working > 0 {
            let alert = NSAlert()
            alert.messageText = "이슈 \(working)개가 아직 진행 중이에요"
            alert.informativeText = "끄면 Hird 실행이 멈춰요. 지금까지 한 변경은 남아 있고, 다시 열면 멈춘 이슈에서 \"다시 시작\"으로 이어갈 수 있어요."
            alert.addButton(withTitle: "그래도 끄기")
            alert.addButton(withTitle: "취소")
            alert.alertStyle = .warning
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        mcpHost?.stop()
        mcpHost = nil
        if termination == nil {
            termination = Task {
                let exit = await store.shutdown()
                await mirror?.goOffline()
                if exit.remainingProcessIDs.isEmpty, let installation {
                    do { try installation.markNormalShutdown() }
                    catch { sender.reply(toApplicationShouldTerminate: false); termination = nil; return }
                }
                sender.reply(toApplicationShouldTerminate: exit.remainingProcessIDs.isEmpty)
                termination = nil
            }
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
