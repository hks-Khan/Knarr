import { lookup } from "@oh-my-pi/pi-coding-agent/config/registry";

// KNARR_HIRD_POLICY is the validated, dispatch-local file snapshot prepended by Knarr.
export default function(pi) {
  const scope = pi.pi.settings;
  const threshold = lookup("compaction.thresholdTokens");
  const policy = KNARR_HIRD_POLICY;
  const failures = new Map();
  // Passive context is delivered by OMP before the next model request. It does
  // not start a turn, change a command, or replace the original result/exit code.
  pi.on("tool_result", async (event) => {
    if (["edit", "write"].includes(event.toolName)) { failures.clear(); return; }
    if (event.toolName !== "bash") return;
    const command = event.input?.command;
    if (typeof command !== "string" || !command.trim()) return;
    const guidance = policy.verificationFeedback;
    if (!guidance) return;
    if (compoundEvidence(command)) return { additionalContext: guidance.invalidCommand };
    const failed = event.isError || event.details?.timedOut ||
      (typeof event.details?.exitCode === "number" && event.details.exitCode !== 0);
    if (!failed) {
      if (!event.details?.async && !event.details?.service) failures.delete(command);
      return;
    }
    const count = (failures.get(command) ?? 0) + 1;
    failures.set(command, count);
    if (count === guidance.failureThreshold) return { additionalContext: guidance.repeatedFailure };
  });
  const updateThreshold = (_, ctx) => {
    const window = ctx.model?.contextWindow;
    const { thresholdTokens, thresholdPercent } = policy.compaction;
    const tokens = Number.isFinite(window) && window > 0
      ? Math.min(thresholdTokens, Math.floor(window * thresholdPercent / 100))
      : thresholdTokens;
    // Native runtime override only: never writes project/global OMP configuration.
    threshold.override(scope, tokens);
  };
  pi.on("session_start", updateThreshold);
  pi.on("model_changed", updateThreshold);
  pi.on("before_agent_start", updateThreshold);
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "lsp") return;
    const input = event.input;
    const limit = policy.lspTimeoutSeconds;
    const requested = typeof input.timeout === "number" && input.timeout > 0 ? input.timeout : limit;
    return { input: { ...input, timeout: Math.min(requested, limit) } };
  });
}

// Mirrors ShellEvidence's evidence eligibility; this advises without blocking.
function compoundEvidence(command) {
  let quote, escaped = false, token = "", tokens = [];
  const segments = [];
  const flush = () => { if (token) { tokens.push(token); token = ""; } };
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (escaped) { token += c; escaped = false; continue; }
    if (quote === "'") { if (c === "'") quote = undefined; else token += c; continue; }
    if (c === "\\") { escaped = true; continue; }
    if (c === "`" || (c === "$" && command[i + 1] === "(")) return true;
    if (quote === '"') { if (c === '"') quote = undefined; else token += c; continue; }
    if (c === "'" || c === '"') { quote = c; continue; }
    if ("|;\n\r()".includes(c)) return true;
    if (c === "&") {
      if (command[i + 1] === "&") {
        flush(); if (!tokens.length) return true;
        segments.push(tokens); tokens = []; i++; continue;
      }
      if (i > 0 && "><".includes(command[i - 1])) { token += c; continue; }
      return true;
    }
    if (/\s/.test(c)) flush(); else token += c;
  }
  if (quote || escaped) return true;
  flush(); if (!tokens.length) return true;
  segments.push(tokens);
  return segments.some(words => {
    let i = 0;
    while (i < words.length && (words[i].includes("=") || ["env", "command"].includes(words[i]))) i++;
    if (i === words.length) return true;
    const program = words[i].split("/").pop();
    if (["eval", "source", "."].includes(program)) return true;
    return ["sh", "bash", "zsh", "dash", "ksh", "fish"].includes(program) &&
      words.slice(i + 1).some(word => word.startsWith("-") && word.includes("c"));
  });
}
