import Foundation
import Darwin
import Testing
@testable import KnarrCore

/// Test fixtures use the existing waitpid reaper, never Foundation's thread-local CFRunLoop wait.
final class TestChildProcess: @unchecked Sendable {
    private let process: OwnedOMPProcess
    private let lock = NSLock()
    private var exit: (Int32, [Int32])?
    var id: Int32 { process.id }
    var isRunning: Bool { terminal() == nil }

    init(_ configuration: OMPLaunchConfiguration) throws {
        process = try OwnedOMPProcess(configuration)
        let output = process.output
        Task { [self] in
            for await event in output {
                if case .exit(let status, let remaining) = event { record(status, remaining) }
            }
        }
    }
    private func record(_ status: Int32, _ remaining: [Int32]) {
        lock.lock(); defer { lock.unlock() }
        exit = (status, remaining)
    }
    private func terminal() -> (Int32, [Int32])? {
        lock.lock(); defer { lock.unlock() }
        return exit
    }
    func closeInput() { process.closeInput() }
    func signal(_ signal: Int32) { process.signalOwnedGroup(signal) }
    func waitForExit(timeout: Duration = .seconds(5)) async throws -> Int32 {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let (status, remaining) = terminal() {
                try #require(remaining.isEmpty, "Owned fixture PID=\(id) remaining=\(remaining)")
                #expect(kill(id, 0) == -1)
                print("Owned fixture PID=\(id) exit=\(status) remaining=0")
                return status
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        signal(SIGKILL)
        throw OMPRPCError.timedOut
    }
    /// Cleanup is bounded even when the test task was cancelled.
    func cleanup() async throws {
        closeInput(); signal(SIGKILL)
        let deadline = ContinuousClock.now + .seconds(5)
        while terminal() == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let result = try #require(terminal(), "Owned fixture PID=\(id) cleanup timed out")
        try #require(result.1.isEmpty)
        #expect(kill(id, 0) == -1)
    }
}

func withTestChildProcess(_ configuration: OMPLaunchConfiguration,
                          operation: (TestChildProcess) async throws -> Void) async throws {
    let process = try TestChildProcess(configuration)
    print("Owned fixture start PID=\(process.id)")
    do {
        try await operation(process)
        try await process.cleanup()
    } catch {
        try await process.cleanup()
        throw error
    }
}
