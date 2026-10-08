# T093n - gated llama.cpp engine advance (FR-085, OD-1), executed on nezha.local

Date: 2026-10-07. Host: nezha.local (i7-1165G7, 8 threads, 62 GiB, ALT Linux, gcc 14.3.1, OpenSSL 3.5.4, CPU only). Key-auth SSH only. Work confined to `~/llmctl-work/` (deleted at the end, verified absent). Local repo untouched except this directory.

## 1. Tag chosen
- Pin: b10969 (391fac164), no /v1/systemone.
- Feature PR ggml-org/llama.cpp#29818, commit a4cb4c61fd9d9c2066c7c1747821d3d65b8943bd (2026-10-02), first tag b11361 (ancestor check verified).
- Follow-up fix #29903 "server: fix laya abort by limiting n_batch to n_ubatch", commit 1537a0a8b, first tag b11379. Julia-1/Laya are `laya`-type, so b11361 has a known abort for exactly the smallest candidates. Clef support (#29831, 99b95488c) first in b11371 (contained in b11379).
- **Chosen: b11379 = 1537a0a8b2f8711d840878b0a0677ab2213c882c** (2026-10-03), 392 commits above b10969.
- Newest tag seen: b11479 (42c787e8c, hours old, not built). Tags carry no stability flag; "newest stable containing the feature" interpreted as first tag with feature + its blocking fix + multi-day soak.

## 2. Build (CPU only, lib/engine.sh flags)
`cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=ON`; `cmake --build build --target llama-server -j4` under /usr/bin/time -v. Logs in raw/logs/.
Configure: x86 CPU backend -march=native, ggml 0.25.3, OpenSSL 3.5.4 found, OpenMP not found (warning, same on b10969), ccache present but cold (1.8% hits). BUILD_SHARED_LIBS=ON: llama-server is a 20 KB binary loading libllama*/libggml* from build/bin via RPATH. LLAMA_CURL is deprecated/ignored.
- b11379: wall 2:18 (first attempt killed at 16% by ssh teardown and resumed, slightly understated), user 471 s, build peak RSS 625 MB.
- b10969: wall 2:41, user 560 s, peak RSS 693 MB.

### HTTPS verdict (FR-072/FR-082): compiled in, proven at runtime
- CMakeCache LLAMA_OPENSSL:BOOL=ON; `ldd build/bin/libllama-common.so` lists libssl.so.3 + libcrypto.so.3.
- Runtime: --ssl-key-file/--ssl-cert-file with a throw-away self-signed cert: `curl -k https://127.0.0.1:<port>/health` 200; /v1/systemone over HTTPS 200; plain HTTP to the TLS port = reset (000).
- Post-build check for lib/engine.sh: `llama-server --help` is NOT proof (lists the ssl flags on both builds). Use `grep '^LLAMA_OPENSSL:BOOL=ON' build/CMakeCache.txt` plus `ldd build/bin/libllama-common.so | grep libssl` (llama-server itself does not link libssl directly), and/or a TLS handshake smoke. LLAMA_OPENSSL defaults ON upstream; without headers it silently has no HTTPS unless engine.sh passes it explicitly and checks.

## 3. Native decision endpoint (real run)
Candidate: ggml-org/Julia-1-GGUF Julia-1-Q8_0.gguf, 168,166,496 B (smallest native GGUF; Laya 449 MB, Kev-0.8B larger), revision 16fee17949206fbf58da9347daea44d792a81211. Size and sha256 1ea6a7e87156eeeda88cb7a36a61265b37ba7b993897b7289b99aea5b5e47069 match evidence/admission record. No HF_TOKEN used.
Server: `llama-server -m Julia-1-Q8_0.gguf --host 127.0.0.1 --port <ephemeral> --api-key-file <random 0600> -c 4096 -t 4 -np 1`. Request: noul + choice + score (raw/sys1.py). Response (raw/out/b11379-julia-systemone-0.json):
{"model":"models/Julia-1-Q8_0.gguf","answers":{"route":{"type":"choice","choice":"shipping","probabilities":{"billing":0.0142,"shipping":0.9552,"technical":0.0306},"confidence":0.9328},"angry":{"type":"noul","noul":0.6671},"urgency":{"type":"score","score":1.2578,"legend":{"0":"can wait","1":"this week","2":"today","3":"right now"},"probabilities":{"0":6.3e-05,"1":0.7427,"2":0.2567,"3":0.0006},"confidence":0.7421}},"usage":{"input_tokens":110,"output_tokens":0}}
- Wire shape matches contracts/openapi.yaml (map-shaped answers, usage output_tokens 0). `model` echoes the local file path; the gateway must rewrite it. The model routed a "charged twice" message to `shipping` (0.955): smoke answers are not quality evidence for G10.
- Determinism: 8/8 byte-identical in one run; a second server restart reproduced identical bytes (cmp). PASS.
- No key -> 401. RSS ~325-339 MB (168 MB model, ctx 4096).
- Single-option `choice` accepted (200, p=1.0): gateway must enforce >=2 options itself.
- Chat model on new build -> /v1/systemone = 501 "This model is not a decision model".
- Upstream bug #30073 reproduced: ~2118-token state at default batch 512 -> HTTP 500 "input (2118 tokens) is too large ... increase the physical batch size (current batch size: 512)". Mitigation proven: `-c 8192 -b 4096 -ub 4096` -> 200. Launcher must set -b/-ub >= max state tokens; gateway should map this engine 500 to its 422 (state over budget).

## 4. Old pin proof
b10969 built with identical flags.
- Julia-1 on b10969 does not load: `error loading model vocabulary: unknown pre-tokenizer type: 'mmbert'` -> failed to load model.
- POST /v1/systemone on b10969 (with Llama-3.2-3B): 404 x8 `{"error":{"message":"File Not Found","type":"not_found_error","code":404}}` (raw/out/b10969-chat-systemone-0.json).
The advance is REQUIRED for any native-path candidate.

## 5. Chat regression subset
Model: catalog `small` Llama-3.2-3B-Instruct-Q4_K_M.gguf (2,019,377,600 B, sha256 6c99cc00...74f87d = catalog, verified). temperature 0, seed 42, cache_prompt off, each twice per build.
- /v1/chat/completions "first five primes": b10969 `2, 3, 5, 7, 11`; b11379 `2, 3, 5, 7, 11`.
- /completion "The capital of France is" (24 tok): identical text on both (" Paris. The capital of France is located in the Ile-de-France region. The capital of France is also known").
- Repeats identical within each build. Server peak RSS (ctx 2048): 3,635,272 kB vs 3,631,988 kB.
Result: no behavioural difference. Scope: CPU only, one small model, two prompts; not CUDA, MoE, vision, colibri or perf.

## 6. Risks
1. 392-commit jump; only a CPU subset tested. Run `make test` and a real CUDA retest of all existing profiles (vision/mmproj, MoE, KV-quant ctx defaults) before committing the pin.
2. #30073 open at b11379: profile defaults need -b/-ub for decision engines.
3. Shared-lib build with RPATH into build tree: engine.sh install/run must keep build/bin intact.
4. LLAMA_OPENSSL default-ON: pass explicitly and verify via CMakeCache+ldd.
5. Clef-Flash #30064 stays HOLD; Clef not tested here.
6. Upstream moves daily (b11479 exists); pin a fixed tag and re-verify.
7. nezha side effects: `ccache -z` was run once (stats reset only); ccache holds objects from these builds. Nothing else outside ~/llmctl-work touched; all processes stopped (they also die with the ssh session).

## 7. Recommendation: GO (conditional) to move the submodule pin to b11379
Conditions: (a) gated by `make test` + CUDA retest on this host; (b) engine.sh adds -DLLAMA_OPENSSL=ON and the CMakeCache+ldd post-build check; (c) -b/-ub for decision profiles; (d) gateway enforces >=2 options and maps engine 500 "too large" to 422. Do NOT use b11361 (laya abort). b11479 untested.

## 8. CUDA build commands for this host (not run)
git -C submodules/llama.cpp fetch --tags origin
git -C submodules/llama.cpp checkout b11379      # pin bump is the main agent's/operator's decision
cd submodules/llama.cpp
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DGGML_NATIVE=ON -DLLAMA_OPENSSL=ON -DCMAKE_CUDA_ARCHITECTURES=120   # RTX 5090 sm_120; confirm with nvidia-smi --query-gpu=compute_cap --format=csv, or omit to autodetect
cmake --build build --config Release --target llama-server -j8   # respect Constitution 12.6/12.12 headroom
grep '^LLAMA_OPENSSL:BOOL=ON' build/CMakeCache.txt && ldd build/bin/libllama-common.so | grep libssl
build/bin/llama-server --version      # expect: build 11379, commit 1537a0a8b

## 9. Artefacts (raw/)
raw/logs (configure logs both tags, key CMake options, build logs/time), raw/out (Julia responses runs 1+2, old-pin 404, chat-regression JSON, large-input 500, server logs), raw/*.sh + raw/sys1.py (exact test scripts). Model files, API key file and TLS key/cert not copied; no secret recorded.
