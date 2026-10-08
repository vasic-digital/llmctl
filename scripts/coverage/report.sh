#!/usr/bin/env bash
# report.sh - measure and REPORT code coverage for llmctl (Constitution 11.4.224; operator decision OD-15:
# measure and report only, there is NO gate here).
#
# Stages (all optional via --stages, default "go,bash,python"):
#   go      go test -coverprofile for the root module and for llmctld (unit packages; the ~400 s
#           llmctld/test/integration package is NOT run), `go tool cover -func`
#   bash    zero-tooling PS4 line-trace coverage of lib/*.sh, bin/llmctl, scripts/*.sh, scripts/release/*.sh
#           by running the cheap bash suites (tests/test_*.sh minus scripts/coverage/bash_suites_excluded.txt)
#   python  coverage.py (scratch venv, pip install coverage) over tests/py + the python-backed bash suites
#           for scripts/golden/*.py lib/onnx_server.py scripts/release/scan_archive.py tests/evidence/*.py
# then scripts/coverage/make_report.py renders COVERAGE-REPORT.md next to the raw summaries.
#
# Usage: report.sh [--out DIR] [--work DIR] [--stages LIST] [--budget SECONDS] [--suite-timeout SECONDS] [--only-suites REGEX]
# Defaults: --out specs/009-jev-decision-models/evidence/coverage  --work $(mktemp -d)  --budget 2400
#           --suite-timeout 600.  Everything heavy runs under `nice -n 10`, at most 2 parallel processes;
# no file is written into the repository tree except the final summaries under --out (profiles, fifos,
# venvs and raw traces live in --work).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="${ROOT}/scripts/coverage"
OUT="${ROOT}/specs/009-jev-decision-models/evidence/coverage"
WORK=""
STAGES="go,bash,python"
BUDGET=2400
SUITE_TIMEOUT=600
ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;
    --work) WORK="$2"; shift 2;;
    --stages) STAGES="$2"; shift 2;;
    --budget) BUDGET="$2"; shift 2;;
    --suite-timeout) SUITE_TIMEOUT="$2"; shift 2;;
    --only-suites) ONLY="$2"; shift 2;;
    -h|--help) sed -n 2,22p "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "report.sh: unknown argument: $1" >&2; exit 2;;
  esac
done
[[ -n "${WORK}" ]] || WORK="$(mktemp -d "${TMPDIR:-/tmp}/llmctl-cov.XXXXXX")"
mkdir -p "${OUT}" "${WORK}"
has() { [[ ",${STAGES}," == *",$1,"* ]]; }
log() { printf '[coverage %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
NICE=(nice -n 10)
START=$(date +%s)

# ---------------------------------------------------------------- go
if has go; then
  command -v go >/dev/null 2>&1 || { echo "report.sh: go not installed" >&2; exit 2; }
  log "go: root module"
  ( cd "${ROOT}" && GOFLAGS=-mod=readonly "${NICE[@]}" go test -p 2 -count=1 -coverprofile="${WORK}/go-root.out" ./... ) >"${WORK}/go-root.log" 2>&1 || log "go root: some package FAILED (see ${OUT}/go-root.log)"
  log "go: llmctld module (unit packages; test/integration NOT run)"
  mapfile -t LLMCTLD_PKGS < <(cd "${ROOT}/llmctld" && go list ./... | grep -v '/test/integration')
  ( cd "${ROOT}/llmctld" && GOFLAGS=-mod=readonly "${NICE[@]}" go test -p 2 -count=1 -coverprofile="${WORK}/go-llmctld.out" "${LLMCTLD_PKGS[@]}" ) >"${WORK}/go-llmctld.log" 2>&1 || log "go llmctld: some package FAILED (see ${OUT}/go-llmctld.log)"
  ( cd "${ROOT}" && go tool cover -func="${WORK}/go-root.out" ) >"${WORK}/go-root.func.txt" 2>&1 || true
  ( cd "${ROOT}/llmctld" && go tool cover -func="${WORK}/go-llmctld.out" ) >"${WORK}/go-llmctld.func.txt" 2>&1 || true
fi

# ---------------------------------------------------------------- python venv (shared by python + bash stages)
VENV=""
if has python; then
  VENV="${WORK}/venv"
  if [[ ! -x "${VENV}/bin/python" ]]; then
    log "python: creating scratch venv + installing coverage.py"
    # python3-venv/ensurepip is absent on some hosts (Debian/Ubuntu): prefer uv, fall back to venv+pip
    if command -v uv >/dev/null 2>&1; then
      { uv venv --quiet "${VENV}" && uv pip install --quiet --python "${VENV}/bin/python" coverage; } >"${WORK}/pip.log" 2>&1 \
        || { echo "report.sh: uv venv/install coverage failed (see ${WORK}/pip.log)" >&2; exit 2; }
    else
      { python3 -m venv "${VENV}" && "${VENV}/bin/pip" install --quiet coverage; } >"${WORK}/pip.log" 2>&1 \
        || { echo "report.sh: venv/pip install coverage failed (see ${WORK}/pip.log)" >&2; exit 2; }
    fi
  fi
  SITE="$("${VENV}/bin/python" -c 'import sysconfig;print(sysconfig.get_paths()["purelib"])')"
  printf 'import coverage; coverage.process_startup()\n' >"${SITE}/llmctl_cov_subprocess.pth"
  cat >"${WORK}/coveragerc" <<RC
[run]
data_file = ${WORK}/pycov/.coverage
parallel = True
relative_files = False
source =
    ${ROOT}/scripts/golden
    ${ROOT}/lib
    ${ROOT}/scripts/release
    ${ROOT}/tests/evidence
    ${ROOT}/scripts/coverage
[report]
skip_empty = False
RC
  mkdir -p "${WORK}/pycov"
fi

# ---------------------------------------------------------------- bash (+ python subprocess data)
if has bash; then
  # safety net: container/service managers must never be reached by a coverage run
  BLOCK="${WORK}/blockbin"; mkdir -p "${BLOCK}"
  for c in systemctl podman docker launchctl loginctl; do
    # shellcheck disable=SC2016 # $0/$* must expand when the STUB runs, not now
    printf '#!/bin/sh\necho "$0 $*" >> "%s/blocked-calls.log"\nexit 1\n' "${WORK}" >"${BLOCK}/${c}"; chmod +x "${BLOCK}/${c}"
  done
  FIFO="${WORK}/trace.fifo"; rm -f "${FIFO}"; mkfifo "${FIFO}"
  TARGETS=()
  for f in "${ROOT}"/lib/*.sh "${ROOT}/bin/llmctl" "${ROOT}"/scripts/*.sh "${ROOT}"/scripts/release/*.sh; do [[ -f "$f" ]] && TARGETS+=("$f"); done
  printf '%s\n' "${TARGETS[@]}" >"${WORK}/bash-targets.txt"
  targs=(); for t in "${TARGETS[@]}"; do targs+=(--target "$t"); done
  python3 -B "${HERE}/bash_line_coverage.py" collect --fifo "${FIFO}" --out "${WORK}/bash-hits.json" --root "${ROOT}" "${targs[@]}" &
  COLLECTOR=$!
  : >"${WORK}/suites.tsv"
  declare -A EXCL=()
  while IFS='|' read -r n r; do
    n="${n%"${n##*[![:space:]]}"}"; n="${n#"${n%%[![:space:]]*}"}"; [[ -z "${n}" || "${n}" == \#* ]] && continue
    r="${r#"${r%%[![:space:]]*}"}"; EXCL["${n}"]="${r}"
  done <"${HERE}/bash_suites_excluded.txt"
  for t in "${ROOT}"/tests/test_*.sh; do
    name="$(basename "${t}")"
    if [[ -n "${EXCL[${name}]+x}" ]]; then printf '%s\tEXCLUDED\t0\t%s\n' "${name}" "${EXCL[${name}]}" >>"${WORK}/suites.tsv"; continue; fi
    if [[ -n "${ONLY}" && ! "${name}" =~ ${ONLY} ]]; then printf '%s\tNOT-RUN\t0\tfiltered out by --only-suites\n' "${name}" >>"${WORK}/suites.tsv"; continue; fi
    if (( $(date +%s) - START > BUDGET )); then printf '%s\tNOT-RUN\t0\tbudget of %ss exhausted\n' "${name}" "${BUDGET}" >>"${WORK}/suites.tsv"; continue; fi
    s0=$(date +%s)
    log "bash suite: ${name}"
    rc=0
    ( cd "${ROOT}" && env BASH_ENV="${HERE}/trace_init.sh" LLMCTL_COV_FIFO="${FIFO}" \
        PATH="${BLOCK}:${VENV:+${VENV}/bin:}${PATH}" ${VENV:+COVERAGE_PROCESS_START="${WORK}/coveragerc"} \
        "${NICE[@]}" timeout "${SUITE_TIMEOUT}" bash "${t}" ) >"${WORK}/suite-${name}.log" 2>&1 || rc=$?
    printf '%s\trc=%s\t%s\t%s\n' "${name}" "${rc}" "$(( $(date +%s) - s0 ))" "$(grep -m1 '^SKIP-SUITE' "${WORK}/suite-${name}.log" || true)" >>"${WORK}/suites.tsv"
  done
  kill -TERM "${COLLECTOR}" 2>/dev/null || true
  wait "${COLLECTOR}" 2>/dev/null || true
  python3 -B "${HERE}/bash_line_coverage.py" report --hits "${WORK}/bash-hits.json" --out "${WORK}/bash-report.json" "${TARGETS[@]}"
  [[ -f "${WORK}/blocked-calls.log" ]] && cp "${WORK}/blocked-calls.log" "${OUT}/bash-blocked-calls.log" || : >"${OUT}/bash-blocked-calls.log"
fi

# ---------------------------------------------------------------- python unit tier
if has python; then
  log "python: unit tier under coverage.py"
  ( cd "${ROOT}" && env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${ROOT}/lib" COVERAGE_PROCESS_START="${WORK}/coveragerc" \
      PATH="${VENV}/bin:${PATH}" "${NICE[@]}" "${VENV}/bin/python" -B -m coverage run --rcfile="${WORK}/coveragerc" \
      -m unittest discover -s tests/py -p 'test_*.py' -t . ) >"${WORK}/py-unit.log" 2>&1 || log "python unit tier reported failures (see py-unit.log)"
  ( cd "${WORK}/pycov" && "${VENV}/bin/python" -m coverage combine --rcfile="${WORK}/coveragerc" >/dev/null 2>&1 || true
    "${VENV}/bin/python" -m coverage json --rcfile="${WORK}/coveragerc" -o "${WORK}/py-cov.json" >/dev/null 2>&1 || true
    "${VENV}/bin/python" -m coverage report --rcfile="${WORK}/coveragerc" >"${WORK}/py-cov.txt" 2>&1 || true )
fi

# ---------------------------------------------------------------- render
log "rendering report into ${OUT}"
cp -f "${WORK}"/go-root.func.txt "${WORK}"/go-llmctld.func.txt "${WORK}"/go-root.log "${WORK}"/go-llmctld.log "${WORK}"/py-cov.txt "${WORK}"/py-unit.log "${OUT}/" 2>/dev/null || true
[[ -f "${WORK}/suites.tsv" ]] && cp -f "${WORK}/suites.tsv" "${OUT}/bash-suites.tsv"
python3 -B "${HERE}/make_report.py" --root "${ROOT}" --work "${WORK}" --out "${OUT}" --exclusions "${ROOT}/tests/coverage_exclusions.txt" --elapsed "$(( $(date +%s) - START ))"
log "done: ${OUT}/COVERAGE-REPORT.md (raw work dir: ${WORK})"
