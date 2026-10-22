// Official OMP API fixture; no credentials, global settings, shell commands, or model calls.
export default function (pi) {
  async function runProbe(ctx) {
    ctx.ui.setStatus("probe", "ready");
    const confirmed = await ctx.ui.confirm("Probe confirm", "Continue?");
    return {
      content: [{ type: "text", text: confirmed ? "confirmed" : "declined" }],
      details: { confirmed },
    };
  }

  pi.registerTool({
    name: "knarr_probe",
    label: "Probe",
    description: "VERSION_ONE",
    parameters: pi.zod.object({}),
    async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
      return runProbe(ctx);
    },
  });

  // Exercise the same tool behavior without sending a prompt to a paid provider.
  pi.registerCommand("knarr-ui-probe", {
    handler: async (_args, ctx) => {
      ctx.ui.setWidget("probe", ["widget line"], { placement: "aboveEditor" });
      ctx.ui.notify("probe toast", "info");
      const result = await runProbe(ctx);
      ctx.ui.notify(result.content[0].text, "info");
      const selected = await ctx.ui.select("Probe select", ["first", "second"]);
      const input = await ctx.ui.input("Probe input", "type here");
      const edited = await ctx.ui.editor("Probe editor", "prefilled");
      ctx.ui.notify(JSON.stringify({ selected, input, edited }), "info");
      ctx.ui.setStatus("probe", undefined);
      ctx.ui.setWidget("probe", undefined);
      ctx.ui.notify("probe complete", "info");
    },
  });

  pi.registerCommand("knarr-reload-probe", {
    handler: async (_args, ctx) => {
      await ctx.reload();
    },
  });
}
