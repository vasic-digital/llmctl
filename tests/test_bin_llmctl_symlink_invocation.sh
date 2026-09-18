#!/usr/bin/env bash
# test_bin_llmctl_symlink_invocation.sh - bin/llmctl must resolve its real
# ../lib sibling directory even when invoked through a PATH symlink (the
# supported install pattern this project's other tools already use under
# ~/.local/bin, e.g. claude-* -> claude_toolkit/scripts/claude-*.sh) - not
# just when invoked by its own direct path. `dirname "${BASH_SOURCE[0]}"`
# alone resolves against the SYMLINK's own containing directory, not its
# real target's directory, which broke every subsequent `source
# "${LLMCTL_ROOT}/lib/*.sh"` call the moment bin/llmctl was symlinked
# somewhere else on the host (confirmed real repro this session: `ln -sf
# .../bin/llmctl ~/.local/bin/llmctl && llmctl status` failed with
# "/home/.../.local/lib/common.sh: No such file or directory").
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

symlink_dir="$(mktemp -d)"
trap 'rm -rf "${symlink_dir}"' EXIT

ln -s "${LLMCTL_ROOT}/bin/llmctl" "${symlink_dir}/llmctl"

out=""
rc=0
out="$("${symlink_dir}/llmctl" plan --json 2>&1)" || rc=$?

assert_eq 0 "${rc}" "invoking bin/llmctl via a PATH-style symlink exits 0"

case "${out}" in
  *"No such file or directory"*)
    assert_eq 0 1 "symlinked invocation did not fail resolving lib/ (got: ${out:0:200})"
    ;;
  *)
    assert_eq 0 0 "symlinked invocation did not fail resolving lib/"
    ;;
esac

echo "${out}" | grep -q '"tier"' \
  && assert_eq 0 0 "symlinked invocation produced real plan JSON output" \
  || assert_eq 0 1 "symlinked invocation produced real plan JSON output (got: ${out:0:200})"

test_finish
