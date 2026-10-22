export type Block = {
  kind: "markdown" | "openui";
  text: string;
  key: string;
  complete: boolean;
};
/** Recognize only top-level fences; quoted examples and longer fences remain ordinary Markdown. */
export function splitContent(text: string): Block[] {
  const lines = text.split("\n"),
    blocks: Block[] = [];
  let plain: string[] = [];
  let normalFence = "";
  const flush = () => {
    if (plain.length) {
      blocks.push({
        kind: "markdown",
        text: plain.join("\n"),
        key: `markdown-${blocks.length}`,
        complete: true,
      });
      plain = [];
    }
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i],
      match = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (normalFence) {
      plain.push(line);
      if (
        match &&
        match[1][0] === normalFence[0] &&
        match[1].length >= normalFence.length &&
        !match[2].trim()
      )
        normalFence = "";
      continue;
    }
    if (match && /^openui(?:-lang)?\s*$/.test(match[2])) {
      flush();
      const body: string[] = [];
      let complete = false;
      for (i++; i < lines.length; i++) {
        const close = lines[i].match(/^ {0,3}(`{3,}|~{3,})\s*$/);
        if (
          close &&
          close[1][0] === match[1][0] &&
          close[1].length >= match[1].length
        ) {
          complete = true;
          break;
        }
        body.push(lines[i]);
      }
      blocks.push({
        kind: "openui",
        text: body.join("\n"),
        key: `openui-${blocks.length}`,
        complete,
      });
    } else {
      plain.push(line);
      if (match) normalFence = match[1];
    }
  }
  flush();
  return blocks;
}
export function applyPatch<T>(
  previous: Record<string, T>,
  patch: { upsert: Record<string, T>; removed: string[] },
): Record<string, T> {
  const next = { ...previous, ...patch.upsert };
  for (const id of patch.removed) delete next[id];
  return next;
}
export function safeLink(value: string): boolean {
  try {
    const u = new URL(value);
    return (
      ["https:", "http:"].includes(u.protocol) && !u.username && !u.password
    );
  } catch {
    return false;
  }
}
