// agent_harness.mjs - a STUB AGENT for the opencode plugin and the pi extension: it loads the real template
// module, drives its hook exactly the way the agent would (opencode: tool.execute.before(input, output);
// pi: the registered "tool_call" handler with an event and a ctx) and checks the outcome.
// Reads the gateway/hook environment of the caller; prints HARNESS-FAIL lines for broken expectations.
import { pathToFileURL } from "node:url";
const [opencodePath, piPath] = process.argv.slice(2);
let fails = 0;
const expect = (name, cond) => { if (!cond) { fails++; console.log("HARNESS-FAIL " + name); } else console.log("harness ok: " + name); };

const oc = await import(pathToFileURL(opencodePath).href);
const exportsList = Object.keys(oc);
expect("opencode: the module exports only the plugin function", exportsList.length === 1 && exportsList[0] === "LlmctlGate");
const hooks = await oc.LlmctlGate({});
const ocCall = async (env) => {
  const saved = { ...process.env };
  Object.assign(process.env, env);
  try { await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "ls" } }); return "allowed"; }
  catch (e) { return "blocked:" + e.message; }
  finally { for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k]; Object.assign(process.env, saved); }
};
const pi = await import(pathToFileURL(piPath).href);
let handler;
pi.default({ on: (ev, fn) => { if (ev === "tool_call") handler = fn; } });
expect("pi: registered a tool_call handler", typeof handler === "function");
const piCall = async (env, ctx = { hasUI: false }) => {
  const saved = { ...process.env };
  Object.assign(process.env, env);
  try { return await handler({ toolName: "bash", input: { command: "ls" } }, ctx); }
  finally { for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k]; Object.assign(process.env, saved); }
};

const here = new URL(".", import.meta.url).pathname;
const block = process.env.HARNESS_BLOCKQ;
const SAFE = { LLMCTL_HOOK_MIN_CONFIDENCE: "0" };
// --- opencode
expect("opencode: safe answer lets the tool run", (await ocCall(SAFE)) === "allowed");
expect("opencode: block answer throws", (await ocCall({ ...SAFE, LLMCTL_HOOK_QUESTION_FILE: block })).startsWith("blocked:"));
expect("opencode: low confidence blocks (no ask in opencode)", (await ocCall({})).includes("needs human review"));
expect("opencode: gateway down blocks", (await ocCall({ LLMCTL_ENDPOINT: "https://127.0.0.1:1" })).startsWith("blocked:"));
expect("opencode: explicit fail-open lets it run", (await ocCall({ LLMCTL_ENDPOINT: "https://127.0.0.1:1", LLMCTL_HOOK_ON_ERROR: "allow" })) === "allowed");
expect("opencode: missing hook file blocks", (await ocCall({ LLMCTL_GATE_HOOK: "/nonexistent/hook.sh" })).startsWith("blocked:"));
expect("opencode: missing hook file + fail-open allows", (await ocCall({ LLMCTL_GATE_HOOK: "/nonexistent/hook.sh", LLMCTL_HOOK_ON_ERROR: "allow" })) === "allowed");
// --- pi
expect("pi: safe answer returns nothing (proceed)", (await piCall(SAFE)) === undefined);
const b = await piCall({ ...SAFE, LLMCTL_HOOK_QUESTION_FILE: block });
expect("pi: block answer returns { block: true }", b && b.block === true && /blocked/.test(b.reason));
const lowNoUi = await piCall({});
expect("pi: low confidence without a UI blocks", lowNoUi && lowNoUi.block === true && /human review/.test(lowNoUi.reason));
let asked = 0;
const yes = await piCall({}, { hasUI: true, ui: { confirm: async () => { asked++; return true; } } });
expect("pi: low confidence with a UI asks the human and proceeds on yes", asked === 1 && yes === undefined);
const no = await piCall({}, { hasUI: true, ui: { confirm: async () => false } });
expect("pi: the human declining blocks", no && no.block === true);
let askedOnBlock = 0;
const hard = await piCall({ ...SAFE, LLMCTL_HOOK_QUESTION_FILE: block }, { hasUI: true, ui: { confirm: async () => { askedOnBlock++; return true; } } });
expect("pi: a DENY verdict is never overridden by a prompt", askedOnBlock === 0 && hard && hard.block === true);
const down = await piCall({ LLMCTL_ENDPOINT: "https://127.0.0.1:1" });
expect("pi: gateway down blocks", down && down.block === true);
expect("pi: explicit fail-open proceeds", (await piCall({ LLMCTL_ENDPOINT: "https://127.0.0.1:1", LLMCTL_HOOK_ON_ERROR: "allow" })) === undefined);
console.log("HARNESS-DONE fails=" + fails);
process.exit(fails ? 1 : 0);
