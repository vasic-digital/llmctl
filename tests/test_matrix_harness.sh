#!/usr/bin/env bash
# test_matrix_harness.sh - end-to-end test of the client-by-call matrix HARNESS (T055/T056, runner side).
#
# Drives tests/matrix/run.py against the self-contained reference HTTPS server (class stand-in: this
# proves the HARNESS and every CLIENT adapter work; it is NOT evidence about the decision gateway).
# Asserts: matrix completeness (every inventory row x every available client), evidence chain +
# manifest + leak scan (with control needle), the negative TLS suite, and three mutations:
#   M1 a deliberately broken client adapter makes the run FAIL,
#   M2 removing a case from an inventory copy is detected,
#   M3 tampering with a finished run is detected by `run.py --check`.
# Set MATRIX_WITH_SDK=1 to also run the typesafe SDK adapters (needs network + uv + npm).
# Bytecode is never written; every temp directory is removed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}" || exit 1
export PYTHONDONTWRITEBYTECODE=1

for need in python3 go bash; do
  command -v "${need}" >/dev/null 2>&1 || { echo "SKIP-SUITE: ${need} not installed (matrix harness test not run)"; exit 0; }
done

TMP="$(mktemp -d -t llmctl-matrix-test-XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT
fails=0
ok()   { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fails=$((fails+1)); }
RUN="python3 -B ${ROOT}/tests/matrix/run.py"
INV="${ROOT}/specs/009-jev-decision-models/contracts/endpoint-inventory.tsv"
py() { python3 -B -c "$@"; }

# ---------------------------------------------------------------- 1. full matrix
CLIENTS="curl,python-urllib,python-requests,node-fetch,go-nethttp,chromium"
EXTRA=()
[[ "${MATRIX_WITH_SDK:-0}" == "1" ]] && EXTRA+=(--with-sdk)
${RUN} --clients "${CLIENTS}" "${EXTRA[@]+"${EXTRA[@]}"}" --allow-env-gaps --run-dir "${TMP}/full" >"${TMP}/full.out" 2>&1 && rc=0 || rc=$?
tail -n 30 "${TMP}/full.out"
M="${TMP}/full/matrix.json"
[[ -f "${M}" ]] || { bad "no matrix.json produced (rc=${rc})"; echo "SUMMARY: ${fails} failure(s)"; exit 1; }

# the only tolerated failures with SDKs on: EP-030 (documented SDK wire-shape finding for GET /v1/models)
read -r verdict nfail < <(py "
import json
m=json.load(open('${M}'))
f=[c for c in m['cells'] if c['result']=='fail']
allowed={('EP-030','typesafe-sdk-py'),('EP-030','typesafe-sdk-js')}
unexpected=[c for c in f if (c['case_id'],c['client']) not in allowed]
print(m['verdict'], len(unexpected))")
if [[ "${nfail}" == "0" ]]; then ok "no unexpected failing cell (verdict=${verdict}, runner rc=${rc})"; else bad "${nfail} unexpected failing cells"; fi
if [[ "${MATRIX_WITH_SDK:-0}" != "1" && "${rc}" != "0" ]]; then bad "runner exit ${rc} for an all-pass matrix"; fi

# independent completeness recomputation (does not reuse the runner's checker)
out="$(py "
import json,csv
m=json.load(open('${M}'))
inv=[r['case_id'] for r in csv.DictReader(open('${INV}'),delimiter='\t')]
clients=list(m['clients'])
have={(c['case_id'],c['client']) for c in m['cells']}
miss=[(i,k) for i in inv for k in clients if (i,k) not in have]
assert not miss, miss
assert len(m['cells'])==len(inv)*len(clients), (len(m['cells']),len(inv),len(clients))
print(len(inv),'cases x',len(clients),'clients =',len(m['cells']),'cells, none missing')")" && ok "${out}" || bad "completeness: ${out}"

# every programmatic client passed every applicable case (floor of FR-069), and browser/others only in declared classes
out="$(py "
import json
m=json.load(open('${M}'))
prog={'curl','python-urllib','python-requests','node-fetch','go-nethttp'}
bad=[]
for c in m['cells']:
    if c['client'] in prog and c['result']=='fail': bad.append((c['case_id'],c['client']))
    if c['result']=='not-exercised' and c['reason_class'] not in ('browser-non-get','transport-not-per-client','sdk-outside-subset','sdk-no-ca-trust','env-gap'):
        bad.append(('undeclared',c['case_id'],c['client'],c['reason_class']))
    if c['result']=='not-exercised' and c['reason_class']=='env-gap': print('NOTE env-gap:',c['case_id'],c['client'],c['reason'][:90])
assert not bad, bad
print('programmatic clients: 0 failing cells; every not-exercised cell is in a declared class')")" && ok "${out}" || bad "floors: ${out}"

# real clients really ran (not just a green table): >0 passes per available client
out="$(py "
import json,collections
m=json.load(open('${M}'))
n=collections.Counter(c['client'] for c in m['cells'] if c['result']=='pass')
print(dict(n))
need={'curl':30,'python-urllib':30,'node-fetch':30,'go-nethttp':30}
low={k:n[k] for k,v in need.items() if n[k]<v}
assert not low, low")" && ok "per-client pass counts: ${out}" || bad "client pass counts too low: ${out}"

ls=$(py "import json;m=json.load(open('${M}'));print(m['leak_scan']['status'], m['leak_scan']['control_needle_found'])")
[[ "${ls}" == "clean True" ]] && ok "leak scan clean with control needle found" || bad "leak scan: ${ls}"
if [[ "${MATRIX_WITH_SDK:-0}" == "1" ]]; then
  # with SDKs on the EP-030 findings (G-038) are gone: GET /v1/models serves the SDK shape, so --check is fully clean
  ${RUN} --check "${TMP}/full" --allow-env-gaps >"${TMP}/check.out" 2>&1 \
    && py "import json;r=json.load(open('${TMP}/check.out'));assert r['problems']==[], r" 2>/dev/null \
    && ok "run.py --check: chain, manifest, cells<->evidence, completeness consistent; no SDK findings left (G-038)" || { bad "run.py --check reports problems with the SDKs enabled"; cat "${TMP}/check.out"; }
else
  ${RUN} --check "${TMP}/full" --allow-env-gaps >"${TMP}/check.out" 2>&1 && ok "run.py --check: chain, manifest, cells<->evidence, completeness all consistent" || { bad "run.py --check failed"; cat "${TMP}/check.out"; }
fi

# ------------------------------------------- 2. M1: deliberately broken client adapter
cp -r "${ROOT}/tests/matrix/clients" "${TMP}/clients_broken"
# the broken curl adapter reports success for every call (a client that lies)
sed -i 's|^echo "STATUS \$code"|echo "STATUS 200"|' "${TMP}/clients_broken/curl.sh"
grep -q '^echo "STATUS 200"' "${TMP}/clients_broken/curl.sh" || bad "mutation M1 did not apply"
MATRIX_CLIENT_DIR="${TMP}/clients_broken" ${RUN} --clients curl --run-dir "${TMP}/m1" >"${TMP}/m1.out" 2>&1 && rc1=0 || rc1=$?
nf1=$(py "import json;m=json.load(open('${TMP}/m1/matrix.json'));print(sum(c['result']=='fail' for c in m['cells']))" 2>/dev/null || echo 0)
if [[ ${rc1} -ne 0 && ${nf1} -gt 5 ]]; then ok "M1 broken client adapter: run FAILS (rc=${rc1}, ${nf1} failing cells)"; else bad "M1 broken adapter was NOT detected (rc=${rc1}, failing cells=${nf1})"; fi
# control: the unbroken copy of the same adapter passes the same command
MATRIX_CLIENT_DIR="${ROOT}/tests/matrix/clients" ${RUN} --clients curl --run-dir "${TMP}/m1ctl" >"${TMP}/m1ctl.out" 2>&1 \
  && ok "M1 control: unbroken curl adapter passes the identical command" || { bad "M1 control failed"; tail -n 20 "${TMP}/m1ctl.out"; }

# ------------------------------------------- 3. M2: row removed from / added to the inventory copy
head -n 1 "${INV}" >"${TMP}/inv_removed.tsv"; tail -n +2 "${INV}" | grep -v '^EP-040	' >>"${TMP}/inv_removed.tsv"
[[ $(wc -l <"${TMP}/inv_removed.tsv") -eq $(( $(wc -l <"${INV}") - 1 )) ]] || bad "M2 inventory mutation did not remove exactly one row"
${RUN} --clients curl --inventory "${TMP}/inv_removed.tsv" --run-dir "${TMP}/m2" >"${TMP}/m2.out" 2>&1 && rc2=0 || rc2=$?
if [[ ${rc2} -ne 0 ]] && grep -q "EP-040 exists in the harness but not in the inventory" "${TMP}/m2.out"; then ok "M2 removed inventory row EP-040 detected"; else bad "M2 removal not detected (rc=${rc2})"; tail -n 15 "${TMP}/m2.out"; fi
cp "${INV}" "${TMP}/inv_added.tsv"; printf 'EP-999\tGET\t/v1/new\tkey\tnew untested call\t200\t-\tFR-069\n' >>"${TMP}/inv_added.tsv"
${RUN} --clients curl --inventory "${TMP}/inv_added.tsv" --run-dir "${TMP}/m2b" >"${TMP}/m2b.out" 2>&1 && rc2b=0 || rc2b=$?
if [[ ${rc2b} -ne 0 ]] && grep -q "EP-999 has no handler" "${TMP}/m2b.out"; then ok "M2 inventory row without a test (EP-999) detected"; else bad "M2b addition not detected (rc=${rc2b})"; fi

# ------------------------------------------- 4. M3: tampering with a finished run
cp -r "${TMP}/full" "${TMP}/tamper"
py "
import json
p='${TMP}/tamper/matrix.json'
m=json.load(open(p))
for c in m['cells']:
    if c['result']=='fail': continue
    c['result']='fail' if c['result']=='pass' else c['result']; break
json.dump(m,open(p,'w'),indent=1,sort_keys=True)"
${RUN} --check "${TMP}/tamper" --allow-env-gaps >"${TMP}/m3.out" 2>&1 && bad "M3 tampered matrix.json passed --check" || ok "M3 tampered matrix.json rejected by --check"
cp -r "${TMP}/full" "${TMP}/tamper2"
sed -i '3s/"result": "pass"/"result": "fail"/' "${TMP}/tamper2/evidence.jsonl"
${RUN} --check "${TMP}/tamper2" --allow-env-gaps >"${TMP}/m3b.out" 2>&1 && bad "M3 edited evidence line passed --check" || ok "M3 edited evidence.jsonl rejected (chain/manifest)"
cp -r "${TMP}/full" "${TMP}/tamper3"
# truncate the tail: drop the last evidence line AND keep the old SHA256SUMS -> must be rejected
sed -i '$ d' "${TMP}/tamper3/evidence.jsonl"
${RUN} --check "${TMP}/tamper3" --allow-env-gaps >"${TMP}/m3c.out" 2>&1 && bad "M3 truncated evidence passed --check" || ok "M3 truncated evidence.jsonl rejected"

# leak-scan control: a planted key-like token in a copy of the evidence is caught by the same scanner
cp -r "${TMP}/full" "${TMP}/leak"
printf 'Authorization: Bearer %s\n' "sk-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" >"${TMP}/leak/raw/planted.txt"
python3 -B -m tests.evidence.leak_scan "${TMP}/leak" >/dev/null 2>&1 && bad "planted token NOT found by the leak scanner" || ok "leak scanner finds a planted token (exit non-zero)"

# ------------------------------------------- 5. negative TLS suite (FR-070)
python3 -B "${ROOT}/tests/matrix/negative_tls.py" --run-dir "${TMP}/neg" >"${TMP}/neg.out" 2>&1 && rcn=0 || rcn=$?
tail -n 12 "${TMP}/neg.out"
[[ ${rcn} -eq 0 ]] && ok "negative TLS: host name, expired, untrusted, altered, plain HTTP, TLS1.0/1.1, weak cipher all refused as documented (with positive controls)" || bad "negative TLS suite failed (rc=${rcn})"
py "
import json
n=json.load(open('${TMP}/neg/negative_tls.json'))
need={'hostname-not-covered','expired-certificate','untrusted-authority','altered-certificate','plain-http-to-tls-port','tls1.0-only-client','tls1.1-only-client','weak-cipher-only-client','control'}
miss=need-set(n['cases']); assert not miss, miss" && ok "negative TLS covers every FR-070 case" || bad "negative TLS case list incomplete"
python3 -B -m tests.evidence.writer verify-chain "${TMP}/neg/evidence.jsonl" && ok "negative TLS evidence chain intact" || bad "negative TLS evidence chain broken"

# G-082: the refusal regexes accept BOTH curl TLS-backend wordings (recorded fixtures), and still
# reject an unrelated failure and a successful connection (no false positive).
FXD="${ROOT}/tests/fixtures/curl_gnutls"
if py "
import re,sys
sys.path.insert(0,'${ROOT}')
from tests.matrix import negative_tls as N
fx=lambda n: open('${FXD}/'+n+'.txt').read()
want={'untrusted':'untrusted-authority','altered':'altered-certificate','expired':'expired-certificate','wronghost':'hostname-not-covered',
      'openssl_untrusted':'untrusted-authority','openssl_expired':'expired-certificate','openssl_wronghost':'hostname-not-covered'}
for f,case in want.items():
    rx=N.NEG[case][2]
    assert re.search(rx,fx(f),re.I), (f,case)
# cross-check: a wrong-name line must not satisfy the expired case, a connection refused must satisfy none
assert not re.search(N.NEG['expired-certificate'][2],fx('wronghost'),re.I)
refused='curl rc=7 curl: (7) Failed to connect to localhost port 1 after 0 ms: Could not connect to server'
assert all(not re.search(v[2],refused,re.I) for v in N.NEG.values())
"; then ok "negative TLS regexes accept GnuTLS-curl and OpenSSL-curl wordings and reject an unrelated failure"; else bad "negative TLS regexes do not accept the recorded curl wordings"; fi

# ------------------------------------------- 6. harness-defect regressions (LAN run 2026-10-09)
python3 -B -m unittest tests.py.test_matrix_harness_fixes tests.py.test_matrix_harness_units tests.py.test_matrix_calibration_fields >"${TMP}/unit.out" 2>&1 \
  && ok "matrix harness unit tests (node piped-stdout 100 KB, --model, additive keys, failed-auth throttle) pass" || { bad "matrix harness unit tests failed"; tail -n 25 "${TMP}/unit.out"; }
# --model: every systemone request carries it (the stand-in serves the alias), the run still passes, matrix.json records it
${RUN} --clients python-urllib --model jev-latest --run-dir "${TMP}/model" >"${TMP}/model.out" 2>&1 && rcm=0 || rcm=$?
out="$(py "
import json
m=json.load(open('${TMP}/model/matrix.json'))
assert m['model']=='jev-latest', m['model']
assert m['verdict']=='PASS', m['verdict']
print('model recorded, verdict PASS')")" && [[ ${rcm} -eq 0 ]] && ok "run.py --model jev-latest: ${out}" || { bad "run.py --model run (rc=${rcm}): ${out}"; tail -n 15 "${TMP}/model.out"; }
# mutation M4: the node adapter reverted to exit-right-after-log must fail the 100 KB piped-stdout test
if command -v node >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
  cp -r "${ROOT}/tests/matrix/clients" "${TMP}/clients_m4"
  python3 -B - "${TMP}/clients_m4/node_https.mjs" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r"const finish = \(lines\) => \{.*?\n\};", "const finish = (lines) => { if (!done) { done = true; console.log(lines.join('\\n')); process.exit(0); } };", s, flags=re.S)
assert s2 != s
open(p, "w").write(s2)
PYEOF
  if MATRIX_NODE_CLIENT="${TMP}/clients_m4/node_https.mjs" python3 -B -m unittest -q tests.py.test_matrix_harness_fixes.NodePipedStdoutTests >"${TMP}/m4.out" 2>&1; then
    bad "M4 reverted node adapter was NOT detected by the 100 KB test"
  else
    ok "M4 reverted (exit-right-after-log) node adapter is rejected by the 100 KB piped-stdout test"
  fi
fi

# the entry scripts never write bytecode themselves, even run WITHOUT -B / PYTHONDONTWRITEBYTECODE: they import
# tests.evidence / tests.matrix, and a plain `python3 scripts/golden/run_golden.py` (the live evidence scripts run it
# that way) left tests/evidence/__pycache__ behind, which then failed the check below in an unrelated `make test`
# (2026-10-09). Probed only on a clean tree, so whatever appears was written by the probe itself.
if find "${ROOT}/tests/matrix" "${ROOT}/tests/evidence" -name '__pycache__' | grep -q .; then
  bad "bytecode-probe precondition: a __pycache__ already exists under tests/matrix or tests/evidence"
else
  for entry in scripts/golden/run_golden.py tests/matrix/run.py tests/matrix/negative_tls.py; do
    ( cd "${ROOT}" && env -u PYTHONDONTWRITEBYTECODE python3 "${entry}" --help >/dev/null 2>&1 ) || bad "${entry} --help failed"
    stray="$(find "${ROOT}/tests/matrix" "${ROOT}/tests/evidence" -name '__pycache__' 2>/dev/null)"
    if [[ -n "${stray}" ]]; then
      bad "plain python3 ${entry} wrote bytecode into the work tree: ${stray//$'\n'/ }"
      while IFS= read -r d; do rm -rf -- "${d}"; done <<<"${stray}"   # created by this probe (clean precondition)
    else
      ok "plain python3 ${entry} (no -B) writes no bytecode under tests/matrix or tests/evidence"
    fi
  done
fi

# no stray bytecode in the tree
if find "${ROOT}/tests/matrix" "${ROOT}/tests/evidence" -name '__pycache__' -o -name '*.pyc' | grep -q .; then bad "bytecode written into the work tree"; else ok "no __pycache__/.pyc written"; fi

echo "SUMMARY: ${fails} failure(s)"
[[ ${fails} -eq 0 ]] || exit 1
echo "  ok: matrix harness test: every check passed (0 failures)"
echo "matrix harness test OK"
