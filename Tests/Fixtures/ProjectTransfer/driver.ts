// Test-only local provider: the real pinned OMP agent executes registered tools.
// streamSimple never opens a connection or reads credentials.
import { createAssistantMessageEventStream } from "@oh-my-pi/pi-ai";
import { fileURLToPath } from "node:url";

type ReceiptEntry = { type?: string; customType?: string; details?: { transferID?: string; attachments?: { url?: string }[] } };

export default function (pi) {
  let notify: ((metadata: string) => void) | undefined;
  let receiptEntries: () => readonly ReceiptEntry[] = () => [];
  pi.on("session_start", (_event, ctx) => {
    receiptEntries = () => ctx.sessionManager.getEntries();
    notify = metadata => ctx.ui.notify("knarr-transfer-fixture:" + metadata, "info");
  });
  pi.registerTool({
    name: "knarr_transfer_fixture_wait", label: "Bounded fixture wait",
    description: "Test-only bounded idle/busy transition", parameters: pi.zod.object({}),
    async execute(_id, _params, signal) {
      await new Promise<void>(resolve => {
        const finish = () => { clearTimeout(timer); signal?.removeEventListener("abort", finish); resolve(); };
        const timer = setTimeout(finish, 3000);
        signal?.addEventListener("abort", finish, { once: true });
        if (signal?.aborted) finish();
      });
      return { content: [{ type: "text", text: "FIXTURE_WAIT_COMPLETE" }] };
    },
  });
  pi.registerCommand("knarr-transfer-fixture-tools", {
    description: "Test-only explicit deterministic tool selection",
    handler: async () => {
      await pi.setActiveTools([...new Set([...pi.getActiveTools(), "transfer_to_main", "knarr_transfer_fixture_wait"])]);
    },
  });
  pi.registerProvider("knarr-transfer-fixture", {
    baseUrl: "http://127.0.0.1:1", apiKey: "fixture-not-a-credential", api: "knarr-transfer-test-api",
    models: [{ id: "deterministic", name: "Knarr transfer deterministic fixture", reasoning: false,
      input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200000, maxTokens: 2048 }],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        const last = context.messages.at(-1);
        const text = typeof last?.content === "string" ? last.content : (last?.content ?? []).map(item => item.text ?? "").join("\n");
        const markerStart = text.indexOf("TRANSFER_TOOL ");
        const markerEnd = markerStart < 0 ? -1 : text.indexOf("\nTRANSFER_TOOL_END", markerStart);
        const isTransfer = last?.role === "user" && markerStart >= 0 && markerEnd >= 0;
        const readStart = text.indexOf("TRANSFER_READ_RECEIPT ");
        const readEnd = readStart < 0 ? -1 : text.indexOf("\nTRANSFER_READ_RECEIPT_END", readStart);
        const wantsRead = last?.role === "user" && readStart >= 0 && readEnd >= 0;
        const readID = wantsRead ? text.slice(readStart + "TRANSFER_READ_RECEIPT ".length, readEnd) : "";
        // The prompt selects a receipt ID, never a path. Read only its exact persisted attachment URL.
        const receipt = wantsRead && process.env.KNARR_STALLARI_THREAD_ID === "default" && /^[0-9a-f-]{36}$/i.test(readID)
          ? receiptEntries().find(entry => entry.type === "custom_message" && entry.customType === "knarr.project-transfer.v1" &&
              entry.details?.transferID === readID && entry.details.attachments?.length === 1)
          : undefined;
        const attachmentURL = receipt?.details?.attachments?.[0]?.url;
        const nativeRead = context.tools?.some(item => item.name === "read") === true;
        const canRead = wantsRead && attachmentURL?.startsWith("file:") && nativeRead;
        const readFailure = wantsRead && !canRead
          ? attachmentURL ? "TRANSFER_ATTACHMENT_READ_UNAVAILABLE" : "TRANSFER_ATTACHMENT_REFERENCE_MISSING"
          : undefined;
        const tool = isTransfer ? "transfer_to_main" : canRead ? "read"
          : last?.role === "user" && text.includes("TRANSFER_HOLD") ? "knarr_transfer_fixture_wait" : undefined;
        const args = isTransfer ? JSON.parse(text.slice(markerStart + "TRANSFER_TOOL ".length, markerEnd))
          : canRead ? { path: fileURLToPath(attachmentURL) } : {};
        notify?.(JSON.stringify({
          role: ["user", "assistant", "toolResult"].includes(last?.role) ? last.role : "other",
          markerPresent: markerStart >= 0 || readStart >= 0, markerEndPresent: markerEnd >= 0 || readEnd >= 0, selectedTool: tool ?? "none",
        }));
        const hasReceipt = context.messages.some(item => {
          const content = typeof item.content === "string" ? item.content : (item.content ?? []).map(part => part.text ?? "").join("\n");
          return content.includes("PERSISTED_REQUEST_NOT_APPROVAL");
        });
        const message = {
          role: "assistant", api: model.api, provider: model.provider, model: model.id,
          content: tool ? [{ type: "toolCall", id: "transfer-fixture-" + Date.now(), name: tool, arguments: args }]
            : [{ type: "text", text: readFailure ?? (last?.role === "toolResult"
                ? (last.toolName === "read" ? "TRANSFER_ATTACHMENT_READ_RESULT " : "TRANSFER_RESULT ") + text
                : `TRANSFER_CONTINUES receipt=${hasReceipt}`) }],
          stopReason: tool ? "toolUse" : "stop", timestamp: Date.now(),
          usage: { input: 10, output: 10, cacheRead: 0, cacheWrite: 0, totalTokens: 20,
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        };
        stream.push({ type: "start", partial: { ...message, content: [] } });
        if (tool) {
          stream.push({ type: "toolcall_start", contentIndex: 0, partial: message });
          stream.push({ type: "toolcall_delta", contentIndex: 0, delta: JSON.stringify(args), partial: message });
          stream.push({ type: "toolcall_end", contentIndex: 0, toolCall: message.content[0], partial: message });
        } else {
          stream.push({ type: "text_start", contentIndex: 0, partial: message });
          stream.push({ type: "text_delta", contentIndex: 0, delta: message.content[0].text, partial: message });
          stream.push({ type: "text_end", contentIndex: 0, content: message.content[0].text, partial: message });
        }
        stream.push({ type: "done", reason: message.stopReason, message }); stream.end(message);
      });
      return stream;
    },
  });
}
