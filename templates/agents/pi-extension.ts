// pi-extension.ts - fail-closed llmctl decision gate for pi (FR-086).
//
// Install: cp pi-extension.ts ~/.pi/agent/extensions/llmctl-gate.ts   (global)  or  .pi/extensions/ (project);
//          `pi -e ./pi-extension.ts` for a one-off. The hook files must exist at $LLMCTL_GATE_HOOK
//          (default ~/.config/llmctl/hooks/llmctl-gate-hook.sh, next to llmctl_gate.py and question.json).
//
// Mechanism (pi docs/extensions.md, verified 2026-10-07): pi has NO shell-command hooks; extensions are
// TypeScript modules and `pi.on("tool_call", ...)` can BLOCK by returning { block: true, reason }.
// ESCALATE asks the human through ctx.ui.confirm when a UI exists (interactive/RPC) and blocks otherwise
// (print/JSON mode cannot prompt). Every failure blocks unless LLMCTL_HOOK_ON_ERROR=allow.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

type Gate = { verdict: "ALLOW" | "DENY" | "ESCALATE"; reason: string };

function gate(tool: string, input: unknown): Gate {
  const hook = process.env.LLMCTL_GATE_HOOK || join(homedir(), ".config", "llmctl", "hooks", "llmctl-gate-hook.sh");
  const failOpen = process.env.LLMCTL_HOOK_ON_ERROR === "allow";
  const closed = (reason: string): Gate => (failOpen ? { verdict: "ALLOW", reason: `FAIL-OPEN: ${reason}` } : { verdict: "DENY", reason });
  const event = JSON.stringify({ tool_name: tool, tool_input: input ?? {} });
  const r = spawnSync("bash", [hook, "--agent", "generic"], { input: event, encoding: "utf8", timeout: 60000, env: process.env });
  if (r.error || r.status !== 0) return closed(`gate failure: ${r.error ? (r.error as NodeJS.ErrnoException).code ?? r.error.message : `status ${r.status}`}`);
  const [verdict, ...rest] = String(r.stdout).split("\n")[0].split("\t");
  if (verdict !== "ALLOW" && verdict !== "DENY" && verdict !== "ESCALATE") return closed("unparsable gate output");
  return { verdict, reason: rest.join("\t") };
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event: any, ctx: any) => {
    const g = gate(String(event.toolName), event.input);
    if (g.verdict === "ALLOW") return undefined;
    if (g.verdict === "ESCALATE" && ctx?.hasUI) {
      const ok = await ctx.ui.confirm("llmctl gate: needs review", `${event.toolName}: ${g.reason}\nAllow this call?`);
      if (ok) return undefined;
      return { block: true, reason: "llmctl gate: declined by the human" };
    }
    return { block: true, reason: `llmctl gate (${g.verdict === "ESCALATE" ? "needs human review" : "blocked"}): ${g.reason}` };
  });
}
