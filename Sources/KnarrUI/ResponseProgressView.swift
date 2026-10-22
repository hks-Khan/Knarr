import SwiftUI

/// The status belongs to the pending assistant reply inside the transcript.
/// After the person stops a reply it stays as "응답 중지됨" until the next response starts,
/// so a request stopped before any answer does not read as unanswered.
/// Thinking states: the line shimmers while a status holds and swaps through a small blur when it changes,
/// and comes and goes the same way inside the transcript's fixed slot (`slotHeight`).
struct ResponseProgressView: View {
    /// `KnarrStore.responseStatus` after the person stopped a reply; kept until the next response starts.
    static let stoppedStatus = "중지됨"
    /// Height the transcript keeps for this line whether or not it shows, so it never moves the messages above.
    static let slotHeight: CGFloat = 28
    let isResponding: Bool
    var status = "응답 준비 중"
    /// Sends the stopped request again; nil when there is nothing to resend.
    var resend: (() -> Void)?

    private var stopped: Bool { !isResponding && status == Self.stoppedStatus }

    var body: some View {
        ZStack(alignment: .leading) {
            if isResponding {
                HStack(spacing: K.s2) {
                    ZStack(alignment: .leading) {
                        ShimmerText(text: status)
                            .id(status)
                            .transition(.swap(distance: Motion.distanceBase))
                    }
                    .animation(Motion.textSwap, value: status)
                    Spacer()
                }
                .padding(.vertical, K.s1)
                .frame(minHeight: Self.slotHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status)
                .accessibilityIdentifier("stallari-response-progress")
                .transition(.swap(distance: Motion.distanceBase))
            } else if stopped {
                HStack(spacing: K.s2) {
                    Image(systemName: "stop.circle").font(K.secondary).foregroundStyle(K.muted).accessibilityHidden(true)
                    Text("응답 중지됨")
                        .font(K.secondary.weight(.medium))
                        .foregroundStyle(K.muted)
                    if let resend {
                        Button("다시 보내기", action: resend)
                            .buttonStyle(.plain).font(K.secondary).foregroundStyle(K.accent)
                            .help("중지한 메시지를 같은 내용으로 다시 보내요")
                    }
                    Spacer()
                }
                .padding(.vertical, K.s1)
                .frame(minHeight: Self.slotHeight)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("stallari-response-stopped")
                .transition(.swap(distance: Motion.distanceBase))
            }
        }
        .animation(Motion.textSwap, value: isResponding)
        .animation(Motion.textSwap, value: stopped)
    }
}
