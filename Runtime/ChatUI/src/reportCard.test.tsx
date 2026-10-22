// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, expect, it, vi } from "vitest";
import { ReportCard, type RowData } from "./app";
declare global {
  var IS_REACT_ACT_ENVIRONMENT: boolean;
}
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
const containers: HTMLElement[] = [];
afterEach(() => { containers.splice(0).forEach(e => e.remove()); });

type ReportState = NonNullable<RowData["report"]>["state"];

function reportRow(state: ReportState, overrides: Partial<NonNullable<RowData["report"]>> = {}): RowData {
  return {
    id: "report-card", kind: "report", text: "", time: "오전 9:00", at: 1_790_000_000_000, attachments: [], state: {},
    report: {
      id: "daily:1:Asia/Seoul", title: "10월 20일 · 일일 작업 보고", state,
      lines: ["작업 2개 · 실행 2회 · 누적 1시간 20분", "완료 1 · 진행 중 1 · 답변 필요 0"],
      error: null, retryable: state === "failed", busy: false, ...overrides,
    },
  };
}
function installPost() {
  const posted = vi.fn();
  window.webkit = { messageHandlers: { knarr: { postMessage: posted } } };
  return posted;
}
it("a report card asks native to open its own saved report", async () => {
  const host = document.createElement("div"); document.body.append(host); containers.push(host);
  const root = createRoot(host);
  const posted = installPost();
  await act(async () => root.render(<ReportCard row={reportRow("ready")} readOnly={false} />));
  expect(host.querySelector(".report-lines")?.textContent).toContain("완료 1");
  expect(host.textContent).not.toContain("다시 시도");
  const open = [...host.querySelectorAll("button")].find(b => b.textContent === "보고서 열기") as HTMLButtonElement;
  await act(async () => open.click());
  expect(posted.mock.calls.at(-1)?.[0]).toMatchObject({ action: "reportOpen", message: "report-card", report: "daily:1:Asia/Seoul" });
  await act(async () => root.unmount());
});

it("a failed report shows its error and retries the same row", async () => {
  const host = document.createElement("div"); document.body.append(host); containers.push(host);
  const root = createRoot(host);
  const posted = installPost();
  const row = reportRow("failed", { error: "Stallari 분석을 완료하지 못했어요." });
  await act(async () => root.render(<ReportCard row={row} readOnly={false} />));
  expect(host.querySelector(".report-error")?.textContent).toContain("완료하지 못했어요");
  const retry = () => [...host.querySelectorAll("button")].find(b => b.textContent === "다시 시도") as HTMLButtonElement | undefined;
  await act(async () => retry()?.click());
  expect(posted.mock.calls.at(-1)?.[0]).toMatchObject({ action: "reportRetry", message: "report-card", report: "daily:1:Asia/Seoul" });
  // A running analysis disables retry instead of offering a second one.
  await act(async () => root.render(<ReportCard row={reportRow("failed", { error: "다시 시도 중", busy: true })} readOnly={false} />));
  expect(retry()?.disabled).toBe(true);
  await act(async () => root.unmount());
});

it("a report card in the shared mobile renderer stays readable", async () => {
  const host = document.createElement("div"); document.body.append(host); containers.push(host);
  const root = createRoot(host);
  installPost();
  document.documentElement.dataset.mobile = "true";
  try {
    await act(async () => root.render(<ReportCard row={reportRow("ready")} readOnly={false} isMobile />));
    expect(host.textContent).toContain("일일 작업 보고");
    expect(host.textContent).toContain("답변 필요 0");
    expect(host.querySelector(".report-card")).not.toBeNull();
    // The phone has no report detail route, so the card must not offer a button that goes nowhere.
    expect(host.querySelector("button")).toBeNull();
  } finally { delete document.documentElement.dataset.mobile; }
  await act(async () => root.unmount());
});
