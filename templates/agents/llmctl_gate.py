#!/usr/bin/env python3
"""llmctl_gate.py - decision logic of the llmctl agent gate hook (FR-086).

Reads one agent hook event as JSON on stdin, asks the llmctl decision gateway ONE typed `choice`
question through `llmctl-decide ask` (HTTPS, certificate verification on, key from the environment /
key file - never from this script's arguments), and prints the agent-specific verdict.

Verdicts: ALLOW (answer 'allow' with enough confidence), DENY ('block' with enough confidence),
ESCALATE (everything else: 'review', low confidence). ANY failure - gateway down, 401, 429/503/529,
timeout, malformed output, missing confidence, unknown answer, unparsable input - is an ERROR that
FAILS CLOSED: the verdict follows LLMCTL_HOOK_ON_ERROR (escalate by default, deny, or - only by that
explicit setting - allow).

Environment (all optional):
  LLMCTL_DECIDE_BIN          the llmctl-decide binary (default: llmctl-decide on PATH)
  LLMCTL_HOOK_QUESTION_FILE  the Typed Question (default: question.json next to this script)
  LLMCTL_HOOK_MIN_CONFIDENCE minimum answer confidence, 0..1 (default 0.7)
  LLMCTL_HOOK_ON_ERROR       escalate (default) | deny | allow   <- allow is the documented FAIL-OPEN switch
  LLMCTL_HOOK_ON_SAFE        defer (default) | allow             <- what an ALLOW verdict prints
  LLMCTL_HOOK_TIMEOUT        seconds for the decision call (default 20)
  (endpoint, CA and key: LLMCTL_ENDPOINT / LLMCTL_CACERT / LLMCTL_API_KEY or the key file, as for `llmctl decide`)

Agents: claude-code (PreToolUse), claude-code-prompt (UserPromptSubmit), crush (PreToolUse), generic.
Exit status is 0 or 2 only; the wrapper llmctl-gate-hook.sh turns every other status into a block.
"""
import json
import os
import subprocess
import sys

MAX_STDIN = 1 << 20
MAX_STATE = 4000
AGENTS = ("claude-code", "claude-code-prompt", "crush", "generic")
HERE = os.path.dirname(os.path.abspath(__file__))


class GateError(Exception):
    """A failure that must fail closed."""


def env_float(name, default, lo, hi):
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    try:
        v = float(raw)
    except ValueError:
        raise GateError("%s=%r is not a number" % (name, raw[:20]))
    if not (lo <= v <= hi):
        raise GateError("%s=%r is outside %s..%s" % (name, raw[:20], lo, hi))
    return v


def build_state(agent, event):
    if agent == "claude-code-prompt":
        text = event.get("prompt")
        if text is None:
            text = event.get("prompt_text")
        if not isinstance(text, str):
            raise GateError("the prompt event has no prompt text")
        return "user prompt submitted to a coding agent:\n" + text[:MAX_STATE]
    name = event.get("tool_name")
    if not isinstance(name, str) or not name:
        raise GateError("the event has no tool_name")
    tool_input = event.get("tool_input", {})
    try:
        body = json.dumps(tool_input, ensure_ascii=False, sort_keys=True)
    except (TypeError, ValueError):
        raise GateError("tool_input is not serialisable")
    return "coding agent tool call\ntool: %s\ninput: %s" % (name, body[:MAX_STATE])


def ask(state, min_conf):
    binary = os.environ.get("LLMCTL_DECIDE_BIN") or "llmctl-decide"
    question = os.environ.get("LLMCTL_HOOK_QUESTION_FILE") or os.path.join(HERE, "question.json")
    timeout = env_float("LLMCTL_HOOK_TIMEOUT", 20.0, 0.5, 600.0)
    cmd = [binary, "ask", "--question-file", question, "--stdin", "--json",
           "--min-confidence", repr(min_conf), "--retries", "1"]
    try:
        p = subprocess.run(cmd, input=state, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        raise GateError("the decision binary %r was not found" % binary)
    except subprocess.TimeoutExpired:
        raise GateError("the decision call timed out after %gs" % timeout)
    except OSError as e:
        raise GateError("cannot run the decision binary: %s" % e.__class__.__name__)
    if p.returncode == 10:
        return None, "low confidence (below %g): the answer was withheld" % min_conf
    if p.returncode != 0:
        first = (p.stderr or "").strip().splitlines()
        raise GateError("the decision call failed (exit code %d)%s" % (p.returncode, ": " + first[-1][:200] if first else ""))
    try:
        doc = json.loads(p.stdout)
        ans = doc["answers"]["q"]
        choice = ans["choice"]
        conf = ans["confidence"]
    except (ValueError, KeyError, TypeError):
        raise GateError("the decision answer is malformed or has no confidence")
    if not isinstance(choice, str) or isinstance(conf, bool) or not isinstance(conf, (int, float)):
        raise GateError("the decision answer is malformed or has no confidence")
    if conf < min_conf:
        return None, "low confidence %.3f (below %g)" % (conf, min_conf)
    return (choice, conf), ""


def decide(agent, event):
    """-> (verdict, reason); raises GateError on any failure."""
    min_conf = env_float("LLMCTL_HOOK_MIN_CONFIDENCE", 0.7, 0.0, 1.0)
    got, why = ask(build_state(agent, event), min_conf)
    if got is None:
        return "ESCALATE", why
    choice, conf = got
    if choice == "allow":
        return "ALLOW", "the decision model judged it safe (confidence %.3f)" % conf
    if choice == "block":
        return "DENY", "the decision model judged it must be blocked (confidence %.3f)" % conf
    if choice == "review":
        return "ESCALATE", "the decision model asks for human review (confidence %.3f)" % conf
    raise GateError("the decision answer %r is not one of allow/review/block" % choice[:20])


def error_verdict():
    mode = os.environ.get("LLMCTL_HOOK_ON_ERROR", "escalate")
    return {"escalate": "ESCALATE", "deny": "DENY", "allow": "ALLOW"}.get(mode)


def emit(agent, verdict, reason, *, from_error):
    on_safe_allow = os.environ.get("LLMCTL_HOOK_ON_SAFE", "defer") == "allow"
    if from_error and verdict == "ALLOW":
        reason = "FAIL-OPEN (LLMCTL_HOOK_ON_ERROR=allow): " + reason
    if agent == "generic":
        print("%s\t%s" % (verdict, reason.replace("\n", " ")))
        return 0
    if agent == "claude-code":
        if verdict == "ALLOW":
            if on_safe_allow and not from_error:
                print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                                                         "permissionDecisionReason": reason}}))
            return 0
        if verdict == "ESCALATE":
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask",
                                                     "permissionDecisionReason": "llmctl gate: " + reason}}))
            return 0
        sys.stderr.write("llmctl gate: blocked: %s\n" % reason)
        return 2
    if agent == "claude-code-prompt":
        if verdict == "ALLOW":
            return 0
        sys.stderr.write("llmctl gate: prompt held (%s): %s\n" % ("block" if verdict == "DENY" else "needs review", reason))
        return 2
    # crush: PreToolUse; no 'ask' - a missing decision falls through to the permission flow, which
    # --yolo auto-approves, so an ESCALATE is a deny here.
    if verdict == "ALLOW":
        if on_safe_allow and not from_error:
            print(json.dumps({"decision": "allow", "reason": reason}))
        return 0
    sys.stderr.write("llmctl gate: %s: %s\n" % ("blocked" if verdict == "DENY" else "needs human review (denied)", reason))
    return 2


def main(argv):
    if len(argv) != 3 or argv[1] != "--agent" or argv[2] not in AGENTS:
        sys.stderr.write("usage: llmctl_gate.py --agent %s\n" % "|".join(AGENTS))
        return 64
    agent = argv[2]
    try:
        raw = sys.stdin.buffer.read(MAX_STDIN + 1)
        if len(raw) > MAX_STDIN:
            raise GateError("the hook event is larger than %d bytes" % MAX_STDIN)
        try:
            event = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise GateError("the hook event is not valid JSON")
        if not isinstance(event, dict):
            raise GateError("the hook event is not a JSON object")
        verdict, reason = decide(agent, event)
        return emit(agent, verdict, reason, from_error=False)
    except GateError as e:
        v = error_verdict()
        if v is None:  # unknown ON_ERROR value: fail closed to the strictest verdict
            v = "DENY"
            e = "%s; LLMCTL_HOOK_ON_ERROR has an unknown value (use escalate|deny|allow)" % e
        return emit(agent, v, "error: %s" % e, from_error=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
