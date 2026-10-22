import Foundation
import Testing
@testable import KnarrCore

/// Explicitly invoked only for the isolated native-app UI fixture. It opens no live database.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_PREPARATION_SEED"] == "1"))
struct PreparationFixtureSeedTests {
    @Test func seedIsolatedOriginalCandidates() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("outputs/archive-ui/fixture/data/knarr.db")
        #expect(FileManager.default.fileExists(atPath: path.path))
        let repository = try await SQLiteKnarrRepository.open(at: path)
        do {
            var project = try #require(try await repository.snapshot().projects.first { $0.name == "2026 개발자 취업 지원" })
            project.settings.workspaceStyle = .preparation
            try await repository.saveProject(project)
            let candidates = [
                ("krafton-2027-intern-apply", "크래프톤", "2027 채용연계형 인턴", "2026-10-23T11:59:00+09:00", "직군 검토 중", "지원 직군: Tech 또는 Game Design 검토 중\n\n준비 내용: 기존 초안과 지원 문항 대조, 직군별 제출 자료 정리"),
                ("krict-it-regular-2026", "한국화학연구원", "전산 정직원", "2026-11-06T17:00:00+09:00", "역량·근무 조건 확인", "전산 정직원 1명 · 대전 본원\n\n준비 내용: 요구 역량과 근무 조건을 확인하고 지원 자료 정리"),
                ("solideng-ai-planning-dev", "솔리드이엔지", "AI 기획·운영·개발", "2026-11-20T23:59:00+09:00", "RAG 경험 대조", "AI 기획·운영·개발\n\n준비 내용: RAG 프로젝트 경험을 공고의 요구 역량과 대조")
            ]
            for (source, organization, title, deadline, memo, posting) in candidates {
                let fields = PreparationItem.Fields(organization: organization, title: title, deadline: StallariSession.date(deadline),
                    priority: source == "krafton-2027-intern-apply", memo: memo, posting: posting,
                    documentPaths: ["PROJECT_STATUS.md", "README.md"])
                _ = try await repository.savePreparation(id: "prep-" + source, projectID: project.id, fields: fields, expectedRevision: 0, sourceIssueID: .init(source))
            }
            #expect(try await repository.snapshot().preparationItems.count == 3)
            #expect(try await repository.snapshot().issues.count == 3)
            #expect(try await repository.snapshot().runs.isEmpty)
            try await repository.close()
        } catch { try? await repository.close(); throw error }
    }
}
