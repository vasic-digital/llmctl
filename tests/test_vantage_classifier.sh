#!/usr/bin/env bash
# test_vantage_classifier.sh - the skip classifier of tests/test_vantage.sh is proven on a positive and a negative sample,
# and a regressed classifier is caught by its self-check (C3-17). Needs neither podman nor go.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
source "${LLMCTL_ROOT}/tests/vantage_classifier.sh"

rc=0; vantage_classifier_selfcheck 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 0 "${rc}" "the real classifier passes its own self-check"
assert_eq 0 "$(wc -c <"${TEST_TMP}/sc.err" | tr -d ' ')" "...silently (no output before the skip decision)"
# shellcheck disable=SC2218  # defined in the sourced tests/vantage_classifier.sh; the later redefinitions below are deliberate mutants
r="$(no_image_skip_reason "${VANTAGE_CANNED_NOIMAGE}")"
assert_contains "${r}" "podman pull docker.io/library/alpine:3.20" "positive sample: the reason carries the exact pull command"

# a regressed classifier that matches EVERY failure would turn real defects into SKIPs: the self-check must refuse it
no_image_skip_reason() { printf "tried: gcr.io/distroless/static-debian12:nonroot docker.io/library/alpine:3.20 fix: podman pull docker.io/library/alpine:3.20"; return 0; }
rc=0; vantage_classifier_selfcheck 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "a match-everything classifier FAILS the self-check"
assert_file_contains "${TEST_TMP}/sc.err" "unrelated 'up' failure" "...naming the negative sample it wrongly accepted"
# a regressed classifier that matches NOTHING would turn the benign gap into a FAIL (and hide the prerequisite hint)
no_image_skip_reason() { return 1; }
rc=0; vantage_classifier_selfcheck 2>"${TEST_TMP}/sc.err" || rc=$?
assert_eq 1 "${rc}" "a match-nothing classifier FAILS the self-check"
assert_file_contains "${TEST_TMP}/sc.err" "does not classify the canned no-image stderr" "...naming the positive sample it missed"
test_finish
