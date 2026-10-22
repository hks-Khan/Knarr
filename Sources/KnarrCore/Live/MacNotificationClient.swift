#if os(macOS)
import AppKit
import UserNotifications
import OSLog

/// Never touches UNUserNotificationCenter outside an identified .app (its API can abort CLI/tests).
@MainActor public final class MacNotificationClient: NSObject, DesktopNotificationClient, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private var queued: [String] = []
    private let logger = Logger(subsystem: "com.kyen.knarr", category: "native-notifications")
    public var observed: ((String) -> Void)?
    public var onOpen: ((String) -> Void)? {
        didSet {
            guard let onOpen else { return }
            let clicks = queued; queued.removeAll()
            for id in clicks { onOpen(id) }
        }
    }
    public static func isUsable(bundleURL: URL, bundleIdentifier: String?) -> Bool {
        bundleURL.pathExtension == "app" && !(bundleIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public static func makeIfUsable(bundle: Bundle = .main) -> MacNotificationClient? {
        guard isUsable(bundleURL: bundle.bundleURL, bundleIdentifier: bundle.bundleIdentifier) else { return nil }
        return MacNotificationClient(center: .current())
    }
    private init(center: UNUserNotificationCenter) { self.center = center; super.init() }
    /// AppDelegate calls this before applicationDidFinishLaunching, including notification cold starts.
    public func installDelegate() { center.delegate = self; observed?("delegate-installed") }
    public func authorizationStatus() async -> DesktopNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    public func requestAuthorization() async throws -> Bool {
        observed?("authorization-request")
        let allowed = try await center.requestAuthorization(options: [.alert, .sound])
        observed?(allowed ? "authorization-granted" : "authorization-denied")
        return allowed
    }
    public func acceptedIdentifiers() async -> Set<String> {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }
        return Set(pending + delivered)
    }
    public func send(_ event: DesktopNotificationEvent) async throws {
        let content = UNMutableNotificationContent()
        content.title = event.title; content.body = event.body; content.sound = .default
        content.userInfo = ["knarr_event_id": event.id]
        try await center.add(.init(identifier: event.id, content: content, trigger: nil))
        observed?("native-add-accepted:\(event.id)")
    }
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier
        completionHandler([.banner, .list, .sound])
        Task { @MainActor [weak self] in self?.observed?("foreground-banner-list-sound:\(id)") }
    }
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["knarr_event_id"] as? String
        let requestID = response.notification.request.identifier
        let clicked = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        completionHandler()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard clicked, let id, id == requestID else {
                self.logger.error("Native notification callback rejected: unsupported action or invalid event identifier")
                self.observed?("native-click-invalid")
                return
            }
            self.observed?("native-click:\(id)")
            if let onOpen = self.onOpen { onOpen(id) }
            else if !self.queued.contains(id) { self.queued.append(id) }
        }
    }
}
#endif
