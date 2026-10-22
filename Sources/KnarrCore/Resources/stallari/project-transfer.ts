// Knarr-owned extension for the pinned OMP 18.7.0 public extension API.
// No filesystem, database, network, execution approval, or arbitrary invokeTool access.
import type { ExtensionAPI, ExtensionContext, ExtensionCommandContext } from "@oh-my-pi/pi-coding-agent";
const BRIDGE = "knarr_project_transfer_bridge_v1";
const INPUT = "knarr.project-transfer.bridge.v1";
const RECEIPT = "knarr.project-transfer.v1";
const LIMIT = 128 * 1024;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const bytes = (value: string) => new TextEncoder().encode(value).length;

function record(value: unknown): asserts value is Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Expected a JSON object");
}
function keys(value: Record<string, unknown>, allowed: string[], required = allowed) {
  if (Object.keys(value).some(key => !allowed.includes(key)) || required.some(key => !Object.hasOwn(value, key))) {
    throw new Error("Unexpected or missing transfer fields");
  }
}
function text(value: unknown, maximum: number, name: string): asserts value is string {
  if (typeof value !== "string" || !value.trim() || bytes(value) > maximum || value.includes("\u0000")) {
    throw new Error(`Invalid ${name}`);
  }
}
function identifier(value: unknown, name: string): asserts value is string { text(value, 256, name); }
function messageID(value: unknown): asserts value is string {
  if (typeof value !== "string" || !uuid.test(value)) throw new Error("Invalid saved message UUID");
}
function messageIDs(value: unknown): asserts value is string[] {
  if (!Array.isArray(value) || value.length < 1 || value.length > 100) throw new Error("Expected 1…100 saved message IDs");
  value.forEach(messageID);
  if (new Set(value.map(id => id.toLowerCase())).size !== value.length) throw new Error("Duplicate saved message IDs");
}
// Key order is irrelevant; array order, values, and every nested field remain exact.
function canonical(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value) ?? "null";
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  record(value);
  return "{" + Object.keys(value).sort().map(key => JSON.stringify(key) + ":" + canonical(value[key])).join(",") + "}";
}
function validatePayload(value: unknown) {
  record(value); keys(value, ["transferID", "details", "content"]);
  identifier(value.transferID, "transferID"); text(value.content, LIMIT, "content");
  const d = value.details;
  record(d); keys(d, ["protocolVersion", "transferID", "originProjectID", "originThreadID", "projectName", "requestMessageID", "requestText", "summary", "messageIDs", "attachments"]);
  if (d.protocolVersion !== 1 || d.transferID !== value.transferID) throw new Error("Transfer protocol or identity mismatch");
  identifier(d.originProjectID, "originProjectID"); identifier(d.originThreadID, "originThreadID");
  if (d.originThreadID === "default") throw new Error("A transfer must originate in a project conversation");
  text(d.projectName, LIMIT, "projectName"); messageID(d.requestMessageID);
  text(d.requestText, LIMIT, "requestText"); text(d.summary, LIMIT, "summary"); messageIDs(d.messageIDs);
  if (!d.messageIDs.includes(d.requestMessageID)) throw new Error("Saved request must be referenced");
  if (!Array.isArray(d.attachments) || d.attachments.length > 100) throw new Error("Too many attachments");
  const refs = new Set<string>();
  for (const attachment of d.attachments) {
    record(attachment); keys(attachment, ["messageID", "url"]); messageID(attachment.messageID);
    if (!d.messageIDs.includes(attachment.messageID)) throw new Error("Attachment is not part of the saved message references");
    text(attachment.url, 8192, "attachment URL");
    const url = new URL(attachment.url);
    if (url.protocol !== "file:" || url.username || url.password) throw new Error("Invalid saved attachment file URL");
    const ref = canonical(attachment);
    if (refs.has(ref)) throw new Error("Duplicate attachment reference");
    refs.add(ref);
  }
  return value;
}

export default function (pi: ExtensionAPI) {
  function supported(ctx: ExtensionContext) {
    if (process.env.KNARR_PROJECT_TRANSFER_BRIDGE !== "1" || !process.env.KNARR_STALLARI_THREAD_ID ||
        ctx.mode !== "rpc" || ctx.agent?.kind !== "main" ||
        typeof pi.getAllTools !== "function" || !pi.getAllTools().some(tool => tool.name === BRIDGE)) {
      throw new Error("unsupported: Upgrade the Knarr app bridge before installing this extension (knarr_project_transfer_bridge_v1 required)");
    }
  }
  async function bridge(ctx: ExtensionContext, arguments_: Record<string, unknown>, signal?: AbortSignal) {
    supported(ctx);
    const request = JSON.stringify(arguments_);
    if (bytes(request) > LIMIT) throw new Error("Transfer bridge arguments exceed 128 KiB");
    if (signal?.aborted) throw new Error("Transfer cancelled; delivery is not confirmed");
    const response = await ctx.ui.input(INPUT, request, { signal, timeout: 15000 });
    if (signal?.aborted || response === undefined) throw new Error("Transfer bridge cancelled or timed out; delivery is not confirmed");
    text(response, LIMIT, "bridge response");
    const envelope: unknown = JSON.parse(response); record(envelope);
    if (envelope.ok === false) {
      keys(envelope, ["ok", "error"]); text(envelope.error, LIMIT, "bridge error");
      throw new Error(envelope.error);
    }
    keys(envelope, ["ok", "result"]);
    if (envelope.ok !== true || envelope.result === null || typeof envelope.result !== "object" || Array.isArray(envelope.result)) {
      throw new Error("Invalid transfer bridge response; delivery is not confirmed");
    }
    return envelope.result;
  }
  pi.registerTool({
    name: "transfer_to_main", label: "Transfer project context to main",
    description: "Explicitly persist a project-to-main context transfer, not an issue or execution approval. action=context reads saved request/message references; enqueue requires a factual summary and optional saved requestMessageID/messageIDs; retry requires the existing transferID. Only fields relevant to the selected action are used. Omitted, null or empty references resolve to the latest saved user request/relevant saved messages; transferID is used only for retry. Enqueue only confirms persistence, never delivery. Main may be busy/offline. Original user request and assistant summary remain distinct untrusted context; no forced model turn.",
    parameters: pi.zod.object({
      action: pi.zod.enum(["context", "enqueue", "retry"]),
      summary: pi.zod.string().optional(), requestMessageID: pi.zod.string().optional(),
      messageIDs: pi.zod.array(pi.zod.string()).optional(), transferID: pi.zod.string().optional(),
    }).strict(),
    async execute(_id, params, signal, _onUpdate, ctx) {
      try {
        supported(ctx);
        if (process.env.KNARR_STALLARI_THREAD_ID === "default") throw new Error("Only a project conversation can transfer to main");
        record(params); keys(params, ["action", "summary", "requestMessageID", "messageIDs", "transferID"], ["action"]);
        const request: Record<string, unknown> = { operation: params.action };
        if (params.action === "context") {
          // Providers may populate every optional field in the shared tool schema.
          // Context is read-only and uses none of the enqueue/retry fields.
        } else if (params.action === "enqueue") {
          text(params.summary, LIMIT, "summary"); request.summary = params.summary;
          request.transferID = crypto.randomUUID();
          if (params.requestMessageID != null && params.requestMessageID !== "") { messageID(params.requestMessageID); request.requestMessageID = params.requestMessageID; }
          if (params.messageIDs != null && params.messageIDs.length !== 0) { messageIDs(params.messageIDs); request.messageIDs = params.messageIDs; }
        } else if (params.action === "retry") {
          identifier(params.transferID, "transferID"); request.transferID = params.transferID;
        } else throw new Error("Unknown transfer action");
        const result = await bridge(ctx, request, signal);
        return { content: [{ type: "text", text: JSON.stringify({ ok: true, result }) }], details: { ok: true, result } };
      } catch (error) {
        const message = error instanceof Error ? error.message : "Transfer bridge failed; delivery is not confirmed";
        return { isError: true, content: [{ type: "text", text: JSON.stringify({ ok: false, error: message }) }], details: { ok: false, error: message } };
      }
    },
  });

  let admissionTail: Promise<void> = Promise.resolve();
  async function admit(args: string, ctx: ExtensionCommandContext) {
    supported(ctx);
    if (process.env.KNARR_STALLARI_THREAD_ID !== "default") throw new Error("Only the default main conversation can admit a transfer");
    if (!ctx.isIdle() || ctx.hasPendingMessages()) throw new Error("Main is busy; keep the transfer pending and retry the same ID");
    if (args.length > Math.ceil(LIMIT / 3) * 4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(args)) {
      throw new Error("Invalid bounded transfer base64");
    }
    const raw = Buffer.from(args, "base64");
    if (raw.length > LIMIT || raw.toString("base64") !== args) throw new Error("Invalid transfer encoding");
    const payload = validatePayload(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)));
    const saved = await bridge(ctx, { operation: "admission", transferID: payload.transferID });
    if (canonical(saved) !== canonical(payload)) throw new Error("Transfer provenance does not match the app's persisted record");
    if (!ctx.isIdle() || ctx.hasPendingMessages()) throw new Error("Main became busy; keep the transfer pending and retry the same ID");
    const prior = ctx.sessionManager.getEntries().filter(entry => {
      if (entry.type !== "custom_message" || entry.customType !== RECEIPT) return false;
      const details = entry.details;
      return details !== null && typeof details === "object" && "transferID" in details && details.transferID === payload.transferID;
    });
    if (prior.some(entry => canonical(entry.details) !== canonical(payload.details))) throw new Error("Transfer identity already exists with different details");
    if (prior.length) return;
    // Public sendMessage is void. Wait for its session entry before releasing
    // this serialized admission; the app separately confirms get_entries.
    pi.sendMessage({ customType: RECEIPT, content: payload.content, display: true, details: payload.details }, { triggerTurn: false });
    const deadline = Date.now() + 2000;
    while (!ctx.sessionManager.getEntries().some(entry => entry.type === "custom_message" && entry.customType === RECEIPT && canonical(entry.details) === canonical(payload.details))) {
      if (Date.now() >= deadline) throw new Error("Transfer receipt not observed; keep pending and retry the same ID");
      await new Promise<void>(resolve => setTimeout(resolve, 10));
    }
  }
  pi.registerCommand("knarr-project-transfer-admit", {
    description: "App-only main-session context admission v1; never execution approval or a model turn",
    handler: async (args, ctx) => {
      const admission = admissionTail.then(() => admit(args, ctx));
      admissionTail = admission.catch(() => {});
      await admission;
    },
  });
}
