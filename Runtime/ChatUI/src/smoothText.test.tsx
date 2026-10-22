// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, expect, test, vi } from "vitest";
import { useSmoothText } from "./smoothText";

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  document.body.innerHTML = "";
});
test("visible streaming reveals graphemes across frames and terminal reveals full text", async () => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  vi.spyOn(document, "hidden", "get").mockReturnValue(false);
  vi.spyOn(performance, "now").mockReturnValue(0);
  let next = 0;
  const frames = new Map<number, FrameRequestCallback>();
  vi.stubGlobal("requestAnimationFrame", (fn: FrameRequestCallback) => {
    frames.set(++next, fn);
    return next;
  });
  vi.stubGlobal("cancelAnimationFrame", (id: number) => frames.delete(id));
  const node = document.createElement("div");
  document.body.append(node);
  const root = createRoot(node);
  const text = "한👨‍👩‍👧‍👦é".repeat(100);
  function Probe({ streaming }: { streaming: boolean }) {
    return <p>{useSmoothText(text, streaming)}</p>;
  }
  try {
    await act(() => root.render(<Probe streaming={true} />));
    expect(node.textContent).toBe("");
    const tick = async (now: number) => {
      const callbacks = [...frames.values()];
      frames.clear();
      await act(() => callbacks.forEach((fn) => fn(now)));
    };
    await tick(16);
    const first = node.textContent!;
    await tick(32);
    const second = node.textContent!;
    expect(first.length).toBeGreaterThan(0);
    expect(second.length).toBeGreaterThan(first.length);
    expect(second.length).toBeLessThan(text.length);
    expect(text.startsWith(second)).toBe(true);
    const boundaries = [
      ...new Intl.Segmenter("ko", { granularity: "grapheme" }).segment(text),
    ].map((s) => s.index + s.segment.length);
    expect(boundaries).toContain(second.length);
    await act(() => root.render(<Probe streaming={false} />));
    expect(node.textContent).toBe(text);
    expect(frames.size).toBe(0);
  } finally {
    await act(() => root.unmount());
  }
});
test("occluded streaming displays received text without waiting for animation frames", async () => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  vi.spyOn(document, "hidden", "get").mockReturnValue(true);
  const node = document.createElement("div");
  document.body.append(node);
  const root = createRoot(node);
  function Probe() {
    return <p>{useSmoothText("백그라운드에서 받은 답변", true)}</p>;
  }
  try {
    await act(() => root.render(<Probe />));
    expect(node.textContent).toBe("백그라운드에서 받은 답변");
  } finally {
    await act(() => root.unmount());
  }
});
