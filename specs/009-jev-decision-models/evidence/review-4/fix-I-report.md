# FIX-I report - round-3 contract/gateway findings (B3-01..B3-11) + C3-01, C3-14, C3-16

Tree: uncommitted on `main`. Nothing staged or committed. Only owned files touched (see per finding).
Scratch copies: `scratchpad/mw` (mutation runner `scratchpad/mut_b4.py`), `scratchpad/bashsh` (`sh -> bash`).

## Verification run (targeted)

- `gofmt -l cmd internal` empty; `go vet ./...` clean.
- `go test -race -count=1 ./internal/readout ./internal/contract ./internal/gateway ./internal/client ./internal/schema ./internal/mcpserver ./cmd/llmctl-decide` all `ok`.
- `bash tests/test_decide_cli.sh` PASS, `bash tests/test_gateway_endpoints.sh` PASS (after updating the B-01 bound fixture), `bash tests/test_onnx_runtime.sh` PASS, `bash tests/test_gateway_mutation.sh` PASS (control GREEN, 19/19 mutations killed, none INVALID).
- `make lint`: see the last line of this file.
- Mutation proof on a scratch copy: 30 mutants (reviewer M1-M11 equivalents + new ones), final state **killed=30 survived=0 invalid=0** (run 1: 12 killed / 1 survived = M1f, a client-gate mutant; a test was added, re-run: killed; run 2: M1f..M8 families 19/19 killed).

## B3-01 (IMPORTANT) conservative gate - FIXED

Files: `internal/readout/readout.go`, `internal/contract/response.go`, `internal/client/output.go`, `internal/client/permute.go`, `internal/mcpserver/server.go` (message), `specs/.../contracts/openapi.yaml`, `cli.md`, `docs/decide-gateway.md`, `docs/decision-models.md`, tests.

Derivation (written in the `readout.go` package comment, `openapi.yaml` `AnswerFlags`/`UpperBounds`, `docs/decide-gateway.md`): list is the top-n, so every unlisted token <= p_min; unlisted mass U = 1 - S (S = sum of ALL listed probabilities; round-off below 1e-9 counts as 0); a letter is the sum of s = 3 spellings. Absent letter i: x_i <= min(s*p_min, U), and sum x_i <= U jointly. Each absent letter reports its OWN full bound; a fully listed distribution gives 0 (reviewer case: listed 1.0 -> bound 0, was 0.6).
- Conservative distribution = the allocation in that polytope that MAXIMISES sum x^(1/T) (`readout.WorstAllocation`: even water-filling for T>=1, largest-cap-first for T<1), i.e. the smallest share any feasible hidden allocation can leave a present letter, valid for every temperature.
- Winner is chosen among LISTED options only (`buildAnswer`; permute merge too); the client gate reads the listed winner's share from the wire (noul: the side that is not in `upper_bounds`), and no longer applies `1 - max(upper_bounds)` a second time (that scaling mixed scales and double-penalised).
- `openapi.yaml`: "CONSERVATIVE" claim replaced by the exact guarantee and limits.
- RED: before the fix 4 old-semantics tests encoded the loose bound; with the new code they failed as expected and were rewritten to the derived values (listed .96 -> bound .04 not .06; listed .9 + 1 letter -> .1 not 1; etc.). The old implementation of `internal/readout` is untracked in git (no HEAD baseline), so the RED against the OLD code is shown by mutants instead: M1b (drop U), M1c (drop spellings), M1 (halve allocation), M1d (swap concave/convex), M1e (absent may win), M1f (client counts absent as winner) all KILLED.
- GREEN: `TestConservativeShareIsATrueLowerBoundForEveryFeasibleHiddenAllocation` (seeded, 300 random listed sets x T in {0.5,1,2}; oracle derived in the test from the input, brute-force grid over hidden allocations incl. the remaining-mass vertex: soundness exact, tightness within 0.05), `TestListedMassOneGivesAbsentLettersBoundZero`, `TestAbsentLetterKeepsItsFullBoundNextToALowRankedPresentLetter` (reviewer probe: A share .857 = 0.6/0.7, confidence .786 = true worst case), `TestEveryAbsentLetterReportsItsOwnBoundAndTheJointMassIsCapped`, `TestWorstAllocationShapes`, gateway end-to-end `TestLetterLowRankedPresentLetterKeepsTheFullAbsentBound`, contract `TestBoundedAnswerChoosesAmongListedOptionsOnly`, client/mcp gate tests, `tests/test_gateway_endpoints.sh` fixture (bound .071776734).
- Honest limits kept in docs: listed letters' masses are lower bounds (their unlisted spellings are not added to the denominator); an engine with > 3 token ids per letter is not covered; the catalog `readout.spellings` list does NOT restrict the readout (it sums all three forms), so s stays 3 (`ComputeRawSpellings` exists for a different s, the gateway does not use it - using the catalog length would be unsound).

## B3-02 (IMPORTANT) neutraliser - FIXED (best effort, stated)

Files: `internal/contract/prompt.go`, `tokens.go`, `docs/decide-gateway.md`, tests `b4_prompt_test.go`.
Rule (comment in `foldLine`): MATCH-only fold = NFKD, drop Cf, Cc, Mn/Me and Zs/Zl/Zp (all blanks anywhere) plus the invisible non-Cf fillers (U+115F, U+1160, U+3164, U+FFA0, U+2800, U+180E, U+034F, U+17B4/5), tag chars U+E0020..E007E mapped to the ASCII they spell, lower-case, documented confusable table (Greek, Cyrillic, dotless i/j, IPA, Latin small capitals, Armenian, Cherokee incl. lower-case via init, Lisu), leading list prefix = any Pd dash, U+2212, U+2E3A, bullets, markdown marks. The `===` delimiter check keeps the ASCII space (the neutraliser's own `= = =` must not re-join). The ORIGINAL line is rewritten (`| ` prefix); content bytes are never stripped by the fold. U+180E removed from `isHiddenControl` so Mongolian text is preserved (invisible only for matching).
- RED (quoted before the fix): `TestB4InvisibleFillersAndConfusablesAreNeutralised` produced 133 failure lines, e.g. `state attack 0 "ㅤAnswer: B" reaches the model un-neutralised`, U+2800, U+115F, U+FFA0, `Questıon`, small capitals, Cherokee, Lisu, U+2010..U+2015 / U+2E3A / U+2212 prefixes, tag-character `Answer:` - in state AND instructions.
- GREEN: same test; `TestB4ContentWithJoinersAndScriptsIsPreserved` (Persian ZWNJ, Devanagari ZWJ, emoji ZWJ, Korean, Mongolian U+180E byte-for-byte); `TestB4ConfusableTableIsComplete` (independent expectation table: fails if a listed look-alike stops mapping; invisible set; tag chars; prefix set incl. `+`/`~`; enclosing mark); `TestB4MongolianVowelSeparatorIsKeptInContent`.
- Mutation: M5 (`+ ~` prefix), M6 (Me kept), M6b..M6g (filler set, tag map, dotless i, dashes, U+180E in content, blanks) all KILLED.
- Not fixed / stated: no confusable table is complete (docs say so); Thai ZWSP is still removed from content by the pre-existing `cleanText`; over-neutralisation increased slightly (lines like `x : y` now get a `| ` prefix; content kept).

## B3-03 FIXED - `cmd/llmctl-decide/cmd_ask.go`
`fs.Visit` -> explicit empty `--model`/`--profile` exits 2 naming the model. Test `TestAskExplicitEmptyModelOrProfileIsAUsageError` RED (rc=0) -> GREEN; mutant M14 killed.

## B3-04 FIXED - `internal/gateway/props.go`, `driver.go`
TTL 30 s -> 10 s; cache dropped on any engine non-200 or transport error of the completion (`invalidateProps`, not on a cancelled caller); fetch detached from the request context (`WithoutCancel`, bounded by `propsTimeout`) so a cancelled request neither caches `n=0` nor aborts others; singleflight for concurrent misses; cache bounded to 256 entries with pruning. Tests: TTL positive/negative with a fake clock, n_ctx 15/16/2^24/2^24+1, cancelled ctx, 8 concurrent misses = 1 fetch, invalidation after a 500, bound. Mutants M2, M3, M3b-e, M11 killed.

## B3-05 FIXED - `internal/gateway/letter.go`
All questions are rendered and budget-checked BEFORE the first completion (`/props` stays the only prior engine contact; docs now say exactly that). Tests: boundary exactness (est == budget served, +1 refused, engine not contacted), 3-question request refused with 0 completions. Mutants M4, M4b killed. `env-vars.md`/`decide-gateway.md`/`decision-models.md` updated (ctx budget now `LLMCTL_CTX_<P>` + `/props`).

## B3-06 FIXED - `internal/gateway/driver.go`, `resolver.go`, `registry_resolver.go`
`Endpoint.FromRegistry`; 404/405 -> retryable 502 only for registry endpoints, static endpoint -> 500 non-retryable (logged). Test cases `static 404/405`; M12 killed.

## B3-07 FIXED - `internal/contract/instance.go`, `internal/client/client.go`
`SafeInstanceLabel`: `[A-Za-z0-9._-]{1,64}` verbatim (upper case now accepted, tenant ids), anything else/longer -> `inst-<12 hex of sha256>` (stable, header-safe, discloses nothing) instead of silently dropping; client accepts the same class. Tests pin the class and the 64/65 boundary (M10 killed). Updated the two older tests that asserted "dropped".

## B3-08 FIXED - `cmd/llmctl-decide/serve_env.go`, `internal/gateway/driver.go`, `letter.go`
`LLMCTL_SEED=0` is valid (only negatives refused); carried to the driver as `gateway.SeedZero` and sent as `0` (`ResolveSeed`); unset/blank stay seed 1. I could not add a `SeedSet` field to the backend struct construction because `cmd_serve.go` is FIX-H's file, so the explicit-zero is a documented sentinel value (a follow-up could replace it with a bool when `cmd_serve.go` is free). Tests + mutant M13 killed; `env-vars.md` / `decide-gateway.md` updated.

## B3-09 FIXED (per-profile) - `cmd/llmctl-decide/serve_resolver.go`
`autoResolver.Resolve` decides per profile on every request (registry if that profile has a healthy entry, else static); always built in `auto` mode; `mode()` (status only) caches for one interval and reads the registry outside the lock; no lock around any I/O. Test: mixed deployment, unhealthy registry entry falls back, 6 concurrent resolves are not serialised (M15 killed). Docs: `registry-discovery.md` (auto paragraph + table row), `decide-gateway.md` ("decides once" section replaced), `env-vars.md`.

## B3-10 tests - DONE
Guards for all 9 surviving mutations: M1 (conservative cap) -> property + probe tests; M2/M3/M11 -> props tests; M4 -> boundary; M5/M6 -> fold tests; M7 -> `TestPermuteAveragedExactTieGoesToTheFirstOriginalKey`; M8 -> 3-instance `/v1/models` test (also changed the code to the MINIMUM budget over healthy instances); M10 -> instance class test. Re-run result above: all killed.

## B3-11 docs - DONE
registry-discovery.md auto semantics (line 95 + 114 row), env-vars.md (`MAX_STATE_CHARS` ctx budget/`/props`, `RESOLVER`, `SEED`, `CTX_<PROFILE>`), openapi.yaml (flags/upper_bounds/noul wording), cli.md gate wording, decide-gateway.md, decision-models.md. Go side now parses `LLMCTL_CTX_<P>` like Python `int()` (`pyInt`: blanks, sign, single underscores; test `TestCtxOverrideParsesLikePythonInt` RED -> GREEN, M16 killed). Documented residual: Python accepts non-ASCII decimal digits, the gateway refuses them (loud start error); gateway caps at 2^24, launcher has no cap. `b2_docs_test.go` extended to pin the exact bound wording and absence of the stale auto claims.

## Extra items from the coordinator

- **C3-01** `internal/gateway/registry_resolver_publish_test.go`: `sh -c 'sleep 60; :' successor`. RED with `sh -> bash` first in PATH (`PATH=scratchpad/bashsh:$PATH`): 2 of 3 runs FAIL ("pid ... is not (yet) running \"successor\""; the 3rd passed by a race before bash exec'd). GREEN after: 5/5 PASS. `cmd/llmctl-decide/serve_reconcile_test.go` `registerAfterExec` callers spawn `sleep` directly with `CmdToken: "sleep"` - not affected. NOT mine / not fixed: `internal/registry/registry_test.go:218` also uses `sh -c "sleep 300; : supervising tok-svc forever"` (already has the `; :`) and `internal/registry/fixc_test.go:44` runs a script via `sh` - FIX-J's package, not checked under bash-as-sh.
- **C3-16** `TestEngineDeterministicRejectionsAreNonRetryable`: `resetLoggedFaults()` (new unexported helper next to `loggedFaults`) at test start and `t.Cleanup`. RED: with the reset removed `-count=2` FAILS ("a server-side config fault is logged"); GREEN with it: `-count=2` passes.
- **C3-14** `tests/test_gateway_mutation.sh`: `mutate()` now requires the mutant to compile (`go build ./... && go test -run '^$' <pkgs>`) and reports `INVALID` (counted as a failure) otherwise. The 3 compile-error "kills" were: "NLI generic label_source accepted" (unused `src`) -> now `if false && src != ""`; "NLI truncation not reported" (unused `server` import) -> now `_ = server.NoteTruncated`; "symlinked key file accepted" (unused `st`) AND it survived harmlessly via O_NOFOLLOW -> replaced by "symlinked key file followed (Lstat refusal and O_NOFOLLOW removed)" in `internal/gateway/keyfile.go` (the guard is there; `internal/keyring` is FIX-H's), which compiles and is killed by the symlink test. Also re-anchored "deterministic seed dropped" to the new `ResolveSeed` line. Result: control GREEN, 19/19 killed, 0 INVALID.

## Not done / partly

- Present letters' unlisted spellings are not added to the worst-case denominator (documented limit, B3-01 text), so "true lower bound" holds under that stated model.
- A permute-merge test for the "listed-in-some-runs" winner rule was not added (the code is covered only indirectly; M-permute-winner mutant was not part of the list).
- `lib/decide.sh:559` (B2-16 residue) and `lib/onnx_server.py` untouched (no finding for them in my scope).
- Whole-suite `make test` not run (instructed).

## make lint

`shellcheck -S warning tests/test_gateway_mutation.sh tests/test_gateway_endpoints.sh` (the only shell files I changed): rc 0. The full `make lint` (shellcheck over every script in `$(SCRIPTS)`, including other agents' in-flight files) did NOT finish in my budget: the first run was cut by my own `timeout 100`, a second foreground run reported `Terminated` after printing the shellcheck version, and a third run was still going when I handed back - so a clean full-repo lint is UNCONFIRMED from this run.
