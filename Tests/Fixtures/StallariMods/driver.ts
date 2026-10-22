// Test-only provider. OMP's real agent loop executes real registered tools;
// this provider emits deterministic tool choices without network or credentials.
import { createAssistantMessageEventStream } from "@oh-my-pi/pi-ai";

export default function (pi) {
  pi.on("session_start", (_event, ctx) => {
    ctx.ui.setStatus("driver-startup", "connected");
    ctx.ui.setWidget("driver-startup", ["connected"]);
  });
  pi.registerProvider("knarr-fixture", {
    baseUrl: "http://127.0.0.1:1",
    apiKey: "fixture-not-a-credential",
    api: "knarr-test-api",
    models: [{
      id: "deterministic", name: "Knarr deterministic fixture", reasoning: false,
      input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 200000, maxTokens: 2048,
    }],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        const last = context.messages.at(-1);
        const text = typeof last?.content === "string" ? last.content : (last?.content ?? []).map(x => x.text ?? "").join("\n");
        const systemPrompt = Array.isArray(context.systemPrompt) ? context.systemPrompt.join("\n") : (context.systemPrompt ?? "");
        const tool = last?.role === "user" && text.includes("CALL_DIRECT_COMMAND") ? "bash"
          : last?.role === "user" && text.includes("CALL_PROBE") ? "knarr_probe"
          : last?.role === "user" && text.includes("RELOAD_EXTENSIONS") ? "reload_extensions" : undefined;
        const args = tool === "bash" ? { command: "printf KNARR_DIRECT_COMMAND_OK" } : {};
        const message = {
          role: "assistant", api: model.api, provider: model.provider, model: model.id,
          content: tool ? [{ type: "toolCall", id: "fixture-" + Date.now(), name: tool, arguments: args }]
            : [{ type: "text", text: text.includes("CHECK_OWNED_RESOURCES")
              ? `OWNED_RULE=${systemPrompt.includes("KNARR_ONLY_RULE")} OWNED_SKILL=${systemPrompt.includes("knarr-only-skill")} AMBIENT_BLOCKED=${!systemPrompt.includes("KNARR_AMBIENT_RESOURCE")}`
              : last?.role === "toolResult" ? "TOOL_RESULT " + text : "CONVERSATION_CONTINUES" }],
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
        stream.push({ type: "done", reason: message.stopReason, message });
        stream.end(message);
      });
      return stream;
    },
  });
}
