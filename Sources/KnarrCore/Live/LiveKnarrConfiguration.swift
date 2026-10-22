import Foundation
import CryptoKit

public struct LiveKnarrConfiguration: Sendable {
    /// Projects to make sure are registered at start (a development path); the rest live in the database.
    public let projects: [StoredProject]
    public let dataDirectory: URL
    public let executable: URL
    public let environment: [String: String]
    /// Jitdeck's database, read once when Knarr has no projects yet. nil skips the import.
    public let jitdeckDatabase: URL?
    public var responseRulesURL: URL {
        get throws {
            if let path = environment["KNARR_RESPONSE_RULES_PATH"] {
                guard path.hasPrefix("/") else { throw ResponseRulesError.invalidPath }
                return URL(fileURLWithPath: path)
            }
            return dataDirectory.appendingPathComponent("response-rules.md")
        }
    }
    public init(projects: [StoredProject], dataDirectory: URL, executable: URL,
                environment: [String: String] = ProcessInfo.processInfo.environment, jitdeckDatabase: URL?) {
        self.projects = projects; self.dataDirectory = dataDirectory; self.executable = executable
        self.environment = environment; self.jitdeckDatabase = jitdeckDatabase
    }

    /// The installed app and development runs alike. `KNARR_PROJECT_PATH` or a path argument adds one project.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment,
                                arguments: [String] = CommandLine.arguments, loginPath: String? = ShellPath.login) -> Self {
        let path = environment["KNARR_PROJECT_PATH"] ?? arguments.dropFirst().first(where: { $0.hasPrefix("/") })
        let projects = path.flatMap { try? StoredProject.at(path: $0) }.map { [$0] } ?? []
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let data = environment["KNARR_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? support.appendingPathComponent("Knarr", isDirectory: true)
        let executable = environment["KNARR_OMP_EXECUTABLE"].map { URL(fileURLWithPath: $0) } ??
            Bundle.main.url(forResource: "omp", withExtension: nil) ??
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".runtime/omp/" + OMPInstallation.version + "/omp")
        let jitdeck = environment["KNARR_SKIP_JITDECK_IMPORT"] == nil
            ? support.appendingPathComponent("JitdeckV2/jitdeck-v2.sqlite") : nil
        var env = environment
        // The desktop app uses OMP's saved login. A launcher/terminal's Claude
        // proxy variables must not reroute that login or replace its credentials.
        for key in ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"] {
            env.removeValue(forKey: key)
        }
        env["PATH"] = ShellPath.merged(current: environment["PATH"], login: loginPath, home: environment["HOME"])
        return .init(projects: projects, dataDirectory: data, executable: executable, environment: env, jitdeckDatabase: jitdeck)
    }
    static func selectedModel(state: OMPJSON, available: OMPJSON) throws -> String {
        guard let model = state["data"]?["model"], let provider = model["provider"]?.string,
              let id = model["id"]?.string, !id.isEmpty,
              !provider.isEmpty,
              available["data"]?["models"]?.array?.contains(where: { $0["provider"]?.string == provider && $0["id"]?.string == id }) == true else {
            throw LiveKnarrError.noSupportedSelectedModel
        }
        return provider + "/" + id
    }
}
public enum LiveKnarrError: Error, LocalizedError, Sendable {
    case missingProject, noSupportedSelectedModel
    case installUnavailable, installBusy
    public var errorDescription: String? {
        switch self {
        case .missingProject: "프로젝트 폴더를 찾지 못했어요. 폴더가 있는지 확인해 주세요"
        case .noSupportedSelectedModel: "OMP에서 선택한 모델을 사용할 수 없어요. OMP의 실제 사용 가능 모델 목록과 연결 상태를 확인해 주세요"
        case .installUnavailable: "후보 앱·현재 설치 앱·DB 경로를 확인하지 못했어요. 앱 번들에서 다시 시도해 주세요"
        case .installBusy: "진행 중인 Hird가 있어 설치하지 않았어요. 모든 실행이 끝난 뒤 다시 시도해 주세요"
        }
    }
}

/// An app opened from Finder gets launchd's bare PATH, so Hird could not find Homebrew or user tools.
public enum ShellPath {
    /// The user's login-shell PATH, read once per process. nil when the shell does not answer quickly.
    public static let login: String? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "print -r -- $PATH"]
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe(); process.standardInput = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + 3) == .timedOut { process.terminate(); return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && text.contains("/") ? text : nil
    }()

    /// Login PATH first, then whatever the process already had; without a login PATH, add the usual tool folders.
    public static func merged(current: String?, login: String?, home: String?) -> String {
        var parts: [String] = []
        func add(_ path: String?) { for p in (path ?? "").split(separator: ":").map(String.init) where !p.isEmpty && !parts.contains(p) { parts.append(p) } }
        add(login); add(current)
        if login == nil { add(["/opt/homebrew/bin", "/usr/local/bin", home.map { $0 + "/.local/bin" }].compactMap { $0 }.joined(separator: ":")) }
        return parts.joined(separator: ":")
    }
}

extension StoredProject {
    /// The reserved row Stallari's own conversation is filed under. Never a real project.
    public static let hubID = "knarr-hub"

    /// A project for a folder. The ID comes from the resolved path, so the same folder is always the same project.
    public static func at(path: String) throws -> StoredProject {
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { throw LiveKnarrError.missingProject }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let digest = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(id: "project-" + digest, name: url.lastPathComponent, absolutePath: url.path)
    }
}
