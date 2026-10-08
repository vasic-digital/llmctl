// opencode-plugin.js - fail-closed llmctl decision gate for opencode (FR-086).
//
// Install:  mkdir -p .opencode/plugins && cp opencode-plugin.js .opencode/plugins/llmctl-gate.js
//           (or ~/.config/opencode/plugins/ for every project). The hook files must exist at
//           $LLMCTL_GATE_HOOK (default ~/.config/llmctl/hooks/llmctl-gate-hook.sh, next to llmctl_gate.py
//           and question.json). Endpoint / CA / key come from the environment as for `llmctl decide`.
//
// Mechanism (opencode plugin docs, verified 2026-10-07): a plugin is a named async export returning hook
// functions; `tool.execute.before(input, output)` sees input.tool and output.args, and THROWING blocks the
// call. opencode has no "ask" outcome here, so ESCALATE is a block. Every failure blocks unless the operator
// sets LLMCTL_HOOK_ON_ERROR=allow (the documented fail-open switch).
// NOTE: opencode treats every named export as a plugin - keep this file free of other exports.
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

function gate(tool, args) {
  const hook = process.env.LLMCTL_GATE_HOOK || join(homedir(), ".config", "llmctl", "hooks", "llmctl-gate-hook.sh");
  const failOpen = process.env.LLMCTL_HOOK_ON_ERROR === "allow";
  const event = JSON.stringify({ tool_name: String(tool), tool_input: args ?? {} });
  const r = spawnSync("bash", [hook, "--agent", "generic"], { input: event, encoding: "utf8", timeout: 60000, env: process.env });
  if (r.error || r.status !== 0) {
    const why = r.error ? r.error.code || r.error.message : `hook exited with status ${r.status}`;
    return failOpen ? { verdict: "ALLOW", reason: `FAIL-OPEN: ${why}` } : { verdict: "DENY", reason: `gate failure: ${why}` };
  }
  const line = String(r.stdout).split("\n")[0];
  const [verdict, ...rest] = line.split("\t");
  if (!["ALLOW", "DENY", "ESCALATE"].includes(verdict)) {
    return failOpen ? { verdict: "ALLOW", reason: "FAIL-OPEN: unparsable gate output" } : { verdict: "DENY", reason: "unparsable gate output" };
  }
  return { verdict, reason: rest.join("\t") };
}

export const LlmctlGate = async () => ({
  "tool.execute.before": async (input, output) => {
    const g = gate(input.tool, output.args);
    if (g.verdict !== "ALLOW") {
      throw new Error(`llmctl gate (${g.verdict === "ESCALATE" ? "needs human review" : "blocked"}): ${g.reason}`);
    }
  },
});
