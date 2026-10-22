import AppKit
import ApplicationServices
import Foundation

let args = CommandLine.arguments
let pid = pid_t(args[1])!
let action = args[2]
guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier?.hasPrefix("com.kyen.knarr.qa.mcp.") == true else {
    fputs("Expected only the dedicated QA application\n", stderr); exit(2)
}
if action == "quit" {
    guard app.terminate() else { fputs("Normal app termination refused\n", stderr); exit(3) }
    let deadline = Date().addingTimeInterval(15)
    while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    guard app.isTerminated else { exit(4) }
    print("normal app termination confirmed")
    exit(0)
}
guard !app.isActive else { fputs("QA app took foreground focus\n", stderr); exit(5) }
let root = AXUIElementCreateApplication(pid)
func values() -> [String] {
    var visited = 0
    func walk(_ node: AXUIElement) -> [String] {
        visited += 1
        guard visited < 5000 else { return [] }
        var text: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success,
               let string = value as? String, !string.isEmpty { text.append(string) }
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
           let children = children as? [AXUIElement] { for child in children { text += walk(child) } }
        return text
    }
    return walk(root)
}
let deadline = Date().addingTimeInterval(10)
var labels: [String] = []
while Date() < deadline {
    labels = values()
    let present = labels.contains { $0.contains("MCP 화면 연결 확인") }
    let version = labels.contains { $0.contains(action == "create" ? "제안 v1" : "제안 v2") }
    if action == "close" ? (!present && labels.contains("메인") && labels.contains("Stallari에게 메시지")) : (present && version) { break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
let output = try JSONSerialization.data(withJSONObject: labels, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(output)
let present = labels.contains { $0.contains("MCP 화면 연결 확인") }
let valid = action == "close" ? (!present && labels.contains("메인") && labels.contains("Stallari에게 메시지"))
    : (present && labels.contains { $0.contains(action == "create" ? "제안 v1" : "제안 v2") })
if !valid { fputs("\nNative accessibility content did not prove the expected state\n", stderr); exit(1) }
