import KnarrSync
import SwiftUI
import UIKit
import UserNotifications

@main
struct KnarrMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(store: delegate.store)
                .tint(Palette.accent)
                .preferredColorScheme(nil)
                .task {
                    #if DEBUG
                    if delegate.store.isSample, ProcessInfo.processInfo.arguments.contains("-landscape") {
                        try? await Task.sleep(for: .seconds(1))
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft)) { error in
                                if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                                    try? String(describing: error).write(to: folder.appendingPathComponent("orientation-error.txt"), atomically: true, encoding: .utf8)
                                }
                            }
                        }
                    }
                    #endif
                }
        }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await delegate.store.becameActive() } }
        }
    }
}

@MainActor final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let store: PhoneStore = {
        var sample = ProcessInfo.processInfo.arguments.contains("-sample")
        #if DEBUG && targetEnvironment(simulator)
        if sample { UserDefaults.standard.set(true, forKey: "knarr.activity.sampleFixture") }
        sample = sample || UserDefaults.standard.bool(forKey: "knarr.activity.sampleFixture")
        #endif
        return PhoneStore(sample: sample)
    }()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        store.startActivityObservation()
        UNUserNotificationCenter.current().delegate = self
        guard !store.isSample else {
            // Screenshot aids for sample launches: `-open <issue id>` or `-chat`.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-open"), i + 1 < args.count { store.openIssue = args[i + 1] }
            // Screenshot aid: `-thread <id>` selects a conversation on iPad and opens it on iPhone.
            if let i = args.firstIndex(of: "-thread"), i + 1 < args.count { store.sampleThread = args[i + 1] }
            if args.contains("-settings") { store.sampleSettings = true }
            #if DEBUG
            if let i = args.firstIndex(of: "-screen"), i + 1 < args.count { store.sampleScreen = args[i + 1] }
            #endif
            store.startOnChat = args.contains("-chat")
            if let i = args.firstIndex(of: "-jump"), i + 1 < args.count { store.sampleJump = args[i + 1] }
            if let i = args.firstIndex(of: "-query"), i + 1 < args.count { store.sampleQuery = args[i + 1] }
            store.sampleConfirm = args.contains("-confirm")
            if args.contains("-applied") {
                store.send(.action(issue: "s1", action: .stop))
                Task { @MainActor [store] in try? await Task.sleep(for: .seconds(3)); store.sampleApplyPending() }
            }
            if args.contains("-failed") { store.failedDraft = .init(text: "이거 다시 보내줘", project: nil, reason: "인터넷 연결이 오프라인 상태입니다.") }
            if args.contains("-pending") { store.send(.message(text: "Mac 꺼져 있을 때 보낸 메시지", project: nil)) }
            #if DEBUG
            if let index = args.firstIndex(of: "-activity"), index + 1 < args.count { store.applyActivityScenario(args[index + 1]) }
            #endif
            return true
        }
        application.registerForRemoteNotifications()
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await store.start()
        }
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await store.refresh()
        return .newData
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await store.refresh()
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let issue = Self.issueID(in: response.notification.request.content.userInfo)
        // Alerts about an Issue open it; the rest (Stallari's replies) open the conversation.
        await MainActor.run { if let issue { store.openIssue = issue } else { store.openChat = true } }
        await store.refresh()
    }

    /// The deployed subscription includes the legacy `thing` field under `ck.qry.af`.
    nonisolated static func issueID(in userInfo: [AnyHashable: Any]) -> String? {
        CloudWire.issueID(in: userInfo)
    }
}
