import SwiftUI
import KnarrCore

private struct WorkReportError: View {
    let store: any KnarrStore
    var body: some View {
        if let error = store.workReportError {
            HStack(alignment: .top, spacing: K.s2) {
                Text(error).font(K.secondary).foregroundStyle(K.red)
                Button("다시 시도") { store.retryWorkReport(nil) }.disabled(store.workReportBusy)
            }
        }
    }
}
struct WorkReportHistory: View {
    let store: any KnarrStore
    @Binding var selected: String?
    let openIssue: (Issue.ID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkReportError(store: store).padding(.horizontal, K.s4)
            if let report = store.workReports.first(where: { $0.id == selected }) {
                HStack {
                    Button { selected = nil } label: { Label("보고 목록", systemImage: "chevron.left") }
                    Spacer()
                    Text(report.period.dateLabel).font(K.caption).foregroundStyle(K.faint)
                }.padding(K.s4)
                WorkReportDetail(report: report, busy: store.workReportBusy, retry: { store.retryWorkReport(report.id) }, cancel: { store.cancelWorkReportAnalysis() }, openIssue: openIssue)
            } else {
                Text("작업 보고").font(K.title).padding(K.s4)
                Text("매일 오전 9시 · 주간 보고는 월요일 오전 9시")
                    .font(K.caption).foregroundStyle(K.faint).padding(.horizontal, K.s4)
                if store.workReports.isEmpty {
                    Text("보고 시간이 되면 어제 작업의 결과와 개선점을 여기에 모아 드려요.")
                        .font(K.body).foregroundStyle(K.muted).padding(K.s5).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(store.workReports) { report in
                                Button { selected = report.id } label: {
                                    HStack(alignment: .top, spacing: K.s3) {
                                        VStack(alignment: .leading, spacing: K.s1) {
                                            Text(report.period.dateLabel + " · " + report.period.title).font(K.body).foregroundStyle(K.ink)
                                            Text("작업 \(report.items.count)개 · 누적 " + WorkReportTime.text(report.time.total)).font(K.caption).foregroundStyle(K.muted)
                                        }
                                        Spacer()
                                        Text(report.analysisLabel).font(K.caption).foregroundStyle(K.faint)
                                    }.padding(K.s4).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityIdentifier("work-report-row-" + report.id)
                                Divider().overlay(K.line)
                            }
                        }
                    }
                }
            }
        }.background(K.surface)
    }
}
struct WorkReportDetail: View {
    let report: WorkReport
    var busy = false
    let retry: () -> Void
    var cancel: () -> Void = {}
    let openIssue: (Issue.ID) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: K.s5) {
                VStack(alignment: .leading, spacing: K.s2) {
                    Text(report.period.title).font(K.title)
                    Text("작업 \(report.items.count)개 · 실행 \(report.runCount)회 · 실패 종료 \(report.failedRunCount)회 · 이어받기 \(report.retryCount)회")
                        .font(K.secondary).foregroundStyle(K.muted)
                    Text("누적 실행 " + WorkReportTime.text(report.time.total) + " · 동시 실행을 한 번 센 시간 " + WorkReportTime.text(report.time.elapsed))
                        .font(K.body)
                    Text(WorkReport.coverage).font(K.caption).foregroundStyle(K.faint)
                }
                if report.analysisState == .ready {
                    VStack(alignment: .leading, spacing: K.s2) {
                        Text("Stallari 분석").font(K.title)
                        MarkdownText(text: report.analysis)
                    }
                } else if report.analysisState == .failed {
                    VStack(alignment: .leading, spacing: K.s2) {
                        Text(report.analysisError ?? "분석을 완료하지 못했어요.").font(K.body).foregroundStyle(K.amber)
                        Button("분석 다시 시도", action: retry).disabled(busy).help(busy ? "현재 보고 분석을 마친 뒤 다시 시도할 수 있어요." : "저장된 집계로 Stallari 분석을 다시 요청해요.")
                    }.accessibilityIdentifier("work-report-analysis-error")
                } else {
                    Text(report.analysisLabel).font(K.body).foregroundStyle(K.muted)
                    if report.analysisState == .generating { Button("분석 중지", action: cancel) }
                }
                if !report.plans.isEmpty {
                    DisclosureGroup("기간의 주간 계획") { ForEach(Array(report.plans.enumerated()), id: \.offset) { _, line in Text(line).font(K.body).padding(.vertical, K.s1) } }
                }
                Text("작업별 결과와 근거").font(K.title)
                ForEach(report.items) { item in
                    VStack(alignment: .leading, spacing: K.s3) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: K.s1) {
                                Text(item.project).font(K.caption).foregroundStyle(K.faint)
                                Text(item.title).font(K.body.weight(.semibold))
                            }
                            Spacer()
                            Button("이슈 열기") { openIssue(.init(item.id)) }.accessibilityIdentifier("report-issue-" + item.id)
                        }
                        Text(item.outcome + " · 조건 \(item.criteria.filter { $0.state == .met }.count)/\(item.criteria.count)").font(K.secondary)
                        Text("누적 " + WorkReportTime.text(item.time.total) + " · 실행 \(item.runs.count)회").font(K.secondary).foregroundStyle(K.muted)
                        Text(item.applicationRecord).font(K.caption).foregroundStyle(K.faint)
                        DisclosureGroup("시작 이유 · 실행 지시") { Text(item.reason).font(K.body).textSelection(.enabled).padding(.top, K.s2) }
                        DisclosureGroup("판정 근거와 실행 기록") {
                            VStack(alignment: .leading, spacing: K.s3) {
                                ForEach(Array(item.criteria.enumerated()), id: \.offset) { index, criterion in
                                    Text("\(index + 1). " + criterion.text).font(K.body)
                                    Text(criterion.evidence.isEmpty ? "판정 근거가 아직 없어요." : criterion.evidence).font(K.secondary).foregroundStyle(K.muted)
                                }
                                ForEach(item.runs) { run in
                                    VStack(alignment: .leading, spacing: K.s1) {
                                        Text(run.id).font(K.mono)
                                        Text(run.timestampLabel).font(K.caption)
                                        if let reason = run.stopReason { Text(reason).font(K.secondary).foregroundStyle(K.muted) }
                                    }
                                }
                            }.padding(.top, K.s3).textSelection(.enabled)
                        }
                        Divider().overlay(K.line)
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("report-item-" + item.id)
                }
            }.padding(K.s5).frame(maxWidth: K.column, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
        }.accessibilityIdentifier("work-report-detail")
    }
}
private extension WorkReport {
    var analysisLabel: String {
        switch analysisState {
        case .pending: "분석 대기"
        case .generating: "Stallari 분석 중"
        case .ready: "보고 보기"
        case .failed: "분석 다시 시도 필요"
        case .noActivity: "기록된 작업 없음"
        }
    }
}

private extension WorkReportRun {
    var timestampLabel: String {
        let start = startedAt.formatted(date: .abbreviated, time: .standard)
        let end = endedAt?.formatted(date: .abbreviated, time: .standard) ?? "종료 미기록"
        let label = ["working": "실행 중", "waitingOnHuman": "답변 대기", "succeeded": "실행 종료", "failed": "실패 종료", "cancelled": "취소", "interrupted": "중단"][state] ?? state
        return "\(label) · \(start) → \(end)"
    }
}
