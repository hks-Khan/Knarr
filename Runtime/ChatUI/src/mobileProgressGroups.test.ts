import { describe, expect, it } from "vitest";
import { groupProgress } from "./progressGroups";
/**
 * Rows exactly as the phone's webview builds them from a synced message: the Mac's activity values,
 * no `responseStartedAt`. Same `groupProgress` the Mac page uses, so both screens fold identically.
 */
type Activity = { kind: string; title: string; state: string; label: string; startedAt: number; updatedAt: number };
type Row = { id: string; kind: string; text: string; activity?: Activity };
const row = (id: string, kind: string, text = id, activity?: Activity): Row => ({ id, kind, text, ...(activity ? { activity } : {}) });
const tool = (id: string, title: string, state = "completed", start = 1000, end = 3000) =>
  row(id, "activity", id, { kind: "tool", title, state, label: state === "completed" ? "완료" : "진행 중", startedAt: start, updatedAt: end });
const reasoning = (id: string, start = 900, end = 1500) =>
  row(id, "activity", "추론 본문", { kind: "reasoning", title: "추론 요약", state: "completed", label: "완료", startedAt: start, updatedAt: end });
const project = (items: Row[], responding: boolean, responseStartedAt?: number | null) =>
  groupProgress(items.map(x => x.id), Object.fromEntries(items.map(x => [x.id, x])), responding, responseStartedAt, true);

describe('progress groups from synced phone messages', () => {
  it('folds reasoning, tools and intermediate prose into one group and keeps the answer', () => {
    const p = project([row("u", "user", "정리해줘"), reasoning("think"), tool("read", "파일 읽기"), tool("bash", "명령 실행"),
      row("mid", "assistant", "중간 안내"), row("answer", "assistant", "다 끝났어요")], false);
    expect(p.order).toEqual(["u", "think", "answer"]);
    expect(p.groups.think.ids).toEqual(["think", "read", "bash", "mid"]);
    expect(p.groups.think.title).toBe("진행 기록");
    expect(p.groups.think.label).toBe("완료");
    expect(p.groups.think.startedAt).toBe(900);
    expect(p.groups.think.endedAt).toBe(3000);
    expect(p.owner.bash).toBe("think");
  });

  it('marks a group live only while its own record is running, since the phone sends no response start', () => {
    const live = project([row("u", "user", "?"), tool("bash", "명령 실행", "running", 4000, 4000), row("answer", "assistant", "작업 중")], true);
    expect(live.groups.bash.running).toBe(true);
    expect(live.groups.bash.title).toBe("명령 실행");
    const settled = project([row("u", "user", "?"), tool("read", "파일 읽기"), row("answer", "assistant", "끝")], true);
    expect(settled.groups.read.running).toBe(false);
    expect(settled.groups.read.label).toBe("완료");
  });

  it('keeps an earlier turn idle during a later response and keeps failures visible', () => {
    const p = project([row("u1", "user", "1"), tool("a", "파일 읽기", "completed", 1000, 2000), row("answer1", "assistant", "끝"),
      row("u2", "user", "2"), tool("bad", "명령 실행", "failed", 5000, 6000)], true);
    expect(p.groups.a.running).toBe(false);
    expect(p.groups.bad.label).toBe("실패 기록 있음");
    expect(p.order).toEqual(["u1", "a", "answer1", "u2", "bad"]);
  });

  it('leaves rows without activity as ordinary messages', () => {
    const p = project([row("u", "user", "질문"), row("answer", "assistant", "Stallari 답변")], false);
    expect(p.order).toEqual(["u", "answer"]);
    expect(p.groups).toEqual({});
  });
});
