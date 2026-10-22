import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil))
struct HirdLSPRuntimeTests {
    @Test func sourceKitDiagnosticsDefinitionReferencesBoundedFallbackAndApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-lsp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Probe\", targets: [.executableTarget(name: \"Probe\")])\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("Sources/Probe/main.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "func answer() -> Int { \"42\" }\nprint(answer())\n".write(to: source, atomically: true, encoding: .utf8)
        let resolve = Process(), stdout = Pipe()
        resolve.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        resolve.arguments = ["--find", "sourcekit-lsp"]
        resolve.standardOutput = stdout
        resolve.standardError = FileHandle.nullDevice
        try resolve.run(); resolve.waitUntilExit()
        try #require(resolve.terminationStatus == 0)
        let sourcekit = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let swiftConfig = OMPJSON.object(["servers": .object(["sourcekit-lsp": .object(["command": .string(sourcekit)])])])
        try JSONEncoder().encode(swiftConfig).write(to: root.appendingPathComponent("lsp.json"))
        for (name, command, args) in [("missing", "/knarr-no-such-language-server", [String]()), ("silent", "/bin/sleep", ["30"])] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "func answer() -> Int { 42 }\n".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
            try "// swift-tools-version: 6.0\n".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            let config = OMPJSON.object(["servers": .object(["sourcekit-lsp": .object(["command": .string(command), "args": .array(args.map(OMPJSON.string)), "fileTypes": .array([.string(".swift")]), "rootMarkers": .array([.string("Package.swift")])])])])
            try JSONEncoder().encode(config).write(to: dir.appendingPathComponent("lsp.json"))
        }
        let policy = root.appendingPathComponent("probe.ts"), result = root.appendingPathComponent("result.json"), overlay = root.appendingPathComponent("hird.yml")
        let configuration = try HirdPolicyFiles(directory: root.appendingPathComponent("hird")).load()
        let native = try configuration.extensionSource.replacingOccurrences(of: "export default function(pi)", with: "function deadline(pi)")
        try (native + "\n" + Self.probe).write(to: policy, atomically: true, encoding: .utf8)
        try configuration.overlayText(mode: .change).write(to: overlay, atomically: true, encoding: .utf8)
        let rpc = OMPRPCSession()
        let env = ["HOME": root.appendingPathComponent("home").path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                   "PI_CODING_AGENT_DIR": root.appendingPathComponent("agent").path, "KNARR_LSP_RESULT": result.path]
        do {
            try await rpc.start(.init(installation: try OMPInstallation(executable: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"]))), workingDirectory: root,
                arguments: ["--mode", "rpc-ui", "--no-ui", "--no-title", "--no-pty", "--no-extensions", "--trusted-extension", policy.path, "--config", overlay.path, "--model", "anthropic/claude-sonnet-4-5", "--no-session"], environment: env))
            _ = try await rpc.request("prompt", fields: ["message": .string("/knarr-native-lsp")])
            for _ in 0..<3000 { if FileManager.default.fileExists(atPath: result.path) { break }; try await Task.sleep(for: .milliseconds(10)) }
            let value = try JSONDecoder().decode(OMPJSON.self, from: Data(contentsOf: result))
            #expect(value["diagnostics"]?["content"]?.array?.contains { $0["text"]?.string?.contains("Cannot convert return expression") == true } == true)
            #expect(value["definition"]?["details"]?["success"]?.bool == true)
            #expect(value["definition"]?["details"]?["request"]?["timeout"]?.integer == 10)
            #expect(value["references"]?["content"]?.array?.contains { $0["text"]?.string?.contains("main.swift:2") == true } == true)
            #expect(value["missing"]?["failed"]?.bool == true)
            #expect(value["silent"]?["failed"]?.bool == true)
            #expect((value["silent"]?["milliseconds"]?.integer ?? Int.max) < 10_000) // Native initialize has its own 5 s bound.
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("fallback-completed").path))
            #expect(value["approvalBlocked"]?.bool == true)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("approval-bypassed").path))
            let exit = await rpc.shutdown()
            #expect(exit.remainingProcessIDs == [])
            let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("outputs/hird-development/lsp-sdk.json")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: output)
            print("OMP SDK definition=\(value["definition"]?["details"]?["success"]?.bool ?? false) requested_timeout=\(value["definition"]?["details"]?["request"]?["timeout"]?.integer ?? -1) silent_ms=\(value["silent"]?["milliseconds"]?.integer ?? -1) approvalBlocked=\(value["approvalBlocked"]?.bool ?? false) owned_remaining=\(exit.remainingProcessIDs.count) provider_calls=0")
        } catch { _ = await rpc.shutdown(cancel: true); throw error }
    }
    static let probe = """
    export default function(pi) {
      pi.registerCommand("knarr-native-lsp", { handler: async (_, ctx) => {
        const fs = await import("node:fs");
        const settings = pi.pi.Settings.isolated({ "lsp.shared": false, "tools.xdev": false, "lsp.diagnosticsOnWrite": false, "tools.approvalMode": "yolo" });
        const { session } = await pi.pi.createAgentSession({ cwd: ctx.cwd, model: ctx.model, settings, disableExtensionDiscovery: true, extensions: [deadline] });
        const context = { settings, hasUI: false, abort: () => {} };
        const lsp = session.agent.state.tools.find(tool => tool.name === "lsp");
        const results = {};
        try {
          results.diagnostics = await lsp.execute("diag", {action:"diagnostics", file:"Sources/Probe/main.swift", timeout:999}, undefined, undefined, context);
          results.definition = await lsp.execute("def", {action:"definition", file:"Sources/Probe/main.swift", line:2, symbol:"answer", timeout:999}, undefined, undefined, context);
          results.references = await lsp.execute("refs", {action:"references", file:"Sources/Probe/main.swift", line:1, symbol:"answer", timeout:999}, undefined, undefined, context);
          for (const name of ["missing", "silent"]) {
            const localSettings = pi.pi.Settings.isolated({ "lsp.shared": false });
            const tool = new pi.pi.LspTool({cwd: ctx.cwd + "/" + name, hasUI:false, settings:localSettings});
            const start = Date.now();
            try {
              const result = await tool.execute(name, {action:"definition", file:"main.swift", line:1, symbol:"answer", timeout:1});
              results[name] = { failed: result.details.success === false, milliseconds:Date.now()-start, content:result.content };
            } catch (_) { results[name] = { failed:true, milliseconds:Date.now()-start }; }
          }
          const bash = session.agent.state.tools.find(tool => tool.name === "bash");
          results.continued = await bash.execute("continued", {command:"/usr/bin/touch " + JSON.stringify(ctx.cwd + "/fallback-completed"), timeout:5}, undefined, undefined, context);
          const denied = pi.pi.Settings.isolated({ "tools.approval": { bash:"prompt" } });
          try { await bash.execute("approval", {command:"/usr/bin/touch " + JSON.stringify(ctx.cwd + "/approval-bypassed"), timeout:5}, undefined, undefined, {settings:denied, hasUI:false, abort:()=>{}}); results.approvalBlocked = false; }
          catch (error) { results.approvalBlocked = error.message.includes("requires approval but no interactive UI"); }
          fs.writeFileSync(process.env.KNARR_LSP_RESULT, JSON.stringify(results));
        } finally { await session.dispose(); }
      }});
    }
    """
}
