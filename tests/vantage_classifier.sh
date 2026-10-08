#!/usr/bin/env bash
# vantage_classifier.sh - sourced by tests/test_vantage.sh and tests/test_vantage_classifier.sh.
# Holds the classifier that decides whether a `vantage up` failure is the benign "no cached image" prerequisite
# gap (the suite SKIPs) or a real defect (the suite FAILs), and its self-check. C3-17: the SKIP decision is taken
# BEFORE any assertion, so a classifier that regressed to "match everything" would turn every rc=1 `up` failure into
# a SKIP on exactly the hosts that skip; the self-check (one positive, one negative sample) therefore runs silently
# BEFORE the skip decision.
set -euo pipefail

# no_image_skip_reason <stderr-text> -> reason on stdout, rc 0 when it IS the no-image case
no_image_skip_reason() {
  local err="$1" tried
  grep -q 'no usable local image' <<<"${err}" || return 1
  tried="$(grep -oE '[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+:[A-Za-z0-9._-]+: ' <<<"${err}" | sed 's/: $//' | awk '!s[$0]++' | tr '\n' ' ')"
  printf 'rootless podman works but no candidate image is cached locally (offline, --pull=never); tried: %s; fix: podman pull docker.io/library/alpine:3.20  (or set LLMCTL_VANTAGE_IMAGE to any image already in `podman images`)' "${tried:-none reported}"
}

VANTAGE_CANNED_NOIMAGE='vantage up: vantage: no usable local image (offline, --pull=never): gcr.io/distroless/static-debian12:nonroot: Error: image not known; docker.io/library/alpine:3.20: Error: image not known'
VANTAGE_CANNED_OTHER='vantage up: vantage: cannot start network: boom'

# vantage_classifier_selfcheck -> rc 0 when the classifier accepts the positive sample (naming every image tried and the
# pull command) AND rejects the negative one. Prints nothing; on failure prints one `  FAIL:` line to stderr.
vantage_classifier_selfcheck() {
  local r rc=0
  r="$(no_image_skip_reason "${VANTAGE_CANNED_NOIMAGE}")" || rc=$?
  if [[ ${rc} -ne 0 ]] || [[ "${r}" != *"gcr.io/distroless/static-debian12:nonroot docker.io/library/alpine:3.20"* ]] || [[ "${r}" != *"podman pull docker.io/library/alpine:3.20"* ]]; then
    echo "  FAIL: no_image_skip_reason does not classify the canned no-image stderr (rc=${rc}); refusing to use it to decide a SKIP" >&2
    return 1
  fi
  rc=0
  no_image_skip_reason "${VANTAGE_CANNED_OTHER}" >/dev/null 2>&1 || rc=$?
  if [[ ${rc} -ne 1 ]]; then
    echo "  FAIL: no_image_skip_reason classifies an unrelated 'up' failure as a missing prerequisite (rc=${rc}); refusing to use it to decide a SKIP" >&2
    return 1
  fi
  return 0
}
