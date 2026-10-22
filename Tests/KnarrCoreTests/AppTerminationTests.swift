import XCTest
@testable import KnarrUI

@MainActor final class AppTerminationTests: XCTestCase {
    /// `NSApp.terminate` waits in a nested run loop for `.terminateLater` work on the MainActor.
    /// Requested from a MainActor task, that work must still run, or the app freezes while quitting.
    func testTerminationRequestedFromMainActorTaskLetsMainActorWorkRun() async {
        let waited = expectation(description: "terminate wait finished")
        var replied = false
        var repliedWhileWaiting = false
        Task { @MainActor in
            AppTermination.request {
                Task { @MainActor in replied = true }
                let deadline = Date().addingTimeInterval(2)
                while !replied, Date() < deadline {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                repliedWhileWaiting = replied
                waited.fulfill()
            }
        }
        await fulfillment(of: [waited], timeout: 10)
        XCTAssertTrue(repliedWhileWaiting)
    }
}
