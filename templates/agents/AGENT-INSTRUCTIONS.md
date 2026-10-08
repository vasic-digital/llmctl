## Decision calls (llmctl)

A local **decision model** answers one typed question about a piece of state with probability-shaped (not calibrated)
probabilities. It is not a chat model: it never writes text, and it cannot see your repository.

Make a decision call - do not reason it out yourself - when ALL of these hold:

1. the outcome is one of a **small closed set** (yes/no, one of N named options, or a level 0..N-1);
2. you can state the relevant **state in text** (a log excerpt, a diff summary, a ticket, a command line);
3. the choice **gates or routes** something (is this command safe to run, which tool, which queue,
   is this change risky) and a wrong or unsure answer should be **visible**, not guessed past.

Do NOT use it for open-ended questions, code generation, summarising, or anything needing the repo.

How (one call, state on stdin so it never appears in a process list):

```sh
printf '%s' "$STATE" | llmctl-decide ask --stdin --type choice \
  --instructions "Which team owns this ticket?" \
  --criteria '{"billing":"invoices and payments","platform":"infrastructure"}' \
  --min-confidence 0.7 --json
```

Read `answers.q.choice` and `answers.q.confidence`. Exit code **10** means "not confident enough":
treat it as *undecided* and ask a human - never as a default answer. Any other non-zero exit
(4 key, 5 certificate, 6 gateway unreachable, 1 backend) is a failure: stop and report it; do **not**
fall back to guessing. The access key comes from the environment (`LLMCTL_API_KEY`) or the key file -
never type it into a command, a file or a message.
