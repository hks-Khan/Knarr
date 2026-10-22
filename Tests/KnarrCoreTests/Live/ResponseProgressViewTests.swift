import AppKit
import SwiftUI
import Testing
@testable import KnarrUI

@MainActor struct ResponseProgressViewTests {
    @Test func indicatorOccupiesVisibleSpaceOnlyWhileResponding() throws {
        // Exercise SwiftUI layout, not a duplicated predicate or a source-text assertion.
        let visible = NSHostingView(rootView: ResponseProgressView(isResponding: true))
        let hidden = NSHostingView(rootView: ResponseProgressView(isResponding: false))
        #expect(visible.fittingSize.height >= 20)
        #expect(visible.fittingSize.width > 0)
        #expect(hidden.fittingSize.height == 0)
        visible.rootView = ResponseProgressView(isResponding: false)
        #expect(visible.fittingSize.height == 0)
        visible.rootView = ResponseProgressView(isResponding: true)
        #expect(visible.fittingSize.height >= 20)
    }

    @Test func stoppedReplyStaysVisibleUntilTheNextResponse() throws {
        // Stopping before any reply arrives must still leave a mark in the transcript.
        let view = NSHostingView(rootView: ResponseProgressView(isResponding: false, status: ResponseProgressView.stoppedStatus))
        #expect(view.fittingSize.height >= 20)
        view.rootView = ResponseProgressView(isResponding: true, status: "응답 준비 중")
        #expect(view.fittingSize.height >= 20)
        view.rootView = ResponseProgressView(isResponding: false, status: "답변 작성 중")
        #expect(view.fittingSize.height == 0)
    }
}
