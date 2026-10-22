import Foundation
import CryptoKit

/// Dispatch-local values. No cache, watcher, alternate OMP settings store, or execution layer.
struct HirdPolicyFiles {
    let directory: URL

    static func resource(_ name: String) throws -> Data {
        let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "hird")
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "hird")
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf: url)
    }

    func load() throws -> HirdPolicy {
        var warnings: [String] = []
        let decoder = JSONDecoder()
        func json(_ data: Data) throws -> OMPJSON { try decoder.decode(OMPJSON.self, from: data) }
        // Never follow a user file symlink into an authentication store or another config root.
        let directoryIsLink = (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if !directoryIsLink { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func read<Value>(_ name: String, decode: (Data, Data) throws -> Value) throws -> Value {
            let fallback = try Self.resource(name)
            let file = directory.appendingPathComponent(name)
            do {
                guard !directoryIsLink else { throw CocoaError(.fileReadNoPermission) }
                if !FileManager.default.fileExists(atPath: file.path) {
                    do { try fallback.write(to: file, options: [.withoutOverwriting]) }
                    catch let error as CocoaError where error.code == .fileWriteFileExists { /* Another dispatch created it. */ }
                }
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true else { throw CocoaError(.fileReadNoPermission) }
                let data = try Data(contentsOf: file)
                return try decode(data, fallback)
            } catch {
                // Instruction text is never replaced on failure: a broken file stops the run
                // instead of silently falling back to broader packaged guidance. The JSON
                // policy files keep their old behavior and are restored to the packaged default.
                if name == "instructions.md" { throw error }
                if !directoryIsLink { try? fallback.write(to: file, options: [.atomic]) }
                warnings.append("[hird_policy] \(name)을 읽거나 검증하지 못해 이 파일만 기본값으로 대체했어요.")
                return try decode(fallback, fallback)
            }
        }
        let overlay = try read("overlay.json") { data, fallback in
            let shape = try json(fallback), value = try data == fallback ? shape : json(data)
            guard Self.matches(value, shape: shape),
                  let compaction = value["compaction"],
                  let tokens = compaction["thresholdTokens"]?.integer, tokens > 0,
                  let percent = compaction["thresholdPercent"]?.integer, percent > 0, percent <= 100,
                  let recent = compaction["keepRecentTokens"]?.integer, recent >= 0 else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        let policy = try read("policy.json") { data, fallback in
            let shape = try json(fallback), value = try data == fallback ? shape : json(data)
            guard Self.matches(value, shape: shape),
                  let timeout = value["lspTimeoutSeconds"]?.integer, timeout > 0,
                  let tools = value["inspectTools"]?.array?.compactMap(\.string), tools.contains("bash"),
                  Set(tools).isSubset(of: Set(HirdInspectionPolicy.tools)),
                  let arguments = value["inspectArguments"]?.array?.compactMap(\.string),
                  Set(arguments).isSubset(of: Set(shape["inspectArguments"]!.array!.compactMap(\.string))) else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        let instructions = try read("instructions.md") { data, fallback in
            guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !text.contains("\0") else { throw CocoaError(.fileReadCorruptFile) }
            // Upgrade only an unchanged shipped policy; preserve custom policies byte-for-byte.
            let digest = SHA256.hash(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)).map { String(format: "%02x", $0) }.joined()
            let shipped = ["6eeb961b51c585cde027f1fb5f06f4bb4ad8ab4b470dab47e53218e4a1d1ffaf",
                           "579b420a14c95a65a1a4624179818edb06dd06b1fa377877119e212c8f53437b",
                           "ff840b2ec382e34dc55db7e49995d181b62c1c126b366e262b27196a3a43a33a"]
            if shipped.contains(digest) {
                try? fallback.write(to: directory.appendingPathComponent("instructions.md"), options: .atomic)
                return String(decoding: fallback, as: UTF8.self)
            }
            for mode in [HirdRunMode.change, .inspect] {
                let rendered = HirdPolicy.render(text, mode: mode)
                    .replacingOccurrences(of: "{{lspTimeoutSeconds}}", with: "")
                    .replacingOccurrences(of: "{{inspectCommands}}", with: "")
                guard !rendered.contains("{{"), !rendered.contains("}}") else { throw CocoaError(.fileReadCorruptFile) }
            }
            return text
        }
        let feedback = try read("verification-feedback.json") { data, fallback in
            let value = try json(data)
            guard Self.matches(value, shape: try json(fallback)),
                  let count = value["failureThreshold"]?.integer, count > 0,
                  ["invalidCommand", "repeatedFailure"].allSatisfy({
                      !(value[$0]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                  }) else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        let continuation = try read("continuation.json") { data, fallback in
            guard Self.matches(try json(data), shape: try json(fallback)) else { throw CocoaError(.fileReadCorruptFile) }
            let value = try decoder.decode(HirdContinuationPolicy.self, from: data)
            guard value.maximumAttempts > 0,
                  [value.interruptedPrompt, value.emptyResultPrompt].allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains("\0")
                  }) else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        // The user-owned hierarchy adds sticky rules and background; the mode-rendered role
        // policy above stays where it was. A broken tree fails a change run instead of
        // silently continuing without the user's rules.
        var instructionSet: InstructionSet?
        var instructionFailure: String?
        do {
            instructionSet = try InstructionSources.load(dataDirectory: directory.deletingLastPathComponent(),
                                                         role: .hird, projectID: nil)
        } catch { instructionFailure = error.localizedDescription }
        return try HirdPolicy(overlay: overlay, values: policy,
            instructions: instructions, userInstructions: instructionSet, instructionFailure: instructionFailure,
            warnings: warnings, continuation: continuation, verificationFeedback: feedback,
            extensionTemplate: String(decoding: Self.resource("extension.ts"), as: UTF8.self))
    }

    /// The bundled defaults define the supported key/type surface; unknown/missing keys
    /// replace only that file. Values remain editable without recompiling Swift.
    private static func matches(_ value: OMPJSON, shape: OMPJSON) -> Bool {
        switch (value, shape) {
        case let (.object(value), .object(shape)):
            return value.keys.count == shape.keys.count && shape.allSatisfy { key, item in value[key].map { matches($0, shape: item) } == true }
        case let (.array(value), .array(shape)):
            guard let item = shape.first else { return value.isEmpty }
            return value.allSatisfy { matches($0, shape: item) }
        case (.string, .string), (.bool, .bool): return true
        case let (.number(value), .number): return value.isFinite && value.rounded() == value
        default: return false
        }
    }
}

struct HirdContinuationPolicy: Codable, Sendable {
    let maximumAttempts: Int
    let interruptedPrompt: String
    let emptyResultPrompt: String
}

struct HirdPolicy {
    let overlay: OMPJSON
    let values: OMPJSON
    let instructions: String
    /// User-owned hierarchy: `AGENTS.md` background plus `RULES.md` carried on every run.
    let userInstructions: InstructionSet?
    let instructionFailure: String?
    let warnings: [String]
    let continuation: HirdContinuationPolicy
    let verificationFeedback: OMPJSON
    let extensionTemplate: String

    var inspectTools: [String] { values["inspectTools"]!.array!.compactMap(\.string) }

    var stageTool: OMPJSON {
        get throws { try JSONDecoder().decode(OMPJSON.self, from: HirdPolicyFiles.resource("stage-tool.json")) }
    }

    func overlayText(mode: HirdRunMode?) throws -> String {
        var result = overlay
        if mode != .inspect, case .object(var object) = result {
            // Work copies keep their own repo AGENTS.md/rules provider, but user-home
            // OMP config (AGENTS.md, skills, managed skills) never joins a Hird run.
            // Merge rather than replace so a user's own disabledProviders survive.
            var disabled = object["disabledProviders"]?.array?.compactMap(\.string) ?? []
            for provider in ["native", "omp-managed"] where !disabled.contains(provider) { disabled.append(provider) }
            object["disabledProviders"] = .array(disabled.map(OMPJSON.string))
            result = .object(object)
        }
        if mode == .inspect, case .object(var object) = result {
            object["disabledProviders"] = values["inspectDisabledProviders"]
            object["lsp"] = .object(["enabled": .bool(false)])
            object["shellPath"] = .string("/bin/bash")
            if case .object(var bash) = object["bash"], case .object(let security) = HirdInspectionPolicy.bashSecurity {
                bash.merge(security, uniquingKeysWith: { _, boundary in boundary })
                object["bash"] = .object(bash)
            } else {
                object["bash"] = HirdInspectionPolicy.bashSecurity
            }
            result = .object(object)
        }
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }

    var extensionSource: String {
        get throws {
            let settings = OMPJSON.object(["compaction": overlay["compaction"]!, "lspTimeoutSeconds": values["lspTimeoutSeconds"]!, "verificationFeedback": verificationFeedback])
            return "const KNARR_HIRD_POLICY = " + String(decoding: try JSONEncoder().encode(settings), as: UTF8.self) + ";\n" + extensionTemplate
        }
    }

    func inspectionArguments(extensionURL: URL) -> [String] {
        // Editable feature flags can further restrict discovery; security flags cannot be removed.
        let configured = values["inspectArguments"]!.array!.compactMap(\.string)
        let flags = configured + HirdInspectionPolicy.securityArguments.filter { !configured.contains($0) }
        return ["--tools", inspectTools.joined(separator: ",")] + flags + ["--trusted-extension", extensionURL.path]
    }

    func prompt(mode: HirdRunMode?, task: String) -> String {
        let rendered = Self.render(instructions, mode: mode ?? .change)
            .replacingOccurrences(of: "{{lspTimeoutSeconds}}", with: String(values["lspTimeoutSeconds"]!.integer!))
            .replacingOccurrences(of: "{{inspectCommands}}", with: HirdInspectionPolicy.commands.joined(separator: "; "))
        let instruction = mode == .inspect ? task : Self.executionTask(task)
        // Inspect runs stay on the fixed read-only policy; only change runs carry user rules.
        let owned = mode == .inspect ? "" : (userInstructions?.prompt.isEmpty == false
            ? "## User-owned instructions\n" + userInstructions!.prompt + "\n\n" : "")
        return HirdInspectionPolicy.safetyInstructions + "\n" + owned + rendered + "\nRun mode: \(mode?.rawValue ?? "change"). Task: \(instruction)"
    }

    func prompt(mode: HirdRunMode?, task: String, stages: [IssueStage]) throws -> String {
        let plan = String(decoding: try JSONEncoder().encode(stages), as: UTF8.self)
        let stageInstructions = String(decoding: try HirdPolicyFiles.resource("stage-instructions.md"), as: UTF8.self)
            .replacingOccurrences(of: "{{stagePlan}}", with: plan)
        return prompt(mode: mode, task: task) + "\n\n" + stageInstructions
    }

    /// This is an exact compatibility conversion for the former generated proposal template,
    /// never a keyword filter for arbitrary user restrictions. Approval is checked before dispatch.
    private static func executionTask(_ task: String) -> String {
        let legacy = "# 승인 범위\n현재 사용자 요청은 이 계획을 검토 가능한 제안으로 등록하는 데까지다. 구현은 이 Knarr 이슈에서 후속 사용자 요청/승인으로 이어간다. 현재 등록만으로 실행하지 않는다. 아래 내용은 향후 승인 시 수행할 change 작업 계획이다."
        guard task.hasPrefix(legacy + "\n\n") else { return task }
        return String(task.dropFirst(legacy.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let modeBlocks = ["change", "inspect"].map { name in
        (name, try! NSRegularExpression(pattern: "\\{\\{#" + name + "\\}\\}([\\s\\S]*?)\\{\\{/" + name + "\\}\\}"))
    }

    static func render(_ text: String, mode: HirdRunMode) -> String {
        var result = text
        for (name, regex) in modeBlocks {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: mode.rawValue == name ? "$1" : "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
