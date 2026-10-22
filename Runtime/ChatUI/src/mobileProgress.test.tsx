// @vitest-environment jsdom
import React, { act } from "react";
import { afterEach, expect, it, vi } from "vitest";
import type { RowData } from "./app";

type KnarrWindow = Window & {
  webkit?: { messageHandlers: { knarr: { postMessage: (value: unknown) => void } } };
  knarr: { receive: (snapshot: unknown) => void };
};
declare global {
  // The renderer reads this flag before it starts animated updates.
  var IS_REACT_ACT_ENVIRONMENT: boolean;
}
(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

/** jsdom has no layout: give the transcript a viewport so the virtual list renders its rows. */
class NoopResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}
(globalThis as unknown as { ResizeObserver: typeof NoopResizeObserver }).ResizeObserver = NoopResizeObserver;
Object.defineProperty(HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 600 });
Object.defineProperty(HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 390 });
Object.defineProperty(HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => 120 });
HTMLElement.prototype.getBoundingClientRect = function () {
  return { x: 0, y: 0, width: 390, height: 120, top: 0, left: 0, right: 390, bottom: 120, toJSON: () => ({}) } as DOMRect;
};

afterEach(() => {
  document.body.innerHTML = "";
  delete (window as unknown as KnarrWindow).webkit;
});

const activity = (kind: "reasoning" | "tool", title: string, state: string, label: string, startedAt: number, updatedAt: number) =>
  ({ kind, title, state, label, startedAt, updatedAt });

const row = (id: string, kind: string, text: string, extra: Partial<RowData> = {}): RowData =>
  ({ id, kind, text, time: "오전 9:00", at: 1_790_000_000_000, attachments: [], state: {}, ...extra });

/** The payload `MobileChatWebView.flush()` sends for rows carrying the Mac's activity values. */
const payload = (order: string[], upsert: Record<string, RowData>, responding = false, reset = false) => ({
  session: "session-1", thread: "main", conversationRootID: null, reset,
  order, upsert, removed: [], streaming: null, footerText: "",
  responding, status: responding ? "명령 실행 진행 중" : "", canResend: false, readOnly: false, jump: false,
  target: null, highlighted: null, viewport: null, dark: false, reduceMotion: true,
  mobile: true, theme: {},
});

const settle = () => act(async () => { await new Promise(resolve => setTimeout(resolve, 0)); });

/** A saved-state message from the renderer: `{action:"state", message:<row id>, state:{...}}`. */
function savedExpansion(calls: unknown[][], id: string): unknown {
  // Newest first: toggling the same group saves more than once.
  for (const [value] of [...calls].reverse()) {
    if (!value || typeof value !== "object") continue;
    if (!("action" in value) || value.action !== "state") continue;
    if (!("message" in value) || value.message !== id) continue;
    if (!("state" in value) || !value.state || typeof value.state !== "object") continue;
    if (!("progress-expanded" in value.state)) continue;
    return value.state["progress-expanded"];
  }
  return undefined;
}

it("folds synced progress into one collapsed 진행 기록 on the phone and keeps the answer readable", async () => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.append(root);
  const posted = vi.fn();
  (window as unknown as KnarrWindow).webkit = { messageHandlers: { knarr: { postMessage: posted } } };
  // The shipped entry renders itself into #root, so import it only after the host exists.
  await act(async () => { await import("./app"); });
  const receive = (window as unknown as KnarrWindow).knarr.receive;
  const rows: Record<string, RowData> = {
    u: row("u", "user", "정리해줘"),
    think: row("think", "assistant", "영어 추론 문장", {
      activity: activity("reasoning", "추론 요약", "completed", "완료", 1000, 2000) }),
    read: row("read", "assistant", "Sources/Login/LoginView.swift", {
      activity: activity("tool", "파일 읽기", "completed", "완료", 2100, 3000) }),
    bash: row("bash", "assistant", "swift", {
      activity: activity("tool", "명령 실행", "completed", "완료", 3100, 4000) }),
    answer: row("answer", "assistant", "빈 이메일 안내 문구를 고쳤어요."),
  };
  await act(async () => receive(payload(Object.keys(rows), rows, false, true)));
  await settle();

  expect(document.documentElement.dataset.mobile).toBe("true");
  const summaries = () => [...root.querySelectorAll<HTMLElement>(".progress-group summary")];
  expect(summaries().length).toBe(1);
  expect(summaries()[0].textContent).toContain("진행 기록");
  expect(summaries()[0].textContent).toContain("완료");
  expect(root.querySelector<HTMLDetailsElement>(".progress-group details")?.open).toBe(false);
  // Collapsed records are not shown, and the reasoning text never reads as an ordinary answer.
  expect(root.querySelectorAll(".activity").length).toBe(0);
  expect(root.querySelector(".assistant")?.textContent).toContain("빈 이메일 안내 문구를 고쳤어요.");
  expect(root.textContent).not.toContain("영어 추론 문장");
  expect(root.textContent).not.toContain("명령 실행");

  // Expanding shows every record and asks native to save the open state under the group's id.
  await act(async () => summaries()[0].click());
  await settle();
  expect(root.querySelectorAll(".activity").length).toBe(3);
  expect(root.textContent).toContain("영어 추론 문장");
  expect(savedExpansion(posted.mock.calls, "think")).toBe(true);

  // Folding again restores the collapsed summary and saves that too.
  await act(async () => summaries()[0].click());
  await settle();
  expect(root.querySelectorAll(".activity").length).toBe(0);
  expect(savedExpansion(posted.mock.calls, "think")).toBe(false);

  // A later sync with a running record keeps one collapsed group and never duplicates rows.
  const running = row("bash", "assistant", "swift test", {
    activity: activity("tool", "명령 실행", "running", "진행 중", 5000, 5000) });
  await act(async () => receive(payload(["u", "bash"], { bash: running }, true)));
  await settle();
  expect(summaries().length).toBe(1);
  expect(summaries()[0].textContent).toContain("명령 실행");
  expect(summaries()[0].textContent).toContain("진행 중");
  expect(root.querySelector<HTMLDetailsElement>(".progress-group details")?.open).toBe(false);
  expect(root.querySelector(".responding")).toBeNull();
});
