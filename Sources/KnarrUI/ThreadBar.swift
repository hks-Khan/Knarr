import SwiftUI
import KnarrCore

/// Browser-style tabs select conversations; closing one never deletes its session or history.
/// A tab whose thread is working (a Stallari answer anywhere, a Hird on its issue, or a pending
/// question) keeps its status dot breathing, including tabs that are not selected.
struct ThreadBar: View {
    let store: any KnarrStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: K.s4) {
                ForEach(store.conversationTabs) { thread in
                    let selected = store.selectedThreadID == thread.id
                    let working = store.isThreadWorking(thread.id)
                    let unread = store.unreadAnswerCount(forThread: thread.id)
                    let issue = thread.issueID.flatMap(store.issue)
                    let tint: ActivityDot.Tint = issue.map(waitsForPerson) == true ? .amber : .accent
                    HStack(spacing: K.s1) {
                        Button { store.selectThread(thread.id) } label: {
                            HStack(spacing: K.s2) {
                                if let issue {
                                    ZStack {
                                        Circle().fill(dotColor(issue)).frame(width: K.dot, height: K.dot)
                                            .opacity(working ? 0 : 1)
                                        if working {
                                            ActivityDot(tint: tint, reduceMotion: reduceMotion)
                                        }
                                    }
                                    .frame(width: K.dot, height: K.dot)
                                }
                                Text(thread.name).lineLimit(1).truncationMode(.tail)
                                    .frame(maxWidth: K.tabTitleWidth, alignment: .leading)
                                    // Main and project tabs have no dot slot; the working mark
                                    // sits in the tab gap so starting or stopping work never
                                    // moves the title or changes the tab width.
                                    .overlay(alignment: .leading) {
                                        if thread.issueID == nil, working {
                                            ActivityDot(tint: tint, reduceMotion: reduceMotion)
                                                .offset(x: -K.s3)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                // The slot keeps its width when the count is zero, so an answer
                                // arriving or being read never shifts the title or close button.
                                UnreadBadge(count: unread)
                            }
                            .font(K.secondary.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? K.ink : K.muted)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(thread.name)
                        .accessibilityIdentifier("thread-" + thread.id)
                        .accessibilityLabel(label(thread, working: working, unread: unread))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        if thread.issueID != nil {
                            Button { store.closeConversationTab(thread.id) } label: {
                                Image(systemName: "xmark").font(K.caption).foregroundStyle(K.faint)
                                    .frame(width: K.controlHeight, height: K.controlHeight)
                            }
                            .buttonStyle(.plain).help("탭 닫기")
                            .accessibilityLabel(thread.name + " 탭 닫기")
                            .accessibilityIdentifier("close-thread-" + thread.id)
                        }
                    }
                    .padding(.vertical, K.s1)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(selected ? K.ink : .clear).frame(height: K.tabUnderline)
                    }
                }
            }
            .padding(.horizontal, K.s5)
        }
        .scrollIndicators(.hidden)
        .background(K.surface)
        .overlay(alignment: .bottom) { Divider().overlay(K.line) }
    }

    /// A question waiting on the person takes priority over any running work.
    private func waitsForPerson(_ issue: Issue) -> Bool {
        issue.state == .needsInput || !store.pendingQuestions(for: issue.id).isEmpty
    }

    private func dotColor(_ issue: Issue) -> Color {
        if waitsForPerson(issue) { return K.amber }
        return issue.state == .running ? K.accent : K.faint
    }

    /// The visible text caps at 99+, while assistive technology always hears the exact number.
    private func label(_ thread: ConversationThread, working: Bool, unread: Int) -> String {
        var parts = [thread.name]
        if working { parts.append("작업 중") }
        if unread > 0 { parts.append("읽지 않은 답변 \(unread)개") }
        return parts.joined(separator: ", ")
    }
}

/// The tab's unread answers: a quiet count on the sunken surface, never a filled accent pill.
/// Zero draws nothing but keeps the slot's width, and the slot's width never depends on the
/// number, so the title, close button and neighbouring tabs never move when a count appears.
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        ZStack {
            if count > 0 {
                Text(UnreadAnswers.badgeText(count))
                    .font(K.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(K.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, K.s1)
                    .frame(minHeight: K.badgeHeight)
                    .background(K.sunken, in: RoundedRectangle(cornerRadius: K.rSmall))
                    .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.line))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: K.tabBadgeWidth, height: K.badgeHeight)
    }
}

/// The tab's working mark: a faint halo around the status dot. Core Animation runs the loop in the
/// render server, so neither the tab bar nor the transcript is redrawn per frame. Reduce Motion
/// keeps a still active dot; the view disappears as soon as the thread stops working.
struct ActivityDot: View {
    enum Tint { case accent, amber }
    let tint: Tint
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            Circle().fill(color).frame(width: K.dot, height: K.dot)
        } else {
            PulseLayer(kind: .ring, tint: tint == .amber ? .amber : .accent)
                .frame(width: K.dot, height: K.dot)
        }
    }

    private var color: Color { tint == .amber ? K.amber : K.accent }
}
