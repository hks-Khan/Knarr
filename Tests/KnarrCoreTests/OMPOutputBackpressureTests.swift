import Foundation
import Darwin
import Testing
@testable import KnarrCore

@Suite(.serialized) struct OMPOutputBackpressureTests {
    @Test func pausedReceiverKeepsProducerBackpressuredUntilBytesAreConsumed() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        let script = """
        import sys,pathlib
        pathlib.Path('started').write_text('1')
        sys.stdout.buffer.write(b'x' * (8 * 1024 * 1024)); sys.stdout.flush()
        pathlib.Path('written').write_text('1')
        """
        try script.write(to: fixture.directory.appendingPathComponent("fixture.py"), atomically: true, encoding: .utf8)
        let process = try OwnedOMPProcess(fixture.configuration)
        let deadline = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { process.signalOwnedGroup(SIGTERM); process.signalOwnedGroup(SIGKILL) }
        }
        defer { deadline.cancel() }
        do {
            process.closeInput()
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("started").path) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(150))
            let wroteBeforeDemand = FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("written").path)
            print("raw-byte backpressure producerCompletedBeforeDemand=\(wroteBeforeDemand) payloadBytes=8388608")
            #expect(!wroteBeforeDemand)
            var bytes = 0, ended = false
            for await event in process.output {
                switch event {
                case .bytes(let chunk): bytes += chunk.count; #expect(chunk.count <= 65_536)
                case .exit(let code, let remaining): #expect(code == 0); #expect(remaining.isEmpty); ended = true
                case .failure: Issue.record("Unexpected pipe failure")
                }
            }
            #expect(bytes == 8 * 1024 * 1024)
            #expect(ended)
        } catch {
            process.closeInput(); process.signalOwnedGroup(SIGTERM); process.signalOwnedGroup(SIGKILL)
            for await event in process.output {
                if case .exit(_, let remaining) = event { #expect(remaining.isEmpty) }
            }
            throw error
        }
    }
}
