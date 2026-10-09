# anton decide-2b after the thinking fix - INCOMPLETE run, NOT a result

- Date/host: 2026-10-08, anton (CPU only). Profile `decide-2b` (letter-logit).
- Tree: HEAD `c5301defb73a949536fe741b597d3bd089df4109` plus an uncommitted change to `internal/gateway/letter.go`
  (`chat_template_kwargs.enable_thinking=false`); see `context.txt`.
- The run was interrupted by a host hang. The directory is a partial capture, not a finished benchmark.
- What the files show: golden 58/132 well-formed (before the change: 0/132); `golden.log` has 88 x `MALFORMED(http 502)`
  (~27 s each), 8 x `MALFORMED(http 422)`, 3 x `MALFORMED(URLError)`; accuracy over the well-formed answers does not beat
  the baselines; calibration "insufficient (n=58, need 200)".
- The cause of the HTTP 502 responses is UNCONFIRMED; nothing here identifies it.
- Do not cite these numbers as a model result or as proof the fix works. See `docs/decision-models.md`.
