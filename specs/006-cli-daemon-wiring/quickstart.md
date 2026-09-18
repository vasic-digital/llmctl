# Quickstart: bash-CLI to Go-daemon Cluster/Tenant/Apikey Wiring

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

Assumes tasks.md's implementation tasks have landed.

## Step 1 — Build the daemon and run its own test suite

```bash
cd /home/milosvasic/Projects/llmctl/llmctld
go build ./...
go test ./... -race
```

**Expected outcome**: build succeeds; `TestRegistry_List`,
`TestEnforcer_GetLimits`, and the new `routes_tenants_test.go` cases for
`GET /v1/tenants` and `GET`/`PUT /v1/tenants/:id/quota` all pass alongside
every pre-existing test (zero regressions).

## Step 2 — Start a real llmctld and issue an admin token

```bash
cd /home/milosvasic/Projects/llmctl
./llmctld/bin/llmctld &            # or the systemd/launchd-managed instance
export LLMCTL_CLUSTER_TOKEN="$(curl -sS -X POST https://127.0.0.1:9443/v1/auth/token -d '{"subject":"admin","roles":["admin"]}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')"
```

## Step 3 — Exercise all seven newly-wired subcommands live

```bash
bin/llmctl tenant create demo-tenant
bin/llmctl tenant list                      # must now show demo-tenant, not "not yet implemented"
bin/llmctl tenant quota demo-tenant --max-concurrent-requests 5
bin/llmctl tenant quota demo-tenant         # view: must echo the just-set limit
bin/llmctl apikey create model-viewer
bin/llmctl apikey rotate <key-id-from-above>
bin/llmctl cluster join 127.0.0.1:9444      # against a second, real llmctld instance
bin/llmctl cluster leave
```

**Expected outcome**: every command prints a real, structured result (no
`die "...not yet implemented..."` anywhere), matching the JSON wire shapes
in data-model.md.

## Step 4 — Confirm the three failure-mode distinctions (spec Edge Cases)

```bash
# Unreachable daemon
kill %1
bin/llmctl tenant list; echo "exit: $?"     # expect: llmctld-unreachable message, non-zero, distinct wording from below

# Daemon reachable but returns an app-level error (nonexistent tenant)
./llmctld/bin/llmctld &
bin/llmctl tenant quota ghost-tenant        # expect: prints the daemon's own 404 {"error": "..."} message, not a curl/parse error

# Concurrent rotate (spec edge case)
bin/llmctl apikey rotate <same-key-id> & bin/llmctl apikey rotate <same-key-id> &
wait                                        # expect: exactly one succeeds with a new key, the other reports the
                                             # daemon's own conflict/not-found response - never two silently-different
                                             # "new" keys both reported as success
```

## Step 5 — Full regression pass

```bash
cd /home/milosvasic/Projects/llmctl
bash tests/test_all.sh   # or the project's existing full-suite entry point
```

**Expected outcome**: 100% of previously-passing bash tests still pass;
the three new test files pass; `go test ./... -race` in `llmctld/` still
passes with zero regressions.
