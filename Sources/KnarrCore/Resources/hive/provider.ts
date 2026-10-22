import { closeSync, readSync } from "node:fs";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const baseUrl = __KNARR_HIVE_BASE_URL__;
// DeepSeek V4.1 Flash's published maximum: 384K = 393216 tokens.
// https://api-docs.deepseek.com/quick_start/pricing
// https://api-docs.deepseek.com/api/create-chat-completion
// Hive supports max_completion_tokens but publishes no numeric ceiling:
// https://docs.thehive.ai/docs/deepseek-v41-flash
// This request budget's acceptance by the live Hive API is not verified.
const localOutputBudget = 393_216;

// Consume the app's bounded, pre-filled one-shot pipe at module import, before
// extension factories or any tools run. Child sessions reuse this closure, not fd198.
const credential = (() => {
  const bytes = Buffer.alloc(4096);
  try {
    const count = readSync(198, bytes, 0, bytes.length, null);
    if (count < 1 || count > 4095) throw new Error("Hive credential pipe is invalid");
    return bytes.toString("utf8", 0, count);
  } finally {
    bytes.fill(0);
    closeSync(198);
  }
})();

export default function (pi: ExtensionAPI) {
  // Official literal, process-memory-only override. Unlike apiKey config values,
  // setRuntime never interprets "!command" or an environment-variable name.
  // session_start completes before RPC admits prompts, including child sessions.
  pi.on("session_start", (_event, ctx) => {
    ctx.modelRegistry.authStorage.keys.setRuntime("hive", credential);
  });
  pi.registerProvider("hive", {
    baseUrl,
    api: "openai-completions",
    // Availability is prepared, never verified. No key in model metadata.
    // The literal runtime override above always wins before any request.
    apiKey: "knarr-hive-prepared",
    models: [{
      id: "deepseek-ai/deepseek-v4.1-flash-1017",
      name: "DeepSeek 4.1 Flash 1017 (Hive)",
      reasoning: true,
      thinking: { mode: "effort", efforts: ["high"], defaultLevel: "high" },
      input: ["text"],
      // Required numeric placeholders: pricing is unknown, not a free-use claim.
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 1_000_000,
      maxTokens: localOutputBudget,
      compat: {
        supportsReasoningEffort: true,
        supportsStore: false,
        maxTokensField: "max_completion_tokens",
      },
    }],
  });
}
