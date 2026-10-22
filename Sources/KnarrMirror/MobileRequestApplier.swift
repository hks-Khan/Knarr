import Foundation
import KnarrCore
import KnarrSync

/// Carries out what the person asked for on the phone, through the same store calls the Mac screens use.
public enum MobileRequestApplier {
    /// Why a request was refused before it could touch the Mac. The reason reaches the phone as an alert.
    public struct Rejected: Error, Equatable { public let reason: String; public init(_ reason: String) { self.reason = reason } }

    /// Checks the phone's pictures before anything is written: count, declared size, real size, type.
    /// Nothing is written for a rejected request, and a valid one writes the same file names again.
    public static func saveAttachments(_ attachments: [MobileAttachment], in directory: URL,
                                       request: String) throws -> [URL] {
        guard attachments.count <= MobileLimits.attachmentCount else {
            throw Rejected("사진은 한 번에 \(MobileLimits.attachmentCount)장까지 보낼 수 있어요")
        }
        guard !attachments.isEmpty else { return [] }
        var urls: [URL] = []
        for attachment in attachments {
            guard let data = attachment.data else { throw Rejected("사진을 받지 못했어요") }
            guard data.count <= MobileLimits.attachmentBytes else { throw Rejected("사진 한 장은 8MB까지 보낼 수 있어요") }
            guard data.count == attachment.byteCount else { throw Rejected("사진 크기가 전송 중에 달라졌어요") }
            guard ["image/jpeg", "image/png", "image/heic", "image/webp"].contains(attachment.type.lowercased()) else {
                throw Rejected("사진 파일만 보낼 수 있어요")
            }
        }
        for (index, attachment) in attachments.enumerated() {
            guard let data = attachment.data else { throw Rejected("사진을 받지 못했어요") }
            let name = request.replacingOccurrences(of: "/", with: "-") + "-\(index)." + attachment.fileExtension
            let url = directory.appendingPathComponent(name)
            if (try? Data(contentsOf: url)) != data {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            urls.append(url)
        }
        return urls
    }

    @MainActor
    public static func apply(_ kind: MobileRequest.Kind, to store: some KnarrStore,
                             attachments directory: URL? = nil, request: String = UUID().uuidString) async throws {
        switch kind {
        case .message(let text, let project):
            try await store.submit(.init(text: text, project: project))
        case .threadMessage(let text, let thread, let project, let attachments):
            let files = try saveAttachments(attachments ?? [], in: directory ?? Self.defaultAttachmentDirectory,
                                            request: request)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else {
                throw Rejected("보낼 내용이 없어요")
            }
            try await store.sendToThread(thread, text: text, project: project, attachments: files)
        case .loadOlder:
            // Answered by the mirror from its own history page; nothing to apply to the store.
            break
        case .answer(let question, let options, let text):
            store.answer(Question.ID(question), with: QuestionAnswer(selectedOptions: options, text: text?.isEmpty == true ? nil : text))
        case .cancelQuestion(let question):
            store.cancel(Question.ID(question))
        case .action(let issue, let action):
            store.perform(issueAction(action), on: Issue.ID(issue))
        case .approveProposal(let issue, let version):
            try validateProposal(issue: store.issue(Issue.ID(issue)), version: version)
            try await store.reviewProposal(.approveProposal(version: version), on: Issue.ID(issue), source: "phone")
        case .requestProposalChanges(let issue, let version, let note):
            try validateProposal(issue: store.issue(Issue.ID(issue)), version: version)
            guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw rejection("수정할 내용을 메모로 적어 주세요")
            }
            try await store.reviewProposal(.requestProposalChanges(version: version, note: note), on: Issue.ID(issue), source: "phone")
        case .rejectProposal(let issue, let version, let note):
            try validateProposal(issue: store.issue(Issue.ID(issue)), version: version)
            try await store.reviewProposal(.rejectProposal(version: version, note: note), on: Issue.ID(issue), source: "phone")
        case .steer(let issue, let text):
            store.steer(text, issue: Issue.ID(issue))
        }
    }

    public static func validateProposal(issue: Issue?, version: Int) throws {
        guard let issue, issue.archivedAt == nil else { throw rejection("이슈가 없거나 보관됐어요") }
        guard issue.proposal?.version == version else { throw rejection("제안 버전이 바뀌었어요. 최신 제안을 다시 확인해 주세요") }
        guard issue.state == .awaitingApproval, issue.approval == nil, issue.proposalReviewNote == nil else {
            throw rejection("이미 처리한 제안이에요. 최신 상태를 확인해 주세요")
        }
    }

    private static func rejection(_ reason: String) -> NSError {
        NSError(domain: "Knarr.PhoneProposal", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    /// Where received pictures are kept: the same application-support folder Knarr already uses.
    public static var defaultAttachmentDirectory: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Knarr/attachments/phone", isDirectory: true)
    }

    public static func issueAction(_ action: MobileAction) -> IssueAction {
        switch action {
        case .confirmResult: .confirmResult
        case .requestChanges: .requestChanges(note: "")
        case .resolvedInput: .resolvedInput
        case .stop: .stop
        case .resume: .resume
        }
    }
}
