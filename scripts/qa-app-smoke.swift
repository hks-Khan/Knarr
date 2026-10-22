#!/usr/bin/swift
import AppKit
import Darwin

// Launch only the generated QA bundle, observe its actual native window, then reclaim that PID.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let app = root.appendingPathComponent("outputs/Knarr QA.app")
let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))!
guard info["CFBundleIdentifier"] as? String == "com.kyen.knarr.qa" else { fatalError("QA bundle ID mismatch") }
let process = Process()
process.executableURL = app.appendingPathComponent("Contents/MacOS/Knarr")
process.currentDirectoryURL = root
var environment = ProcessInfo.processInfo.environment
for (key, value) in info["LSEnvironment"] as? [String: String] ?? [:] { environment[key] = value }
process.environment = environment
try process.run()
let pid = process.processIdentifier
print("QA native app PID=\(pid)")
var observed = false
let deadline = Date().addingTimeInterval(10)
while process.isRunning && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
    for window in owned {
        if let bounds = window[kCGWindowBounds as String] as? [String: Any],
           let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
           width >= 720 && height >= 540 {
            print("QA native window observed PID=\(pid) size=\(width)x\(height)")
            observed = true
        }
    }
    if observed { break }
}
if process.isRunning { process.terminate() }
let cleanupDeadline = Date().addingTimeInterval(5)
while process.isRunning && Date() < cleanupDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
if process.isRunning {
    kill(pid, SIGKILL)
    let killDeadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < killDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}
let remaining = process.isRunning || kill(pid, 0) == 0
print("QA native app cleanup PID=\(pid) remaining=\(remaining ? 1 : 0)")
exit(observed && !remaining ? 0 : 1)
