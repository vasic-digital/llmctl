#!/usr/bin/env bash
# test_vision_golden_fixtures.sh - the golden screenshots of validation/suites/vision-golden-v1 are
# (a) byte-reproducible from scripts/vision/make_golden.py, (b) exactly the files the expectation file
# pins by sha256, and (c) really contain what the expectations claim, checked by an INDEPENDENT pixel
# oracle (own PNG decode via zlib + palette, connected components, colours, centroids) that shares no
# code with the generator. tesseract is deliberately NOT used as the text oracle: measured 2026-10-12,
# tesseract 5.5 misreads this 5x7 bitmap font (N->H, "42"->"43"), so it would be a noisy oracle.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT

GEN="${LLMCTL_ROOT}/scripts/vision/make_golden.py"
SUITE="${LLMCTL_ROOT}/validation/suites/vision-golden-v1"

echo "== 1. byte reproducibility: regenerate and compare with the committed fixtures"
out="$(python3 -I "${GEN}" --check "${SUITE}" 2>&1)" && rc=0 || rc=$?
printf '%s\n' "${out}" | sed 's/^/    | /'
assert_eq 0 "${rc}" "make_golden.py --check: every committed PNG is byte-identical to a fresh render"
assert_eq 11 "$(grep -c '^IDENTICAL ' <<<"${out}")" "11 fixtures (9 golden + 2 golden-bad) identical"
python3 -I "${GEN}" --out "${TEST_TMP}/a" >/dev/null
python3 -I "${GEN}" --out "${TEST_TMP}/b" >/dev/null
assert_eq "" "$(diff -r "${TEST_TMP}/a" "${TEST_TMP}/b" 2>&1 || true)" "two independent renders are identical"

echo "== 2. mutation: a changed glyph is detected by --check"
sed 's/"4": \["...#.", "..##."/"4": ["..##.", "..##."/' "${GEN}" > "${TEST_TMP}/gen_mut.py"
assert_eq 1 "$(grep -c '"4": \["..##.", "..##."' "${TEST_TMP}/gen_mut.py")" "mutant generator really differs"
rc=0; python3 -I "${TEST_TMP}/gen_mut.py" --check "${SUITE}" >"${TEST_TMP}/mut.out" 2>&1 || rc=$?
assert_eq 1 "${rc}" "mutated glyph -> --check exit 1"
assert_contains "$(cat "${TEST_TMP}/mut.out")" "DIFFERS 01_text_large.png" "the changed fixture is named"

echo "== 3. the expectation file pins exactly these bytes"
pins="$(python3 -I - "${SUITE}" <<'PY'
import hashlib, json, os, sys
d = json.load(open(os.path.join(sys.argv[1], "expectations.json")))
bad = [fx["image"] for fx in d["fixtures"]
       if hashlib.sha256(open(os.path.join(sys.argv[1], fx["image"]), "rb").read()).hexdigest() != fx["sha256"]]
roles = sorted({fx["role"] for fx in d["fixtures"]})
print(len(d["fixtures"]), sum(fx["role"] == "golden" for fx in d["fixtures"]),
      sum(fx["role"] == "control-bad" for fx in d["fixtures"]), "bad=%s" % bad, roles)
PY
)"
assert_eq "11 9 2 bad=[] ['control-bad', 'golden']" "${pins}" "11 fixtures pinned by sha256: 9 golden, 2 golden-bad"

echo "== 4. independent pixel oracle (own decoder, no generator code)"
oracle="$(python3 -I - "${SUITE}" <<'PY'
import os, struct, sys, zlib
def load(path):
    b = open(path, "rb").read()
    assert b[:8] == b"\x89PNG\r\n\x1a\n"
    i, chunks = 8, {}
    idat = b""
    while i < len(b):
        n = struct.unpack(">I", b[i:i+4])[0]; tag = b[i+4:i+8]; body = b[i+8:i+8+n]
        if tag == b"IDAT": idat += body
        else: chunks[tag] = body
        i += 12 + n
    w, h, depth, ctype = struct.unpack(">IIBB", chunks[b"IHDR"][:10])
    assert (depth, ctype) == (8, 3)
    pal = [tuple(chunks[b"PLTE"][k:k+3]) for k in range(0, len(chunks[b"PLTE"]), 3)]
    raw = zlib.decompress(idat)
    rows = []
    for y in range(h):
        line = raw[y*(w+1):(y+1)*(w+1)]
        assert line[0] == 0
        rows.append([pal[v] for v in line[1:]])
    return w, h, rows
def comps(rows, pred):
    h, w = len(rows), len(rows[0]); seen = [[False]*w for _ in range(h)]; out = []
    for y in range(h):
        for x in range(w):
            if pred(rows[y][x]) and not seen[y][x]:
                stack = [(y, x)]; seen[y][x] = True; pts = []
                while stack:
                    cy, cx = stack.pop(); pts.append((cy, cx))
                    for dy in (-1, 0, 1):
                        for dx in (-1, 0, 1):
                            ny, nx = cy+dy, cx+dx
                            if 0 <= ny < h and 0 <= nx < w and not seen[ny][nx] and pred(rows[ny][nx]):
                                seen[ny][nx] = True; stack.append((ny, nx))
                out.append(pts)
    return out
S = sys.argv[1]
dark = lambda c: sum(c) < 3*100
red = lambda c: c[0] > 180 and c[1] < 80 and c[2] < 80
blue = lambda c: c[2] > 180 and c[0] < 80
green = lambda c: c[1] > 130 and c[0] < 80 and c[2] < 100
w, h, r = load(os.path.join(S, "01_text_large.png")); print("size", w, h)
print("text_large_glyphs", len(comps(r, dark)))
_, _, r = load(os.path.join(S, "91_bad_wrong_content.png")); print("wrong_content_glyphs", len(comps(r, dark)))
_, _, r = load(os.path.join(S, "90_bad_blank.png")); print("blank_colours", len({c for row in r for c in row}))
_, _, r = load(os.path.join(S, "02_shapes_count.png"))
print("red_components", len(comps(r, red)), "blue_components", len(comps(r, blue)))
_, _, r = load(os.path.join(S, "09_color_blocks.png"))
cx = lambda pts: sum(p[1] for p in pts) / len(pts)
order = sorted([(cx(comps(r, red)[0]), "RED"), (cx(comps(r, green)[0]), "GREEN"), (cx(comps(r, blue)[0]), "BLUE")])
print("color_order", " ".join(n for _, n in order))
_, _, r = load(os.path.join(S, "07_dark_theme.png"))
lum = sum(sum(c) for row in r for c in row) / (3 * w * h)
print("dark_theme_mean_luma_below_64", lum < 64)
PY
)"
printf '%s\n' "${oracle}" | sed 's/^/    | /'
assert_contains "${oracle}" "size 896 896" "canvas is 896x896 (Gemma 3 SigLIP native input, no resampling)"
assert_contains "${oracle}" "text_large_glyphs 13" "01_text_large has 13 glyphs = ORANGE TIGER (11) + 42 (2)"
assert_contains "${oracle}" "wrong_content_glyphs 13" "91_bad_wrong_content has 13 glyphs = PURPLE HORSE (11) + 17 (2)"
assert_contains "${oracle}" "blank_colours 1" "90_bad_blank is a single colour (nothing drawn)"
assert_contains "${oracle}" "red_components 3 blue_components 2" "02_shapes_count really has 3 red and 2 blue shapes"
assert_contains "${oracle}" "color_order RED GREEN BLUE" "09_color_blocks really is red, green, blue left to right"
assert_contains "${oracle}" "dark_theme_mean_luma_below_64 True" "07_dark_theme really is dark"

test_finish
