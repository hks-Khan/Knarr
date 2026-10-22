import { describe, it, expect } from "vitest";
import { splitContent, applyPatch, safeLink } from "./protocol";
describe("transcript protocol", () => {
  it("streams an unfinished OpenUI fence independently of prose", () => {
    const blocks = splitContent('설명\n\n```openui\nroot = Text("안녕")');
    expect(blocks.map((b) => b.kind)).toEqual(["markdown", "openui"]);
    expect(blocks[1].text).toBe('root = Text("안녕")');
    expect(blocks[1].complete).toBe(false);
  });
  it("keeps ordinary code and fences inside longer code fences as Markdown", () => {
    const text = '````text\n```openui\nroot = Text("not live")\n```\n````';
    expect(splitContent(text)).toEqual([
      { kind: "markdown", text, key: "markdown-0", complete: true },
    ]);
  });
  it("preserves block identity while content is streaming and accepts later prose", () => {
    const a = splitContent('```openui\nroot = Text("a")');
    const b = splitContent('```openui\nroot = Text("abc")\n```\n끝');
    expect(a[0].key).toBe(b[0].key);
    expect(b[0].complete).toBe(true);
    expect(b[1].text).toBe("끝");
  });
  it("patches only changed message references and removes deleted records", () => {
    const keep = { text: "same" },
      prev = { a: keep, b: { text: "old" }, c: { text: "removed" } };
    const next = applyPatch(prev, {
      upsert: { b: { text: "new" } },
      removed: ["c"],
    });
    expect(next.a).toBe(keep);
    expect(next.b).toEqual({ text: "new" });
    expect(next.c).toBeUndefined();
    expect(prev.c).toBeDefined();
  });
  it("only routes ordinary web links to the native opener", () => {
    expect(safeLink("https://example.org")).toBe(true);
    for (const url of [
      "javascript:alert(1)",
      "file:///etc/passwd",
      "data:text/html,test",
      "knarr://approve",
      "https://name:secret@example.org",
    ])
      expect(safeLink(url)).toBe(false);
  });
});
