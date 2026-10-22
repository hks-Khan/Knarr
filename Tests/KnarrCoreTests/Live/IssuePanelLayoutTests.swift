import Testing
import KnarrCore
@testable import KnarrUI

/// The issue detail's width policy: 380pt floor, 60% ceiling, 480pt conversation floor,
/// and a saved preference that is clamped for display without being overwritten.
struct IssuePanelLayoutTests {
    @Test func splitNeedsRoomForBothColumnsAndTheSplitter() {
        let exact = K.issuePanelMinimumWidth + K.issueConversationMinimumWidth + K.issueResizeHitWidth
        #expect(IssuePanelLayout.isSplit(available: exact))
        #expect(!IssuePanelLayout.isSplit(available: exact - 1))
        #expect(IssuePanelLayout.isSplit(available: 1400))
    }

    @Test func ceilingIsSixtyPercentOfTheWindowUnlessTheConversationWouldShrink() {
        // 0.6 × 2076 = 1245.6, but 2012 − 24 − 480 = 1508, so the window fraction wins.
        #expect(abs(IssuePanelLayout.maximumWidth(available: 2012, windowWidth: 2076) - 2076 * K.issuePanelMaximumFraction) < 0.001)
        // 0.6 × 1064 = 638.4, but the conversation floor leaves only 516.
        #expect(IssuePanelLayout.maximumWidth(available: 1020, windowWidth: 1084) == 516)
        // Never below the floor, even at the split breakpoint.
        #expect(IssuePanelLayout.maximumWidth(available: 884, windowWidth: 948) == K.issuePanelMinimumWidth)
    }

    @Test func widthClampsTheSavedPreferenceInBothDirections() {
        #expect(IssuePanelLayout.width(available: 1400, windowWidth: 1464, preferred: 0) == K.issuePanelDefaultWidth)
        #expect(IssuePanelLayout.width(available: 1400, windowWidth: 1464, preferred: 10) == K.issuePanelMinimumWidth)
        #expect(IssuePanelLayout.width(available: 1400, windowWidth: 1464, preferred: 5000) == 878.4)
        #expect(IssuePanelLayout.width(available: 1400, windowWidth: 1464, preferred: 620) == 620)
        #expect(IssuePanelLayout.width(available: 1400, windowWidth: 1464, preferred: .nan) == K.issuePanelDefaultWidth)
        #expect(IssuePanelLayout.isSplit(available: 1400))
    }
}
