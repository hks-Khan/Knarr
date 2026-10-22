import React, {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import { createRoot } from "react-dom/client";
import { useVirtualizer } from "@tanstack/react-virtual";
import ReactMarkdown, { defaultUrlTransform } from "react-markdown";
import remarkGfm from "remark-gfm";
import rehypeHighlight from "rehype-highlight";
import { Renderer } from "@openuidev/react-lang";
import { library } from "./library";
import { useSmoothText } from "./smoothText";
import { applyPatch, safeLink, splitContent } from "./protocol";
import { groupProgress, type ProgressGroup, type ProgressProjection } from "./progressGroups";
import { IMAGE_SCHEME, InlineImage } from "./inlineImage";

type Saved = Record<string, any>;
export type RowData = {
  id: string;
  kind: string;
  text: string;
  time: string;
  /** Milliseconds since epoch, for card ordering and unread counts. */
  at?: number;
  project?: string;
  conversationRootID?: string | null;
  isConversationLink?: boolean;
  mainTransferID?: string;
  request?: string;
  activity?: {
    kind: "reasoning" | "tool";
    title: string;
    state: string;
    label: string;
    startedAt: number;
    updatedAt: number;
  };
  attachments: string[];
  attachmentImages?: string[];
  pendingCount?: number;
  state: Saved;
  lines?: string[];
  title?: string;
  tone?: string;
  primary?: string;
  issue?: {
    id: string;
    title: string;
    status: string;
    met: number;
    total: number;
    criteriaSummary?: string;
    headline: string;
    detail: string;
    state: string;
    steps: { title: string; state: string }[];
    hirds: { state: string; since: number }[];
  };
  proposal?: {
    version: number;
    instruction: string;
    model: string;
    mode: string;
    thinking?: string;
    previousRun?: string;
    editable: boolean;
    note?: string;
    blockReason?: string;
  };
  /** One generated work report, shown in the main conversation. */
  report?: {
    id: string;
    title: string;
    state: "pending" | "generating" | "ready" | "failed" | "noActivity";
    lines: string[];
    error?: string | null;
    retryable: boolean;
    busy: boolean;
  };
  question?: {
    id: string;
    asker: string;
    issueTitle?: string;
    prompt: string;
    options: string[];
    multiple: boolean;
    status: string;
    summary: string;
    style?: string;
    placeholder?: string;
    prefill?: string;
  };
};
type CanvasData = {
  root: string;
  order: string[];
  rows: Record<string, RowData>;
  responding: boolean;
  /** True only when this root's reply is queued behind someone else's answer. */
  waiting?: boolean;
  /** True only when this root's own answer can be aborted without dropping queued replies. */
  stoppable?: boolean;
  /** Why an answering root cannot be stopped safely, straight from the store's current state. */
  stopBlockReason?: string | null;
  status: string;
  startedAt: number | null;
  readOnly: boolean;
};
type ConversationSummary = {
  at: number;
  time: string;
  replyAts: number[];
};
type Snapshot = {
  mobile?: boolean;
  progress?: ProgressProjection;
  session: string;
  thread: string;
  reset: boolean;
  order: string[];
  conversationRootID?: string | null;
  upsert: Record<string, RowData>;
  removed: string[];
  streaming: string | null;
  footerText: string;
  responding: boolean;
  status: string;
  /** Roots whose focused conversation is answering right now. */
  respondingRoots?: string[];
  /** Roots whose own answer can be stopped; others are only waiting behind it. */
  stoppableRoots?: string[];
  /** Roots whose reply is queued behind another answer. */
  waitingRoots?: string[];
  /** A native request to expand one focused conversation in place. */
  canvasRequest?: { root: string; token: string } | null;
  /** Rows for the one canvas the page asked to show. */
  canvas?: CanvasData | null;
  /** Last answer time per conversation link, for collapsed cards. */
  summaries?: Record<string, ConversationSummary>;
  responseStartedAt?: number | null;
  responseLastEventAt?: number | null;
  canResend: boolean;
  readOnly: boolean;
  jump: boolean;
  target: string | null;
  highlighted: string | null;
  viewport: Saved | null;
  dark: boolean;
  reduceMotion: boolean;
  theme: Record<string, string>;
};
let env: { session: string; thread: string; conversationRootID: string | null } = { session: "", thread: "", conversationRootID: null };
let rows: Record<string, RowData> = {};
let saved: Record<string, Saved> = {};
let mobile = false;
let receive: (s: Snapshot) => void = () => {};
const post = (action: string, message?: string, fields: Saved = {}) => {
  window.webkit?.messageHandlers.knarr.postMessage({
    ...env,
    action,
    message,
    ...fields,
  });
};
const save = (id: string, key: string, value: any) => {
  saved[id] = { ...(saved[id] ?? {}), [key]: value };
  post("state", id, { state: saved[id] });
};
declare global {
  interface Window {
    webkit?: {
      messageHandlers: { knarr: { postMessage: (value: unknown) => void } };
    };
    knarr: {
      receive: (s: Snapshot) => void;
      result: (message: string, error: string | null, request?: string) => void;
      ready: boolean;
      /** Native asks the page to re-report what is visible after the app becomes active. */
      recheckVisibility?: () => void;
    };
  }
}
window.knarr = {
  ready: false,
  receive: (s) => receive(s),
  result: (message, error, request) =>
    window.dispatchEvent(
      new CustomEvent("knarr-result", { detail: { message, error, request } }),
    ),
};
function useSaved<T>(id: string, key: string, initial: T): [T, (v: T) => void] {
  const [v, set] = useState<T>(() => saved[id]?.[key] ?? initial);
  return [
    v,
    (next: T) => {
      set(next);
      save(id, key, next);
    },
  ];
}

const Markdown = memo(function Markdown({
  text,
  id,
}: {
  text: string;
  id: string;
}) {
  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm]}
      rehypePlugins={[rehypeHighlight]}
      urlTransform={(value) =>
        value.startsWith(`${IMAGE_SCHEME}://image/`) ? value : defaultUrlTransform(value)
      }
      components={{
        a: ({ href, children }) => (
          <a
            href={safeLink(href ?? "") ? href : undefined}
            onClick={(e) => {
              e.preventDefault();
              if (safeLink(href ?? "")) post("link", id, { text: href });
            }}
          >
            {children}
          </a>
        ),
        img: ({ alt, src }) => (
          <InlineImage
            alt={alt}
            src={src}
            onOpen={(address) => post("imagePreview", id, { text: address })}
          />
        ),
        table: ({ children }) => (
          <div className="table-scroll">
            <table>{children}</table>
          </div>
        ),
        pre: ({ children }) => (
          <div className="code-block">
            <button
              className="code-copy"
              aria-label="코드 복사"
              onClick={(e) => {
                const code =
                  e.currentTarget.parentElement?.querySelector(
                    "code",
                  )?.textContent;
                post("copyText", id, { text: code ?? "" });
              }}
            >
              복사
            </button>
            <pre>{children}</pre>
          </div>
        ),
        blockquote: ({ children, node }) => {
          // remark exposes the first textual paragraph without executing source HTML.
          const raw =
            (node?.children?.[1] as any)?.children?.[0]?.value ??
            (node?.children?.[0] as any)?.children?.[0]?.value ??
            "";
          const match = String(raw).match(
            /^\[!([A-Za-z]+)\]([-+])?\s*([^\n]*)/,
          );
          if (!match) return <blockquote>{children}</blockquote>;
          const kind = match[1].toUpperCase();
          const tone = ["RESULT", "SUCCESS", "DONE", "CHECK", "TIP"].includes(
            kind,
          )
            ? "green"
            : ["STOP", "WARNING", "DANGER", "FAILURE", "BUG"].includes(kind)
              ? "red"
              : [
                    "DECIDE",
                    "IMPORTANT",
                    "CAUTION",
                    "QUESTION",
                    "TODO",
                    "ACTION",
                  ].includes(kind)
                ? "accent"
                : "faint";
          return (
            <Callout
              id={id}
              marker={match[0]}
              title={match[3] || kind}
              folded={match[2] === "-"}
              tone={tone}
            >
              {children}
            </Callout>
          );
        },
      }}
    >
      {text}
    </ReactMarkdown>
  );
});
function Callout({
  id,
  marker,
  title,
  folded,
  tone,
  children,
}: {
  id: string;
  marker: string;
  title: string;
  folded: boolean;
  tone: string;
  children: React.ReactNode;
}) {
  const [open, setOpen] = useSaved(id, "callout:" + marker, !folded);
  // Strip the semantic marker from the first React paragraph while retaining its remaining content.
  let removed = false;
  const content = React.Children.map(children, (child) => {
    if (
      !removed &&
      React.isValidElement<{ children?: React.ReactNode }>(child) &&
      child.type === "p"
    ) {
      removed = true;
      const parts = React.Children.toArray(child.props.children);
      if (typeof parts[0] === "string")
        parts[0] = parts[0].replace(marker, "").replace(/^\n/, "");
      return React.cloneElement(child, {}, ...parts);
    }
    return child;
  });
  return (
    <aside className={`callout tone-${tone}`}>
      <button
        className="callout-title"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        {open ? "⌄" : "›"} {title}
      </button>
      {open && <div>{content}</div>}
    </aside>
  );
}
function UiBlock({
  id,
  blockKey,
  source,
  streaming,
  readOnly,
}: {
  id: string;
  blockKey: string;
  source: string;
  streaming: boolean;
  readOnly: boolean;
}) {
  const initial = useRef(
    saved[id]?.[blockKey]?.source === source
      ? saved[id]?.[blockKey]?.values
      : {},
  );
  const [errors, setErrors] = useState<string[]>([]);
  const [actionError, setActionError] = useState("");
  useEffect(() => {
    const result = (e: Event) => {
      const d = (e as CustomEvent).detail;
      if (d.message === id) setActionError(d.error ?? "");
    };
    window.addEventListener("knarr-result", result);
    return () => window.removeEventListener("knarr-result", result);
  }, [id]);
  const update = useCallback(
    (state: Saved) => {
      if (!streaming) save(id, blockKey, { source, values: state });
    },
    [id, blockKey, source, streaming],
  );
  return (
    <div className="generated-ui">
      <fieldset disabled={streaming || readOnly} aria-label="대화 도구">
        <Renderer
          library={library}
          response={source}
          isStreaming={streaming}
          initialState={initial.current}
          onStateUpdate={update}
          onAction={(e) => {
            if (readOnly || streaming) return;
            if (e.type === "continue_conversation")
              post("continue", id, {
                text:
                  e.humanFriendlyMessage +
                  "\n" +
                  JSON.stringify(e.formState ?? {}),
              });
            else if (
              e.type === "open_url" &&
              typeof e.params.url === "string" &&
              safeLink(e.params.url)
            )
              post("link", id, { text: e.params.url });
          }}
          onError={(list) =>
            setErrors((prev) => {
              const next = list
                .filter((e) => e.severity !== "warning")
                .map((e) => e.message);
              return JSON.stringify(prev) === JSON.stringify(next)
                ? prev
                : next;
            })
          }
        />
      </fieldset>
      {actionError && <p role="status">{actionError}</p>}
      {!streaming && errors.length > 0 && (
        <div role="status" className="tone-amber">
          화면 일부를 표시하지 못했어요.{" "}
          <button
            onClick={() =>
              post("continue", id, {
                text: "이 UI를 수정해 주세요.\n" + errors.join("\n"),
              })
            }
          >
            수정 요청
          </button>
        </div>
      )}
    </div>
  );
}
function Assistant({
  row,
  streaming,
  readOnly,
  reduceMotion,
}: {
  row: RowData;
  streaming: boolean;
  readOnly: boolean;
  reduceMotion: boolean;
}) {
  const visible = useSmoothText(row.text, streaming && !reduceMotion);
  const blocks = splitContent(visible);
  return (
    <>
      <div className="meta">
        Stallari · {row.time}
        {row.project && ` · ${row.project}`}
      </div>
      <div className="markdown">
        {blocks.map((b) =>
          b.kind === "markdown" ? (
            <Markdown key={b.key} id={row.id} text={b.text} />
          ) : (
            <UiBlock
              key={`${b.key}:${streaming ? "stream" : b.text}`}
              id={row.id}
              blockKey={b.key}
              source={b.text}
              streaming={streaming}
              readOnly={readOnly}
            />
          ),
        )}
      </div>
      <div className="message-actions">{!streaming && <Copy key={`${env.session}:${row.id}`} id={row.id} />}</div>
    </>
  );
}
function useActivityClock(running: boolean) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!running) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [running]);
  return now;
}
/** One expanded focused conversation, in the link's own transcript row. */
function MessageConversationCanvas({
  root,
  data,
  snapshot,
  onSeen,
  onClose,
  onWindow,
}: {
  root: RowData;
  data: CanvasData | null;
  snapshot: Snapshot;
  onSeen: () => void;
  onClose: () => void;
  onWindow: () => void;
}) {
  const [draft, setDraft] = useState("");
  const [error, setError] = useState<string | null>(null);
  const pendingText = useRef<string | null>(null);
  const body = useRef<HTMLDivElement>(null);
  // Until the first rows are positioned, the panel must not follow the bottom: it opens at the start.
  const follow = useRef(false);
  // Last scrollTop reported by the body, so reflow events that keep the position are not reader movement.
  const lastTop = useRef<number | null>(null);
  // The frame still owed to the current render; cancelled as soon as the reader takes over.
  const pinFrame = useRef<number | null>(null);
  const rowsHere = data?.root === root.id ? data : null;
  const responding = rowsHere?.responding ?? snapshot.respondingRoots?.includes(root.id) ?? false;
  const waiting = responding && (rowsHere?.waiting ?? snapshot.waitingRoots?.includes(root.id) ?? false);
  const stoppable = responding && !waiting
    && (rowsHere?.stoppable ?? snapshot.stoppableRoots?.includes(root.id) ?? false);
  // A running answer that cannot be aborted (other drafts queued) says why instead of hiding stop silently.
  const stopReason = !responding || waiting || stoppable ? null : (rowsHere?.stopBlockReason ?? null);
  const now = useActivityClock(responding && !waiting);
  const elapsed = rowsHere?.startedAt == null || waiting ? null : Math.max(0, Math.floor((now - rowsHere.startedAt) / 1000));
  useEffect(() => { onSeen(); }, [root.id]);
  useEffect(() => {
    const result = (event: Event) => {
      const detail = (event as CustomEvent).detail;
      if (detail.message !== root.id) return;
      setError(detail.error ?? null);
      // A failed reply keeps its text so the person can retry without retyping it.
      const sent = pendingText.current;
      pendingText.current = null;
      if (detail.error && sent) setDraft((current) => current || sent);
    };
    window.addEventListener("knarr-result", result);
    return () => window.removeEventListener("knarr-result", result);
  }, [root.id]);
  const order = rowsHere?.order ?? [];
  // Native sends only replies for this root; the link row is drawn once here as the conversation's start.
  const items = order.map((id) => rowsHere!.rows[id]).filter((row) => row && row.id !== root.id);
  // A freshly opened panel starts at the message that began the conversation, so the whole original
  // text is read first and the replies follow it. Auto-follow still keeps the live end in view once the
  // reader is at the bottom; a reply that arrives while they are reading above never yanks them down.
  const positioned = useRef(false);
  useEffect(() => {
    if (positioned.current) return;
    const el = body.current;
    if (!el || items.length === 0) return;
    // The first rows can arrive after the reader already scrolled the empty panel; leave them there.
    if (lastTop.current !== null && lastTop.current !== 0) { positioned.current = true; return; }
    positioned.current = true;
    follow.current = false;
    el.scrollTop = 0;
    lastTop.current = 0;
  }, [items.length]);
  useEffect(() => {
    const el = body.current;
    if (!el || !follow.current) return;
    // Text growth reflows after this render, so pin once more on the next frame. Both writes are ours
    // and must not be mistaken for the reader scrolling away from the bottom.
    const pin = () => {
      pinFrame.current = null;
      // The reader may have scrolled up between this render and the frame; never drag them back.
      if (!follow.current) return;
      el.scrollTop = el.scrollHeight;
      // The browser clamps scrollTop; remembering what actually landed keeps this write from
      // looking like the reader moved.
      lastTop.current = el.scrollTop;
    };
    pin();
    pinFrame.current = requestAnimationFrame(pin);
    return () => {
      if (pinFrame.current != null) cancelAnimationFrame(pinFrame.current);
      pinFrame.current = null;
    };
  }, [items.length, items.at(-1)?.text.length, rowsHere?.status]);
  const send = () => {
    const text = draft.trim();
    if (!text) return;
    pendingText.current = text;
    setDraft("");
    setError(null);
    post("canvasSend", root.id, { text });
  };
  const statusText = waiting
    ? "답변 순서를 기다리는 중"
    : (rowsHere?.status ?? snapshot.status) + (elapsed != null ? ` · ${elapsed}초` : "");
  return (
    <div className="conversation-canvas" role="region" aria-label="집중 대화" data-canvas-root={root.id}>
      <header className="conversation-header">
        <span className={`conversation-dot${responding ? " live" : ""}`} aria-hidden="true" />
        <span className="conversation-eyebrow">집중 대화</span>
        <span className="conversation-meta">{root.time}</span>
        <div className="conversation-actions">
          <button className="conversation-icon" aria-label="접기" title="접기" onClick={onClose}>
            <span className="action-symbol symbol-collapse" aria-hidden="true" />
          </button>
          <button className="conversation-icon" aria-label="새 창으로 열기" title="새 창으로 열기" onClick={onWindow}>
            <span className="action-symbol symbol-expand-window" aria-hidden="true" />
          </button>
          <button className="conversation-icon conversation-close" aria-label="닫기" title="닫기" onClick={onClose}>
            <span className="action-symbol symbol-close" aria-hidden="true" />
          </button>
        </div>
      </header>
      <div
        className="conversation-body"
        ref={body}
        onWheel={(e) => {
          e.stopPropagation();
          // An upward wheel is reader intent before scrollTop moves; drop any owed auto-scroll.
          if (e.deltaY < 0 && pinFrame.current != null) { cancelAnimationFrame(pinFrame.current); pinFrame.current = null; }
        }}
        onScroll={(e) => {
          const el = e.currentTarget;
          // Our own pin and growth reflows raise scroll events without moving the reader, so only a
          // changed position counts. Comparing against the previous position, not a pinned bottom,
          // keeps a return to that same bottom from looking like our own write.
          if (lastTop.current === el.scrollTop) return;
          lastTop.current = el.scrollTop;
          follow.current = el.scrollHeight - el.scrollTop - el.clientHeight < 32;
          if (!follow.current && pinFrame.current != null) {
            cancelAnimationFrame(pinFrame.current); pinFrame.current = null;
          }
        }}
      >
        {/* The link row is not among the native canvas rows, so the root appears here exactly once. */}
        <Row
          key={`root:${root.id}`}
          row={root}
          streaming={false}
          readOnly={snapshot.readOnly}
          highlighted={false}
          reduceMotion={snapshot.reduceMotion}
        />
        {items.map((row) => (
          <Row
            key={row.id}
            row={row}
            streaming={snapshot.streaming === row.id}
            readOnly={snapshot.readOnly}
            highlighted={snapshot.highlighted === row.id}
            reduceMotion={snapshot.reduceMotion}
          />
        ))}
      </div>
      <footer className="conversation-form">
        {(responding || stopReason) && (
          <div className="conversation-footer-status">
            {responding && (
              <span className={`conversation-status${waiting ? " waiting" : ""}`} role="status">
                {statusText}
              </span>
            )}
            {stopReason && <span className="conversation-stop-reason" role="status">{stopReason}</span>}
          </div>
        )}
        <div className="conversation-compose">
          <textarea
            rows={1}
            value={draft}
            placeholder="이 대화에 답장"
            aria-label="이 대화에 답장"
            disabled={snapshot.readOnly}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); send(); }
            }}
            onWheel={(e) => e.stopPropagation()}
          />
          {stoppable && !snapshot.readOnly ? (
            <button className="conversation-icon conversation-send" aria-label="답변 중지" title="답변 중지"
              onClick={() => post("canvasStop", root.id)}>
              <span className="action-symbol symbol-stop" aria-hidden="true" />
            </button>
          ) : (
            <button className="conversation-icon conversation-send" aria-label="보내기" title="보내기"
              disabled={snapshot.readOnly || waiting || !draft.trim()} onClick={send}>
              <span className="action-symbol symbol-send" aria-hidden="true" />
            </button>
          )}
        </div>
        {error && <p className="conversation-error" role="status">{error}</p>}
      </footer>
    </div>
  );
}

/** The same conversation when collapsed: one line that reopens the canvas in place. */
function ConversationCard({
  root,
  summary,
  responding,
  seenAt,
  active,
  onOpen,
}: {
  root: RowData;
  summary?: ConversationSummary;
  responding: boolean;
  seenAt: number;
  /** The docked panel currently shows this conversation. */
  active: boolean;
  onOpen: () => void;
}) {
  const unread = (summary?.replyAts ?? []).filter((at) => at > seenAt).length;
  const state = responding ? "응답 중" : unread > 0 ? `새 답변 ${unread}개` : summary?.replyAts.length ? "답변 완료" : "답변 없음";
  return (
    <div className={`conversation-card user-content${active ? " active" : ""}`}>
      <button className="conversation-card-open" onClick={onOpen} title={root.text}
        aria-label={`집중 대화 펼치기: ${root.text}`} aria-expanded={active}>
        <span className={`conversation-dot${responding ? " live" : ""}`} aria-hidden="true" />
        <span className="conversation-card-title">{root.text}</span>
        <span className="conversation-card-state">{state}</span>
        <span className="conversation-card-time">{summary?.time ?? root.time}</span>
      </button>
    </div>
  );
}

/** One generated work report: numbers from saved data, its detail, and a retry when analysis failed. */
export function ReportCard({ row, readOnly, isMobile = false }: { row: RowData; readOnly: boolean; isMobile?: boolean }) {
  const report = row.report;
  if (!report) return <ArchivedMessage row={row} />;
  return (
    <aside className={`report-card tone-${report.state === "failed" ? "amber" : "accent"}`} data-report={report.id}>
      <div className="meta">{report.title} · {row.time}</div>
      <strong>{report.title}</strong>
      <ul className="report-lines">
        {report.lines.map((line, i) => <li key={i}>{line}</li>)}
      </ul>
      {report.error && <p className="report-error" role="status">{report.error}</p>}
      {isMobile ? (
        <p className="meta">보고서 상세는 맥의 기록 탭에서 열 수 있어요</p>
      ) : (
        <div className="actions">
          <button disabled={readOnly || report.state === "pending" || report.state === "generating"}
            onClick={() => post("reportOpen", row.id, { report: report.id })}>
            {report.state === "generating" ? "분석 중" : "보고서 열기"}
          </button>
          {report.state === "failed" && report.retryable && (
            <button disabled={readOnly || report.busy} onClick={() => post("reportRetry", row.id, { report: report.id })}>
              다시 시도
            </button>
          )}
        </div>
      )}
    </aside>
  );
}

function Activity({ row, live }: { row: RowData; live: boolean }) {
  const activity = row.activity!;
  const running = live && activity.state === "running";
  const now = useActivityClock(running);
  const seconds = Math.max(0, Math.floor(((running ? now : activity.updatedAt) - activity.startedAt) / 1000));
  return (
    <section className={`progress-entry activity-${activity.state}`} aria-label={activity.title}>
      <div className="meta">
        <span>{activity.title}</span> · <span>{activity.label}</span> · {seconds}초
        <time className="activity-time">{new Date(activity.startedAt).toLocaleTimeString("ko-KR", { hour: "2-digit", minute: "2-digit", second: "2-digit" })}</time>
      </div>
      {activity.kind === "reasoning" && (
        <div className="activity-body"><Markdown id={row.id} text={row.text} /></div>
      )}
    </section>
  );
}
function Progress({ group, snapshot, onToggle }: { group: ProgressGroup; snapshot: Snapshot; onToggle: () => void }) {
  const [expanded, setExpanded] = useSaved(group.id, "progress-expanded", false);
  const now = useActivityClock(group.running);
  const seconds = Math.max(0, Math.floor(((group.running ? now : group.endedAt) - group.startedAt) / 1000));
  const duration = seconds < 60 ? `${seconds}초` : `${Math.floor(seconds / 60)}분 ${seconds % 60}초`;
  const target = snapshot.target && group.ids.includes(snapshot.target);
  useEffect(() => { if (target) setExpanded(true); }, [snapshot.target]);
  return (
    <article className="message progress-group" data-message={group.id}>
      <details open={expanded} onToggle={event => {
        const open = event.currentTarget.open;
        if (open !== expanded) { onToggle(); setExpanded(open); }
      }}>
        <summary aria-label={`진행 기록 · ${group.title} · ${group.label} · ${duration}`} aria-expanded={expanded}>
          <span>{group.running && group.title === "진행 기록" ? snapshot.status : group.title}</span><span className="muted"> · {group.label} · {duration}</span>
        </summary>
        {expanded && <div className="progress-records">
          {group.ids.map(id => {
            const row = rows[id];
            if (!row) return null;
            return <div key={id} data-message={id} className={`progress-record${row.activity ? " activity" : ""}${snapshot.highlighted === id ? " highlighted" : ""}`}>
              {row.activity ? <Activity row={row} live={group.running} /> :
                <section className="progress-entry"><div className="meta">진행 안내 · {row.time}</div>
                  <div className="activity-body"><Markdown id={id} text={row.text} /></div></section>}
            </div>;
          })}
        </div>}
      </details>
    </article>
  );
}
function ResponseStatus({ snapshot }: { snapshot: Snapshot }) {
  const grouped = Object.values(snapshot.progress?.groups ?? {}).some(group => group.running);
  const latest = rows[snapshot.order.at(-1) ?? ""]?.activity;
  const duplicate = latest?.kind === "tool" && latest.state === "running" && snapshot.status === `${latest.title} 진행 중`;
  const now = useActivityClock(snapshot.responding && !duplicate && !grouped);
  if (duplicate || grouped) return null;
  const elapsed = snapshot.responseStartedAt == null ? null : Math.max(0, Math.floor((now - snapshot.responseStartedAt) / 1000));
  return <span className="responding">{snapshot.status}{elapsed != null && ` · ${elapsed}초`}</span>;
}
export function ArchivedMessage({ row }: { row: RowData }) {
  return <section className="archived-message"><div className="meta">{row.title} · {row.time}</div><Markdown id={row.id} text={row.text} /></section>;
}
export function Copy({ id }: { id: string }) {
  const [feedback, setFeedback] = useState<"copied" | "failed" | null>(null);
  const timer = useRef<number | undefined>(undefined);
  const pending = useRef<string | null>(null);
  useEffect(() => {
    const result = (event: Event) => {
      const detail = (event as CustomEvent).detail;
      if (detail.message !== id || !pending.current || detail.request !== pending.current) return;
      pending.current = null;
      clearTimeout(timer.current);
      setFeedback(detail.error ? "failed" : "copied");
      timer.current = window.setTimeout(() => setFeedback(null), 1500);
    };
    window.addEventListener("knarr-result", result);
    return () => {
      window.removeEventListener("knarr-result", result);
      clearTimeout(timer.current);
      pending.current = null;
    };
  }, [id]);
  const copied = feedback === "copied";
  const label = copied ? "복사됨" : "복사";
  return (
    <>
      <button
        className={`copy message-action${copied ? " copied" : ""}`}
        aria-label={label}
        title={label}
        onClick={() => {
          clearTimeout(timer.current);
          setFeedback(null);
          const request = crypto.randomUUID();
          pending.current = request;
          post("copy", id, { request });
        }}
      >
        <span className={`action-symbol ${copied ? "symbol-check" : "symbol-copy"}`} aria-hidden="true" />
      </button>
      <span className="action-status" role="status">
        {copied ? "복사됨" : feedback === "failed" ? "복사하지 못했어요. 다시 시도해 주세요." : ""}
      </span>
    </>
  );
}
function LiveLabel({ issue }: { issue: NonNullable<RowData["issue"]> }) {
  const [now, setNow] = useState(Date.now());
  const running = issue.hirds.some((h) =>
    ["working", "waiting"].includes(h.state),
  );
  useEffect(() => {
    if (!running) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [running]);
  const h =
    issue.state === "running"
      ? (issue.hirds
          .filter((h) => h.state === "working")
          .sort((a, b) => b.since - a.since)[0] ?? issue.hirds.at(-1))
      : issue.hirds.at(-1);
  if (!h) return null;
  const seconds = Math.max(0, Math.floor((now - h.since) / 1000)),
    minutes = Math.floor(seconds / 60);
  const text =
    h.state === "working"
      ? seconds < 90
        ? `활동 ${seconds}초 전`
        : `${minutes}분째 조용함`
      : h.state === "waiting"
        ? `사람 기다림${minutes ? ` · ${minutes}분` : ""}`
        : `${new Date(h.since).toLocaleTimeString("ko-KR", { hour: "numeric", minute: "2-digit" })} ${h.state === "done" ? "끝남" : "중단"}`;
  return <span className={`live-label live-${h.state}`}>● {text}</span>;
}
function IssueCard({ row }: { row: RowData }) {
  const issue = row.issue;
  if (!issue) return null;
  return (
    <section className="issue-card">
      <div className="spread">
        <strong>{issue.title}</strong>
        <button className="link" onClick={() => post("open", row.id)}>
          이슈 열기
        </button>
      </div>
      <div className="meta">
        {issue.status} · <LiveLabel issue={issue} />
      </div>
      <div className="issue-progress">
        <div className="step-bar" aria-label="작업 단계">
          {issue.steps?.map((s, i) => (
            <span key={i} className={`step step-${s.state}`} title={s.title} />
          ))}
        </div>
        <span className="meta">
          {issue.criteriaSummary ?? `완료 조건 ${issue.total}개`}
        </span>
      </div>
    </section>
  );
}
function Proposal({ row, readOnly }: { row: RowData; readOnly: boolean }) {
  const p = row.proposal;
  const [note, setNote] = useSaved(row.id, "proposal-note", p?.note ?? "");
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    setSubmitted(false);
    setError("");
  }, [p?.version, p?.blockReason]);
  useEffect(() => {
    const handler = (e: Event) => {
      const d = (e as CustomEvent).detail;
      if (d.message === row.id && d.error) {
        setSubmitted(false);
        setError(d.error);
      }
    };
    window.addEventListener("knarr-result", handler);
    return () => window.removeEventListener("knarr-result", handler);
  }, [row.id]);
  const editable = !!p?.editable && !readOnly && !submitted;
  const decide = (action: string) => {
    if (!editable || !p) return;
    setSubmitted(true);
    post(action, row.id, { version: p.version, text: note });
  };
  return (
    <>
      <IssueCard row={row} />
      {p && (
        <section className="proposal" aria-label="제안 검토">
          <div className="meta">제안 v{p.version}</div>
          <p>{p.instruction.split("\n")[0]}</p>
          <input
            aria-label="수정 요청 또는 거절 메모"
            placeholder="수정 요청 또는 거절 메모"
            value={note}
            onChange={(e) => setNote(e.target.value)}
            disabled={!editable}
          />
          <div className="actions">
            <button
              className="primary"
              disabled={!editable || !!p.blockReason}
              onClick={() => decide("approve")}
            >
              승인
            </button>
            <button
              disabled={!editable || !note.trim()}
              onClick={() => decide("revise")}
            >
              수정 요청
            </button>
            <button
              className="danger"
              disabled={!editable}
              onClick={() => decide("reject")}
            >
              거절
            </button>
          </div>
          {(error || p.blockReason || submitted || p.note) && (
            <p role="status" className="meta">
              {error ||
                p.blockReason ||
                (submitted
                  ? "검토를 전달했어요"
                  : "수정 요청을 전달했어요 · 새 제안 대기")}
            </p>
          )}
          <details>
            <summary>작업 지시와 실행 설정</summary>
            <dl>
              <dt>모델</dt>
              <dd>{p.model}</dd>
              <dt>추론</dt>
              <dd>{p.thinking ?? "기본"}</dd>
              <dt>모드</dt>
              <dd>{p.mode}</dd>
              {p.previousRun && (
                <>
                  <dt>이전 실행</dt>
                  <dd>{p.previousRun}</dd>
                </>
              )}
            </dl>
            <p className="prewrap">{p.instruction}</p>
          </details>
        </section>
      )}
    </>
  );
}
export function Question({ row, readOnly, isMobile = false }: { row: RowData; readOnly: boolean; isMobile?: boolean }) {
  const q = row.question;
  const [draft, setDraft] = useSaved(row.id, "answer", {
    text: q?.prefill ?? "",
    selected: [] as string[],
  });
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    const fn = (e: Event) => {
      const d = (e as CustomEvent).detail;
      if (d.message === row.id && d.error) {
        setSubmitted(false);
        setError(d.error);
      }
    };
    window.addEventListener("knarr-result", fn);
    return () => window.removeEventListener("knarr-result", fn);
  }, [row.id]);
  useEffect(() => {
    if (isMobile && q?.status === "pending") { setSubmitted(false); setError(""); }
  }, [isMobile, q?.status]);
  if (!q) return null;
  if (q.status !== "pending")
    return (
      <p className="muted">
        {q.asker} · {q.summary}
      </p>
    );
  const disabled = readOnly || submitted,
    canSend = ["select", "confirm"].includes(q.style ?? "")
      ? draft.selected.length > 0
      : ["input", "editor"].includes(q.style ?? "")
        ? true
        : !!draft.text.trim() || draft.selected.length > 0;
  const toggle = (s: string) =>
    setDraft({
      ...draft,
      selected: draft.selected.includes(s)
        ? draft.selected.filter((v) => v !== s)
        : q.multiple
          ? [...draft.selected, s]
          : [s],
    });
  return (
    <section className="question callout tone-accent">
      <div className="meta">
        {isMobile ? "답변 필요" : `${q.asker}가 묻고 있어요`} · {row.time}
        {q.issueTitle && ` · ${q.issueTitle}`}
      </div>
      <p>{q.prompt}</p>
      <fieldset disabled={disabled}>
        <div className="choices">
          {q.options.map((s) => (
            <button
              key={s}
              aria-pressed={draft.selected.includes(s)}
              onClick={() => toggle(s)}
            >
              {s}
            </button>
          ))}
        </div>
        {!["select", "confirm"].includes(q.style ?? "") &&
          (q.style === "editor" ? (
            <textarea
              aria-label="답변"
              value={draft.text}
              onChange={(e) => setDraft({ ...draft, text: e.target.value })}
            />
          ) : (
            <input
              aria-label="답변"
              placeholder={
                q.placeholder ??
                (q.options.length ? "덧붙일 말 (선택)" : "답을 적어 주세요")
              }
              value={draft.text}
              onChange={(e) => setDraft({ ...draft, text: e.target.value })}
            />
          ))}
        <div className="actions">
          <button
            className="primary"
            disabled={!canSend}
            onClick={() => {
              setSubmitted(true);
              post("answer", row.id, {
                text: draft.text,
                selected: draft.selected,
              });
            }}
          >
            {isMobile ? "답변" : "보내기"}
          </button>
          <button
            onClick={() => {
              setSubmitted(true);
              post("cancelQuestion", row.id);
            }}
          >
            질문 닫기
          </button>
          {q.multiple && <span className="meta">여러 개 고를 수 있어요</span>}
        </div>
      </fieldset>
      {error && <p role="status">{error}</p>}
    </section>
  );
}
const Row = memo(function Row({
  row,
  streaming,
  readOnly,
  highlighted,
  reduceMotion,
}: {
  row: RowData;
  streaming: boolean;
  readOnly: boolean;
  highlighted: boolean;
  reduceMotion: boolean;
}) {
  let content: React.ReactNode;
  switch (row.kind) {
    case "user":
      content = (
        <div className="user-content">
          {row.attachments.length > 0 && (
            <div className="attachments">
              {row.attachments.map((name, i) => (
                <button
                  key={i}
                  onClick={() => post("preview", row.id, { index: i })}
                >
                  {row.attachmentImages?.[i]?.startsWith("chat-image://image/") &&
                    <img className="attachment-thumbnail" src={row.attachmentImages[i]} alt={name} />}
                  <span>{name}</span>
                </button>
              ))}
            </div>
          )}
          <div className="user-line">
            <div className="bubble">{row.text}</div>
            <div className="message-actions user-actions">
              <Copy key={`${env.session}:${row.id}`} id={row.id} />
              <button className="message-action" aria-label="수정" title="수정" disabled={readOnly} onClick={() => post("edit", row.id)}>
                <span className="action-symbol symbol-edit" aria-hidden="true" />
              </button>
              {!mobile && <button className="message-action conversation-action" aria-label="새 창에서 대화" title="새 창에서 대화"
                disabled={readOnly || !!row.conversationRootID} onClick={() => post("startConversation", row.id)}>
                새 창에서 대화
              </button>}
            </div>
          </div>
          {row.mainTransferID && (
            <button className="conversation-action" onClick={() => post("transferMain", row.id)}>
              메인으로 이동
            </button>
          )}
        </div>
      );
      break;
    case "pending":
      content = <div className="user-content">
        <div className="bubble">{row.text}{!!row.pendingCount && <span className="meta"> · 첨부 {row.pendingCount}</span>}</div>
        <div className="meta pending-status">전달 대기 <button className="link" onClick={() => post("cancelPending", row.id)}>취소</button></div>
      </div>;
      break;
    case "transfer":
      content = (
        <aside className="callout" data-transfer-receipt>
          <div className="meta">{row.time}</div>
          <strong>{row.title}</strong>
          <Markdown id={row.id} text={row.text} />
          <details><summary>원본 요청</summary><p>{row.request}</p></details>
          <div className="actions">
            <button onClick={() => post("transferSource", row.id)}>원본 요청으로 이동</button>
          </div>
        </aside>
      );
      break;
    case "activity":
      content = <Activity row={row} live={false} />;
      break;
    case "assistant":
      content = (
        <Assistant
          row={row}
          streaming={streaming}
          readOnly={readOnly}
          reduceMotion={reduceMotion}
        />
      );
      break;
    case "issue":
      content = <IssueCard row={row} />;
      break;
    case "proposal":
      content = <Proposal row={row} readOnly={readOnly} />;
      break;
    case "question":
      content = <Question row={row} readOnly={readOnly} isMobile={mobile} />;
      break;
    case "report":
      content = <ReportCard row={row} readOnly={readOnly} isMobile={mobile} />;
      break;
    case "archived":
      content = <ArchivedMessage row={row} />;
      break;
    case "notice":
      content = (
        <aside className={`callout tone-${row.tone}`}>
          <strong>{row.title}</strong>
          <Markdown id={row.id} text={row.text} />
          <div className="actions">
            {row.primary && (
              <button
                disabled={readOnly}
                onClick={() => post("noticePrimary", row.id)}
              >
                {row.primary}
              </button>
            )}
            <button onClick={() => post("open", row.id)}>
              {row.primary ? "이슈 보기" : "확인하기"}
            </button>
          </div>
        </aside>
      );
      break;
    case "autoCheck":
      content = (
        <details>
          <summary>{row.text}</summary>
          {row.lines?.map((line, i) => (
            <p key={i}>{line}</p>
          ))}
        </details>
      );
      break;
    case "day":
      content = <div className="day">{row.text}</div>;
      break;
  }
  return (
    <article
      className={`message ${row.kind}${highlighted ? " highlighted" : ""}`}
      data-message={row.id}
      data-role={row.kind === "assistant" && row.conversationRootID == null && !row.isConversationLink ? "assistant" : undefined}
    >
      {content}
    </article>
  );
});
function App() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  /** The focused conversation expanded in place; only one canvas is open at a time. */
  const [openRoot, setOpenRoot] = useState<string | null>(null);
  /** When each conversation was last read, for collapsed-card unread counts. */
  const [seen, setSeen] = useState<Record<string, number>>({});
  const seenRef = useRef<Record<string, number>>({});
  const openRootRef = useRef<string | null>(null);
  const baselined = useRef<Record<string, true>>({});
  const lastCanvasToken = useRef<string | null>(null);
  const viewport = useRef<HTMLDivElement>(null);
  const following = useRef(true);
  const userScrollUntil = useRef(0);
  const pointerScrolling = useRef(false);
  const layoutWidth = useRef(0);
  useEffect(() => {
    const end = () => {
      pointerScrolling.current = false;
      userScrollUntil.current = performance.now() + 200;
    };
    window.addEventListener("pointerup", end);
    window.addEventListener("pointercancel", end);
    return () => {
      window.removeEventListener("pointerup", end);
      window.removeEventListener("pointercancel", end);
    };
  }, []);
  const pendingAnchor = useRef<Saved | null>(null);
  const readerAnchor = useRef<Saved | null>(null);
  const readerWidth = useRef(0);
  const lastTarget = useRef<string | null>(null);
  const lastSnapshot = useRef<Snapshot | null>(null);
  const virtual = useVirtualizer({
    count: snapshot?.progress?.order.length ?? 0,
    getScrollElement: () => viewport.current,
    estimateSize: () => 120,
    overscan: 6,
    getItemKey: (i) => snapshot?.progress?.order[i] ?? i,
  });
  const capture = useCallback(() => {
    const el = viewport.current;
    if (!el) return null;
    const top = el.getBoundingClientRect().top;
    const mounted = [...el.querySelectorAll<HTMLElement>("[data-message]")];
    const start =
      mounted.find(
        (item) =>
          item.getBoundingClientRect().top >= top &&
          item.getBoundingClientRect().top < top + el.clientHeight,
      ) ??
      mounted.find(
        (item) =>
          item.getBoundingClientRect().bottom > top &&
          item.getBoundingClientRect().top < top + el.clientHeight,
      );
    return {
      following: following.current,
      anchor: start?.dataset.message,
      offset: start ? top - start.getBoundingClientRect().top : 0,
    };
  }, [virtual]);
  const restoreReader = useCallback((anchor: Saved | null) => {
    const el = viewport.current;
    if (!el || !anchor?.anchor) return false;
    const item = [...el.querySelectorAll<HTMLElement>("[data-message]")].find(
      (e) => e.dataset.message === anchor.anchor,
    );
    if (!item) return false;
    const delta =
      item.getBoundingClientRect().top -
      el.getBoundingClientRect().top +
      (anchor.offset ?? 0);
    if (Math.abs(delta) > 0.5) el.scrollTop += delta;
    return true;
  }, []);
  useLayoutEffect(() => {
    receive = (next) => {
      pendingAnchor.current = next.reset ? next.viewport : capture();
      if (next.reset) {
        rows = {};
        saved = {};
        following.current = next.viewport?.following ?? true;
        lastTarget.current = null;
        readerAnchor.current = next.viewport;
        readerWidth.current = viewport.current?.clientWidth ?? 0;
      }
      env = { session: next.session, thread: next.thread, conversationRootID: next.conversationRootID ?? null };
      mobile = next.mobile === true;
      document.documentElement.dataset.mobile = String(mobile);
      rows = applyPatch(rows, next);
      next = { ...next, order: next.order.filter(id => next.conversationRootID
        ? rows[id]?.conversationRootID === next.conversationRootID
        : !rows[id]?.conversationRootID) };
      for (const [id, row] of Object.entries(next.upsert))
        if (!saved[id]) saved[id] = row.state ?? {};
      for (const id of next.removed) delete saved[id];
      for (const [k, v] of Object.entries(next.theme))
        document.documentElement.style.setProperty("--" + k, v);
      document.documentElement.style.colorScheme = next.dark ? "dark" : "light";
      document.documentElement.dataset.reduceMotion = String(next.reduceMotion);
      // A newly linked conversation starts read: only replies that arrive after this count as new.
      let baseline: Record<string, number> | null = null;
      for (const [id, summary] of Object.entries(next.summaries ?? {}))
        if (!baselined.current[id]) {
          baselined.current[id] = true;
          (baseline ??= {})[id] = summary.at;
        }
      if (baseline) {
        seenRef.current = { ...baseline, ...seenRef.current };
        setSeen(seenRef.current);
      }
      const request = next.canvasRequest;
      if (request && request.token !== lastCanvasToken.current) {
        lastCanvasToken.current = request.token;
        openRootRef.current = request.root;
        setOpenRoot(request.root);
        post("canvasOpen", request.root);
      }
      if (next.jump) following.current = true;
      next.progress = groupProgress(next.order, rows, next.responding, next.responseStartedAt, next.mobile === true);
      lastSnapshot.current = next;
      setSnapshot(next);
    };
    window.knarr.ready = true;
    post("ready");
    return () => {
      window.knarr.ready = false;
      receive = () => {};
    };
  }, [capture]);
  useLayoutEffect(() => {
    if (!snapshot || !viewport.current) return;
    let timer = 0;
    let attempts = 0;
    const go = () => {
      const el = viewport.current;
      if (!el) return;
      if (snapshot.target && snapshot.target !== lastTarget.current) {
        const index = snapshot.progress!.order.indexOf(snapshot.progress!.owner[snapshot.target] ?? snapshot.target);
        if (index >= 0) {
          following.current = false;
          readerAnchor.current = null;
          const mounted = el.querySelector<HTMLElement>(`.virtual-row[data-index="${index}"]`);
          if (!mounted) virtual.scrollToIndex(index, { align: "start" });
          const reveal = () => {
            const target = [...el.querySelectorAll<HTMLElement>("[data-message]")]
              .find(item => item.dataset.message === snapshot.target);
            const wrapper = target?.closest<HTMLElement>(".virtual-row");
            if (!target || !wrapper) {
              if (++attempts < 30) timer = window.setTimeout(reveal, 16);
              return;
            }
            // Expanding a group changes its virtual height. Measure it before scrolling
            // inside it; scrollToIndex would otherwise re-center the whole tall group.
            virtual.measureElement(wrapper);
            timer = window.setTimeout(() => {
              el.scrollTop += target.getBoundingClientRect().top - el.getBoundingClientRect().top - el.clientHeight / 2;
              lastTarget.current = snapshot.target;
              readerAnchor.current = capture();
              readerWidth.current = el.clientWidth;
              post("targetReached", undefined, { target: snapshot.target });
            });
          };
          // WKWebView pauses animation frames while its window is hidden.
          // A bounded task also restores search targets before that window is shown.
          timer = window.setTimeout(reveal, 0);
        }
        return;
      }
      if (!snapshot.target) lastTarget.current = null;
      if (following.current) {
        el.scrollTop = el.scrollHeight;
      } else if (
        pendingAnchor.current ||
        readerWidth.current !== el.clientWidth
      ) {
        const anchor = readerAnchor.current ?? pendingAnchor.current;
        if (anchor?.anchor && !restoreReader(anchor)) {
          const index = snapshot.progress!.order.indexOf(snapshot.progress!.owner[anchor.anchor] ?? anchor.anchor);
          if (index >= 0) virtual.scrollToIndex(index, { align: "start" });
        }
        readerAnchor.current = anchor;
      }
      pendingAnchor.current = null;
    };
    go();
    return () => clearTimeout(timer);
  }, [
    snapshot,
    virtual,
    virtual.getTotalSize(),
    virtual.range?.startIndex,
    restoreReader,
  ]);
  useEffect(() => {
    const el = viewport.current;
    if (!el) return;
    let frame = 0;
    const observer = new ResizeObserver(() => {
      const resized = layoutWidth.current !== el.clientWidth;
      layoutWidth.current = el.clientWidth;
      if (following.current) {
        el.scrollTop = el.scrollHeight;
      } else if (
        resized ||
        (!pointerScrolling.current &&
          performance.now() >= userScrollUntil.current)
      ) {
        restoreReader(readerAnchor.current);
      }
    });
    const content = el.firstElementChild;
    if (content) observer.observe(content);
    observer.observe(el);
    return () => {
      observer.disconnect();
      cancelAnimationFrame(frame);
    };
  }, [snapshot?.thread, snapshot?.conversationRootID]);
  /** Expansion marks the conversation read and asks native for that root's rows. */
  const markSeen = useCallback((root: string) => {
    const now = Date.now();
    if ((seenRef.current[root] ?? 0) >= now) return;
    seenRef.current = { ...seenRef.current, [root]: now };
    setSeen(seenRef.current);
    save(root, "conversation-read-at", now);
  }, []);
  const openCanvas = useCallback((root: string) => {
    markSeen(root);
    openRootRef.current = root;
    setOpenRoot(root);
    post("canvasOpen", root);
  }, [markSeen]);
  const closeCanvas = useCallback(() => {
    const root = openRootRef.current;
    if (!root) return;
    openRootRef.current = null;
    setOpenRoot(null);
    post("canvasClose");
  }, []);
  const onScroll = () => {
    const el = viewport.current;
    if (!el) return;
    if (
      (pointerScrolling.current ||
        performance.now() < userScrollUntil.current) &&
      (readerWidth.current === 0 || readerWidth.current === el.clientWidth)
    ) {
      following.current = el.scrollHeight - el.scrollTop - el.clientHeight < 64;
      readerAnchor.current = capture();
    }
    post("viewport", undefined, { state: capture() ?? { following: true } });
    scheduleVisibleReport();
  };
  /** The visible-answer signature last posted, so scrolling within read rows never repeats a batch. */
  const reportedSignature = useRef("");
  const reportFrame = useRef(0);
  /**
   * Reports the answers the person can actually see. Only mounted virtual rows are inspected, so
   * this never walks the whole transcript. App activity is not judged here: the native store
   * refuses a read while the app is inactive, and it re-checks the thread and every id. `force`
   * re-posts after activation or a new render even when the same rows are visible.
   */
  const reportVisibleAnswers = useCallback((force: boolean) => {
    reportFrame.current = 0;
    const el = viewport.current;
    if (!el || env.conversationRootID) return;
    const top = el.getBoundingClientRect().top,
      bottom = top + el.clientHeight;
    const ids: string[] = [];
    for (const node of el.querySelectorAll<HTMLElement>('[data-role="assistant"]')) {
      const rect = node.getBoundingClientRect();
      if (rect.height <= 0 || rect.bottom <= top || rect.top >= bottom) continue;
      const visible = Math.min(rect.bottom, bottom) - Math.max(rect.top, top);
      if (visible < Math.min(rect.height, 48) * 0.6) continue;
      const id = node.dataset.message;
      if (id) ids.push(id);
    }
    const signature = ids.join(",");
    if (!ids.length || (!force && signature === reportedSignature.current)) return;
    reportedSignature.current = signature;
    post("answersSeen", undefined, { ids });
  }, []);
  const scheduleVisibleReport = useCallback(() => {
    if (reportFrame.current) return;
    reportFrame.current = requestAnimationFrame(() => reportVisibleAnswers(false));
  }, [reportVisibleAnswers]);
  // A new projection or a different set of mounted virtual rows changes what is visible; a scroll
  // alone may only mount rows, so the reported range must also schedule a re-check.
  useLayoutEffect(() => {
    if (!snapshot) return;
    const timer = window.setTimeout(() => reportVisibleAnswers(true), 120);
    return () => window.clearTimeout(timer);
  }, [snapshot, virtual.range?.startIndex, virtual.range?.endIndex, reportVisibleAnswers]);
  useEffect(() => {
    reportedSignature.current = "";
    window.addEventListener("focus", scheduleVisibleReport);
    document.addEventListener("visibilitychange", scheduleVisibleReport);
    // Native calls this when the app becomes active. The same rows must be posted again: the store
    // refused them while it was inactive, so the page's last signature cannot be reused.
    window.knarr.recheckVisibility = () => reportVisibleAnswers(true);
    return () => {
      window.removeEventListener("focus", scheduleVisibleReport);
      document.removeEventListener("visibilitychange", scheduleVisibleReport);
      delete window.knarr.recheckVisibility;
      if (reportFrame.current) cancelAnimationFrame(reportFrame.current);
      reportFrame.current = 0;
    };
  }, [scheduleVisibleReport]);
  return (
    <div className="chat-shell">
      <div
        className="viewport"
        ref={viewport}
        onScroll={onScroll}
        onWheel={(e) => {
          readerWidth.current = viewport.current?.clientWidth ?? 0;
          userScrollUntil.current = performance.now() + 1000;
          if (e.deltaY < 0) following.current = false;
        }}
        onPointerDown={() => {
          pointerScrolling.current = true;
          readerWidth.current = viewport.current?.clientWidth ?? 0;
          userScrollUntil.current = performance.now() + 1000;
        }}
        onKeyDown={(e) => {
          if (
            [
              "ArrowUp",
              "ArrowDown",
              "PageUp",
              "PageDown",
              "Home",
              "End",
              " ",
            ].includes(e.key)
          ) {
            readerWidth.current = viewport.current?.clientWidth ?? 0;
            userScrollUntil.current = performance.now() + 1000;
          }
        }}
        role="log"
        aria-label="대화 기록"
        aria-live="off"
      >
        <div className="transcript">
          {snapshot && (
            <>
              <div
                className="virtual-list"
                style={{ height: virtual.getTotalSize() }}
              >
                {virtual.getVirtualItems().map((item) => {
                  const id = snapshot.progress!.order[item.index],
                    row = rows[id];
                  return row ? (
                    <div
                      key={`${snapshot.thread}:${id}`}
                      data-index={item.index}
                      ref={virtual.measureElement}
                      className="virtual-row"
                      style={{ transform: `translateY(${item.start}px)` }}
                    >
                      {snapshot.progress!.groups[id] ? <Progress
                        key={`${snapshot.session}:${id}`}
                        group={snapshot.progress!.groups[id]}
                        snapshot={snapshot}
                        onToggle={() => {
                          following.current = false;
                          readerAnchor.current = capture();
                          readerWidth.current = viewport.current?.clientWidth ?? 0;
                        }}
                      /> : row.isConversationLink && !row.conversationRootID ? (
                        <ConversationCard
                          key={`${snapshot.session}:${id}:card`}
                          root={row}
                          summary={snapshot.summaries?.[id]}
                          responding={snapshot.respondingRoots?.includes(id) ?? false}
                          seenAt={seen[id] ?? 0}
                          active={openRoot === id}
                          onOpen={() => openCanvas(id)}
                        />
                      ) : <Row
                        row={row}
                        streaming={snapshot.streaming === id}
                        readOnly={snapshot.readOnly}
                        highlighted={snapshot.highlighted === id}
                        reduceMotion={snapshot.reduceMotion}
                      />}
                    </div>
                  ) : null;
                })}
              </div>
              <div className="response-footer">
                {snapshot.footerText && (
                  <div className="markdown">
                    <Markdown
                      id={snapshot.order.at(-1) ?? ""}
                      text={snapshot.footerText}
                    />
                  </div>
                )}
                <div className="response-slot" role="status">
                  {snapshot.responding ? (
                    <ResponseStatus snapshot={snapshot} />
                  ) : snapshot.status === "중지됨" ? (
                    <>
                      <span>응답 중지됨</span>
                      {snapshot.canResend && (
                        <button className="link" onClick={() => post("resend")}>
                          다시 보내기
                        </button>
                      )}
                    </>
                  ) : null}
                </div>
              </div>
            </>
          )}
        </div>
      </div>
      {/* The panel sits outside the scroll area: it keeps its own scroll and the main conversation
          above it never moves when the panel opens, closes or streams. */}
      {snapshot && openRoot && rows[openRoot] && (
        <div className="conversation-dock">
          <MessageConversationCanvas
            key={`${snapshot.session}:${openRoot}:canvas`}
            root={rows[openRoot]}
            data={snapshot.canvas ?? null}
            snapshot={snapshot}
            onSeen={() => markSeen(openRoot)}
            onClose={closeCanvas}
            onWindow={() => post("canvasWindow", openRoot)}
          />
        </div>
      )}
    </div>
  );
}
const rootElement = document.getElementById("root");
if (rootElement) createRoot(rootElement).render(<App />);
