import Foundation

/// Starts app termination from the run loop instead of the caller's MainActor job.
/// `NSApp.terminate` waits in a nested run loop for `.terminateLater` shutdown work on the
/// MainActor; called inside a MainActor job, that work can never run and the app freezes.
public enum AppTermination {
    @MainActor public static func request(_ terminate: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { terminate() }
        }
    }
}
