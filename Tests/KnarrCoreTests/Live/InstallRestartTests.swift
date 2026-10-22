import Foundation
import Darwin
import Testing
@testable import KnarrCore

@Suite(.serialized) struct InstallRestartTests {
    @Test(arguments: [true, false]) func helperWaitsForNormalExitThenBacksUpInstallsAndRelaunches(ready: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = root.appendingPathComponent("job")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let candidate = root.appendingPathComponent("candidate.app"), target = root.appendingPathComponent("installed.app")
        let code = root.appendingPathComponent("main.c")
        let binary = root.appendingPathComponent("fake-app")
        try "int main(void) { return 0; }\n".write(to: code, atomically: true, encoding: .utf8)
        try await withTestChildProcess(.init(executable: URL(fileURLWithPath: "/usr/bin/cc"), workingDirectory: root, arguments: [code.path, "-o", binary.path])) { p in
            let status = try await p.waitForExit()
            #expect(status == 0)
        }
        for (app, label) in [(candidate, "new"), (target, "old")] {
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let plist: [String: String] = ["CFBundleIdentifier": "com.kyen.knarr", "CFBundleExecutable": "Knarr", "CFBundlePackageType": "APPL", "CFBundleVersion": label]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            try FileManager.default.copyItem(at: binary, to: app.appendingPathComponent("Contents/MacOS/Knarr"))
            try label.write(to: app.appendingPathComponent("Contents/Resources/version"), atomically: true, encoding: .utf8)
            try await withTestChildProcess(.init(executable: URL(fileURLWithPath: "/usr/bin/codesign"), workingDirectory: root, arguments: ["--force", "--sign", "-", app.path])) { p in
                let status = try await p.waitForExit()
                #expect(status == 0)
            }
        }
        let database = root.appendingPathComponent("knarr.db")
        let repository = try await SQLiteKnarrRepository.open(at: database)
        try await repository.saveProject(.init(id: "fixture", name: "backup survives", absolutePath: root.path))
        try await repository.close()
        let launch = root.appendingPathComponent("launch.sh"), launched = root.appendingPathComponent("launched")
        try "#!/bin/bash\nprintf '%s\\n' \"$@\" > \"\(launched.path)\"\n".write(to: launch, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launch.path)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/KnarrCore/Resources/install-restart.sh")
        try await withTestChildProcess(.init(executable: URL(fileURLWithPath: "/bin/sleep"), workingDirectory: root, arguments: ["0.5"])) { parent in
            try await withTestChildProcess(.init(executable: URL(fileURLWithPath: "/bin/bash"), workingDirectory: root,
                arguments: [script.path, String(parent.id), candidate.path, target.path, database.path, job.path, launch.path, "2"])) { helper in
                try await Task.sleep(for: .milliseconds(100))
                #expect(try String(contentsOf: target.appendingPathComponent("Contents/Resources/version"), encoding: .utf8) == "old")
                #expect(!FileManager.default.fileExists(atPath: job.appendingPathComponent("knarr.db.backup").path))
                if ready { try Data().write(to: job.appendingPathComponent("shutdown-ready")) }
                let parentStatus = try await parent.waitForExit()
                let helperStatus = try await helper.waitForExit()
                #expect(parentStatus == 0)
                #expect(helperStatus == (ready ? 0 : 1))
                if helperStatus != (ready ? 0 : 1) { print(try String(contentsOf: job.appendingPathComponent("install.log"), encoding: .utf8)) }
            }
        }
        #expect(try String(contentsOf: target.appendingPathComponent("Contents/Resources/version"), encoding: .utf8) == (ready ? "new" : "old"))
        #expect(FileManager.default.fileExists(atPath: launched.path) == ready)
        if ready {
            let backup = try await SQLiteKnarrRepository.open(at: job.appendingPathComponent("knarr.db.backup"))
            #expect(try await backup.snapshot().projects.first?.name == "backup survives")
            try await backup.close()
            #expect(try String(contentsOf: launched, encoding: .utf8) == "-n\n\(target.path)\n")
        }
    }
}
