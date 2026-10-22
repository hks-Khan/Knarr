import SwiftUI
import KnarrCore

/// One reviewed proposal version. The parent keys this view by issue ID and version,
/// so a submitted decision stays disabled until a genuinely new proposal arrives.
struct ProposalReviewView: View {
    let issue: Issue
    let proposal: IssueProposal
    let surface: String
    var blockReason: String? = nil
    let perform: (IssueAction) -> Void
    @State private var note = ""
    @State private var submitted = false

    private var editable: Bool { issue.archivedAt == nil && issue.state == .awaitingApproval && issue.approval?.runID == nil && issue.proposalReviewNote == nil && !submitted }
    private var reviewNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: K.s2) {
            Text("제안 v\(proposal.version)")
                .font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
            MarkdownText(text: proposal.instruction, scale: .secondary)
                .lineLimit(4)
                .accessibilityIdentifier("proposal-instruction-\(surface)")
            if issue.state == .awaitingApproval {
                TextField("수정 요청 또는 거절 메모", text: $note)
                    .textFieldStyle(.roundedBorder).disabled(!editable)
                HStack(spacing: K.s2) {
                    KButton(title: "승인", style: .primary, enabled: editable && blockReason == nil) {
                        decide(.approveProposal(version: proposal.version))
                    }
                    KButton(title: "수정 요청", enabled: editable && !reviewNote.isEmpty) {
                        decide(.requestProposalChanges(version: proposal.version, note: reviewNote))
                    }
                    KButton(title: "거절", style: .destructive, enabled: editable) {
                        decide(.rejectProposal(version: proposal.version, note: reviewNote))
                    }
                    Spacer(minLength: 0)
                }
                if let blockReason {
                    Text(blockReason).font(K.caption).foregroundStyle(K.amber)
                } else if submitted || issue.proposalReviewNote != nil {
                    Text(submitted ? "검토를 전달했어요" : "수정 요청을 전달했어요 · 새 제안 대기")
                        .font(K.caption).foregroundStyle(K.faint)
                } else if editable && reviewNote.isEmpty {
                    Text("수정 요청은 메모를 입력하면 보낼 수 있어요")
                        .font(K.caption).foregroundStyle(K.faint)
                }
            }
            FoldSection(title: "작업 지시와 실행 설정") {
                KeyValueRows(mono: IssueDrawer.meta(of: proposal))
                MarkdownText(text: proposal.instruction, scale: .secondary)
                    .accessibilityIdentifier("proposal-instruction-folded-\(surface)")
            }
            if let saved = issue.proposalReviewNote, !saved.isEmpty, issue.state != .awaitingApproval {
                Text("검토 메모 · \(saved)").font(K.secondary).foregroundStyle(K.muted).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("proposal-review-\(surface)")
        .onAppear { if let saved = issue.proposalReviewNote { note = saved } }
        .onChange(of: issue.proposalReviewNote) { if let saved = issue.proposalReviewNote { note = saved } }
        .onChange(of: issue.approval) { if issue.approval?.runID == nil { submitted = false } }
        .onChange(of: blockReason) { if blockReason == nil && issue.approval?.runID == nil { submitted = false } }
    }

    private func decide(_ action: IssueAction) {
        guard editable else { return }
        submitted = true
        perform(action)
    }
}
