import Foundation
import Observation

/// One timer at the next deadline; no idle database polling and no per-conversation fan-out.
@MainActor @Observable public final class WorkReportController {
    public private(set) var reports: [WorkReport] = []
    public private(set) var error: String?
    public private(set) var isBusy = false
    private var archive: WorkReportArchive?
    private var unsaved: WorkReportArchive?
    private let url: URL
    private let snapshot: @Sendable () async throws -> PersistenceSnapshot
    private let analyze: @Sendable (WorkReport, WorkReport?) async throws -> String
    private let model: @MainActor () -> String?
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var closed = false
    public init(url: URL, snapshot: @escaping @Sendable () async throws -> PersistenceSnapshot,
                analyze: @escaping @Sendable (WorkReport, WorkReport?) async throws -> String,
                model: @escaping @MainActor () -> String? = { nil }, now: @escaping @Sendable () -> Date = { .now }) {
        self.url = url; self.snapshot = snapshot; self.analyze = analyze; self.model = model; self.now = now
    }
    public func start() async {
        guard archive == nil, !closed else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let state = try WorkReportArchive.load(from: url, now: now(), calendar: .current)
            try save(state)
            wake()
        } catch { self.error = "보고 기록을 열지 못했어요. 기존 파일은 보존돼 있어요." }
    }
    private func save(_ value: WorkReportArchive) throws {
        do {
            try value.save(to: url)
            archive = value; reports = value.reports; unsaved = nil; error = nil
        } catch {
            unsaved = value; reports = value.reports
            self.error = "보고 기록을 저장하지 못했어요. 저장을 다시 시도해 주세요."
            throw error
        }
    }
    public func wake() {
        guard !closed, task == nil, archive != nil, unsaved == nil else { return }
        timer?.cancel(); timer = nil
        task = Task { [weak self] in
            guard let self else { return }
            self.isBusy = true
            await self.collectAndAnalyze()
            self.isBusy = false; self.task = nil
            self.schedule()
        }
    }
    public func cancel() { task?.cancel() }
    public func retry(_ id: String? = nil) {
        guard !closed, task == nil else { return }
        do {
            if let unsaved { try save(unsaved) }
            if archive == nil { Task { await start() }; return }
            if let id, var state = archive, let index = state.reports.firstIndex(where: { $0.id == id && $0.analysisState == .failed }) {
                state.reports[index].analysisState = .pending; state.reports[index].analysisError = nil
                try save(state)
            }
            wake()
        } catch { /* save preserves the aggregate and the recovery action */ }
    }
    private func collectAndAnalyze() async {
        guard var state = archive else { return }
        do {
            let due = WorkReportPeriod.due(now: now(), dailyEnd: state.dailyEnd, weeklyEnd: state.weeklyEnd, calendar: state.calendar)
            if !due.isEmpty {
                let source = try await snapshot()
                try Task.checkCancellation()
                for period in due where !state.reports.contains(where: { $0.id == period.id }) {
                    state.record(.build(period: period, snapshot: source, at: now()))
                }
                try save(state)
            }
            // Work oldest first so the previous report is available for weekly comparisons.
            for id in state.reports.filter({ $0.analysisState == .pending }).sorted(by: { $0.period.end < $1.period.end }).map(\.id) {
                try Task.checkCancellation()
                guard !closed, var state = archive, let index = state.reports.firstIndex(where: { $0.id == id }) else { return }
                state.reports[index].analysisState = .generating
                state.reports[index].analysisModel = model()
                do { try save(state) }
                catch {
                    // The provider has not started. Persist a retryable state when the user
                    // repairs storage, instead of leaving an orphaned generating marker.
                    state.reports[index].analysisState = .pending
                    unsaved = state; reports = state.reports
                    throw error
                }
                let report = state.reports[index]
                let previous = state.reports.filter { $0.period.kind == report.period.kind && $0.period.end <= report.period.start }.max { $0.period.end < $1.period.end }
                do {
                    let text = try await analyze(report, previous)
                    try Task.checkCancellation()
                    state.reports[index].analysis = text
                    state.reports[index].analysisState = .ready
                } catch {
                    state.reports[index].analysisState = .failed
                    state.reports[index].analysisError = error is CancellationError ? "분석이 중단됐어요. 집계는 보관돼 있어요." : "Stallari 분석을 완료하지 못했어요. 연결 상태를 확인한 뒤 다시 시도해 주세요."
                }
                try save(state)
            }
        } catch is CancellationError { /* shutdown awaits the analyzer's owned process cleanup */ }
        catch { if unsaved == nil { self.error = "작업 기록 집계를 완료하지 못했어요. 다시 시도해 주세요." } }
    }
    private func schedule() {
        guard !closed, error == nil, let state = archive else { return }
        let dates = [state.dailyEnd, state.weeklyEnd].compactMap { state.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
        guard let next = dates.min() else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSince(self?.now() ?? .now)))) }
            catch { return }
            self?.wake()
        }
    }
    public func whenIdle() async { await task?.value }
    public func shutdown() async {
        closed = true; timer?.cancel(); task?.cancel()
        await task?.value; timer = nil; task = nil
    }
}
