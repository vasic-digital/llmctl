# Encoder-Class Decision Models — Verified HF Metadata

**Copied from the iteration-2 research brief (2026-10-06); original title: "Encoder model hashes (via hf-mirror.com HF API, ?blobs=true)". Raw HF API values behind the `decide-nli` / `decide-2b` / `decide-max` catalog pins and the Laya BYO-ONNX decision. Where this brief and the shipped catalog disagree, the catalog wins.**


## 1. MoritzLaurer/deberta-v3-large-zeroshot-v2.0

- commit: cf44676c28ba7312e5c5f8f8d2c22b3e0c9cdae2
- license: MIT
- Contains `onnx/model.onnx` (1.74 GB, fp32) but **NO quantized ONNX**; also `model.safetensors` (870 MB). No pytorch_model.bin.
- **Best CPU option: onnx/model.onnx** (only ONNX available; unquantized). Alternatively model.safetensors.
- Tokenizer: **SentencePiece** (DeBERTa-v3; `spm.model` + `tokenizer.json` fast tokenizer).
- ONNX model: producer `pytorch 2.2.2`, ir_version 7, **opset 12**, inputs `input_ids`/`attention_mask` (dynamic batch/seq), output `logits`.

```json
{
 "repo": "MoritzLaurer/deberta-v3-large-zeroshot-v2.0",
 "commit": "cf44676c28ba7312e5c5f8f8d2c22b3e0c9cdae2",
 "license": "mit",
 "files": [
  {
   "name": ".gitattributes",
   "size": 1519,
   "sha256": null
  },
  {
   "name": "README.md",
   "size": 21118,
   "sha256": null
  },
  {
   "name": "added_tokens.json",
   "size": 23,
   "sha256": null
  },
  {
   "name": "config.json",
   "size": 1019,
   "sha256": null
  },
  {
   "name": "model.safetensors",
   "size": 870176356,
   "sha256": "2031ec34340911b2cecf4f95f5e24db91b2a5d7ea0fa1e704e9cd6d61585e477"
  },
  {
   "name": "onnx/added_tokens.json",
   "size": 23,
   "sha256": null
  },
  {
   "name": "onnx/config.json",
   "size": 1036,
   "sha256": null
  },
  {
   "name": "onnx/model.onnx",
   "size": 1741985401,
   "sha256": "beded3d71421ceb718861af381d1a0d29037b3679c7350ebd41edbf79cdced1e"
  },
  {
   "name": "onnx/special_tokens_map.json",
   "size": 970,
   "sha256": null
  },
  {
   "name": "onnx/spm.model",
   "size": 2464616,
   "sha256": "c679fbf93643d19aab7ee10c0b99e460bdbc02fedf34b92b05af343b4af586fd"
  },
  {
   "name": "onnx/tokenizer.json",
   "size": 8649136,
   "sha256": null
  },
  {
   "name": "onnx/tokenizer_config.json",
   "size": 1256,
   "sha256": null
  },
  {
   "name": "special_tokens_map.json",
   "size": 970,
   "sha256": null
  },
  {
   "name": "spm.model",
   "size": 2464616,
   "sha256": "c679fbf93643d19aab7ee10c0b99e460bdbc02fedf34b92b05af343b4af586fd"
  },
  {
   "name": "tokenizer.json",
   "size": 8656646,
   "sha256": null
  },
  {
   "name": "tokenizer_config.json",
   "size": 1256,
   "sha256": null
  },
  {
   "name": "training_args.bin",
   "size": 4920,
   "sha256": "7174ebede2e9f6479616b183d5cfb9e7fe2b0e0ae1b8ae1566788b50cd1c9a6e"
  }
 ],
 "tokenizer_files": [
  {
   "name": "added_tokens.json",
   "size": 23,
   "sha256": null
  },
  {
   "name": "onnx/added_tokens.json",
   "size": 23,
   "sha256": null
  },
  {
   "name": "onnx/special_tokens_map.json",
   "size": 970,
   "sha256": null
  },
  {
   "name": "onnx/spm.model",
   "size": 2464616,
   "sha256": "c679fbf93643d19aab7ee10c0b99e460bdbc02fedf34b92b05af343b4af586fd"
  },
  {
   "name": "onnx/tokenizer.json",
   "size": 8649136,
   "sha256": null
  },
  {
   "name": "onnx/tokenizer_config.json",
   "size": 1256,
   "sha256": null
  },
  {
   "name": "special_tokens_map.json",
   "size": 970,
   "sha256": null
  },
  {
   "name": "spm.model",
   "size": 2464616,
   "sha256": "c679fbf93643d19aab7ee10c0b99e460bdbc02fedf34b92b05af343b4af586fd"
  },
  {
   "name": "tokenizer.json",
   "size": 8656646,
   "sha256": null
  },
  {
   "name": "tokenizer_config.json",
   "size": 1256,
   "sha256": null
  },
  {
   "name": "onnx/spm.model",
   "size": 2464616,
   "sha256": "c679fbf93643d19aab7ee10c0b99e460bdbc02fedf34b92b05af343b4af586fd"
  },
  {
   "name": "onnx/tokenizer.json",
   "size": 8649136,
   "sha256": null
  },
  {
   "name": "onnx/tokenizer_config.json",
   "size": 1256,
   "sha256": null
  }
 ]
}
```


## 2. convaiinnovations/laya

- commit: 7b928d828b7b0e022f929d9bd2e44165aa270148
- license: Apache-2.0
- ModernBERT-large backbone (395M) + decision head = 421M total; context 512 tokens (English).
- **NO ONNX exports in repo** — safetensors only. ONNX available at runtime via pip extra `laya[onnx]` (`ONNXAgent`, converts in-process).
- Tokenizer: **BPE** (ModernBERT `tokenizer.json`, no spm.model), three checkpoints: root (English), `multilingual/` (mmBERT-base, 322M, 8192 ctx), `typed-decisions/`.

```json
{
 "repo": "convaiinnovations/laya",
 "commit": "7b928d828b7b0e022f929d9bd2e44165aa270148",
 "license": "apache-2.0",
 "files": [
  {
   "name": ".gitattributes",
   "size": 1913,
   "sha256": null
  },
  {
   "name": "README.md",
   "size": 23187,
   "sha256": null
  },
  {
   "name": "assets/laya_benchmark.png",
   "size": 260892,
   "sha256": "e01e49f0d842b4616e44c4c9a0feb92a9ae45efeb533f8f838888715dc89c2b9"
  },
  {
   "name": "assets/laya_benchmark_common.png",
   "size": 278159,
   "sha256": "183b0b17e8d90e091582e415d9f1da0ef34b40c3db6ccd2c8bbfd2b9232b95a6"
  },
  {
   "name": "assets/laya_vs_jev.png",
   "size": 216412,
   "sha256": "5c06517ea7f3e5f3f84873ddaa3cb470f101ad0276f921c58886f8fb12fbe0a8"
  },
  {
   "name": "assets/laya_vs_jev_full.png",
   "size": 487005,
   "sha256": "ee47b751d524a0bb65159e026141b4ce70cc83d03b14df8ec68afbc7bcdb95b3"
  },
  {
   "name": "assets/logo-lockup-dark.png",
   "size": 27666,
   "sha256": null
  },
  {
   "name": "assets/logo-lockup-dark.svg",
   "size": 1590,
   "sha256": null
  },
  {
   "name": "assets/logo-lockup.png",
   "size": 26761,
   "sha256": null
  },
  {
   "name": "assets/logo-lockup.svg",
   "size": 1590,
   "sha256": null
  },
  {
   "name": "assets/logo-mark-ink.png",
   "size": 17378,
   "sha256": null
  },
  {
   "name": "assets/logo-mark-ink.svg",
   "size": 1320,
   "sha256": null
  },
  {
   "name": "assets/logo-mark-mono.svg",
   "size": 1380,
   "sha256": null
  },
  {
   "name": "assets/logo-mark.png",
   "size": 17962,
   "sha256": null
  },
  {
   "name": "assets/logo-mark.svg",
   "size": 1320,
   "sha256": null
  },
  {
   "name": "config.json",
   "size": 160,
   "sha256": null
  },
  {
   "name": "email_utils.py",
   "size": 3937,
   "sha256": null
  },
  {
   "name": "encoder/config.json",
   "size": 2083,
   "sha256": null
  },
  {
   "name": "eval/benchmark_comparison.png",
   "size": 467466,
   "sha256": "78e4b926bfca3950ff5441d1030a1453515973fbe5d7dd70a1c764a81f0d3d38"
  },
  {
   "name": "eval/reliability_eval_in.png",
   "size": 65436,
   "sha256": null
  },
  {
   "name": "eval/reliability_eval_zs.png",
   "size": 72014,
   "sha256": null
  },
  {
   "name": "eval/results.json",
   "size": 2976,
   "sha256": null
  },
  {
   "name": "eval/results.md",
   "size": 1608,
   "sha256": null
  },
  {
   "name": "model.safetensors",
   "size": 842609210,
   "sha256": "891102d372688fc2a094dac56a384bc537b87c63f21f9f3dac0be2b7cbc8d86c"
  },
  {
   "name": "multilingual/encoder/config.json",
   "size": 1938,
   "sha256": null
  },
  {
   "name": "multilingual/model.safetensors",
   "size": 643835514,
   "sha256": "9d628fd971b700382ac6f65920a86f149777b2e748e0c955fb3b19695aa8f204"
  },
  {
   "name": "multilingual/rl_agent_config.json",
   "size": 472,
   "sha256": null
  },
  {
   "name": "multilingual/tokenizer/tokenizer.json",
   "size": 34363188,
   "sha256": "609d8f4c067cd3950f88594c5a802616cea245823836ef5848ee4fc40aab5b6f"
  },
  {
   "name": "multilingual/tokenizer/tokenizer_config.json",
   "size": 524,
   "sha256": null
  },
  {
   "name": "rl_agent_api.py",
   "size": 4732,
   "sha256": null
  },
  {
   "name": "rl_agent_config.json",
   "size": 745,
   "sha256": null
  },
  {
   "name": "rl_common.py",
   "size": 19139,
   "sha256": null
  },
  {
   "name": "tokenizer/tokenizer.json",
   "size": 3583228,
   "sha256": null
  },
  {
   "name": "tokenizer/tokenizer_config.json",
   "size": 308,
   "sha256": null
  },
  {
   "name": "typed-decisions/encoder/config.json",
   "size": 2084,
   "sha256": null
  },
  {
   "name": "typed-decisions/model.safetensors",
   "size": 842609220,
   "sha256": "4fa56de72383a9d3efa9cfa78955733c81b9fc8067a587ca4beb82c78107a24e"
  },
  {
   "name": "typed-decisions/rl_agent_config.json",
   "size": 847,
   "sha256": null
  },
  {
   "name": "typed-decisions/tokenizer/tokenizer.json",
   "size": 3583228,
   "sha256": null
  },
  {
   "name": "typed-decisions/tokenizer/tokenizer_config.json",
   "size": 337,
   "sha256": null
  }
 ],
 "tokenizer_files": [
  {
   "name": "multilingual/tokenizer/tokenizer.json",
   "size": 34363188,
   "sha256": "609d8f4c067cd3950f88594c5a802616cea245823836ef5848ee4fc40aab5b6f"
  },
  {
   "name": "multilingual/tokenizer/tokenizer_config.json",
   "size": 524,
   "sha256": null
  },
  {
   "name": "tokenizer/tokenizer.json",
   "size": 3583228,
   "sha256": null
  },
  {
   "name": "tokenizer/tokenizer_config.json",
   "size": 308,
   "sha256": null
  },
  {
   "name": "typed-decisions/tokenizer/tokenizer.json",
   "size": 3583228,
   "sha256": null
  },
  {
   "name": "typed-decisions/tokenizer/tokenizer_config.json",
   "size": 337,
   "sha256": null
  }
 ]
}
```


### laya-serve (from README, quoted)

> `laya-serve` exposes the `Router` on the same `POST /v1/systemone` request and response shape as TypeSafe Jev...
> `pip install "laya[serve]"`; `LAYA_DEVICE=cuda LAYA_PRELOAD=1 laya-serve  # 0.0.0.0:8000, preloads the checkpoints`
> Request shape:
> ```
> curl -s localhost:8000/v1/systemone -H 'Content-Type: application/json' -d '{
>   "state": {"document": "I was charged twice. Please fix this ASAP."},
>   "questions": {"billing": {"type": "noul", "instructions": "Is this ticket about billing?"}}
> }'
> ```
> "It accepts every question shape the Jev API does (for example `criteria` as a list), ignores unknown fields, and returns a 422 naming the problem for a malformed question. It binds `0.0.0.0` with no authentication unless `LAYA_API_KEY` is set, in which case it requires `Authorization: Bearer <key>`."


## 3. alibiserikbay/JevK5-GGUF
- commit: ec67b0bfce5119a8b11a2cdb430bb43e3fa3e82a, license: apache-2.0
- **CONFIRMED**: `jevk5-2b-v0.2-Q8_0.gguf` = 2012012000 bytes, sha256 `17222f27a89273aca7614e34083a530b0d90cd51cffeb225c7acc8e79a7e0eba` — exact match.
- **CONFIRMED**: `jevk5-9b-v0.3.3-Q8_0.gguf` = 9527501280 bytes, sha256 `283de8fd216ad2200506d9236e574ddb5902b16e6a806a6fa38e9dd1b4286edf` — exact match.
- **Independent reference (huggingface.co, not the mirror), 2026-10-07**: both values were re-checked against `https://huggingface.co/api/models/alibiserikbay/JevK5-GGUF/tree/ec67b0bfce5119a8b11a2cdb430bb43e3fa3e82a?recursive=1` (size + `lfs.oid`); the record is `specs/009-jev-decision-models/evidence/pin-reverify.json` (all 10 decision-profile files match the catalog).

```json
{
 "repo": "alibiserikbay/JevK5-GGUF",
 "commit": "ec67b0bfce5119a8b11a2cdb430bb43e3fa3e82a",
 "license": "apache-2.0",
 "files": [
  {
   "name": ".gitattributes",
   "size": 2133,
   "sha256": null
  },
  {
   "name": "README.md",
   "size": 10850,
   "sha256": null
  },
  {
   "name": "SHA256SUMS",
   "size": 990,
   "sha256": null
  },
  {
   "name": "jevk5-2b-v0.2-Q8_0.gguf",
   "size": 2012012000,
   "sha256": "17222f27a89273aca7614e34083a530b0d90cd51cffeb225c7acc8e79a7e0eba"
  },
  {
   "name": "jevk5-4b-v0.2-Q4_K_M.gguf",
   "size": 2708803936,
   "sha256": "d4289a6d760e662da3aac4bce9b7a06c1806b6cfbeb1ae31947421e3e257e433"
  },
  {
   "name": "jevk5-4b-v0.2-Q8_0.gguf",
   "size": 4482402656,
   "sha256": "c66bb7a8f2e2e6ada6f7abd00e2b974e0118644820eb6fcf3edd4794c7bf1e44"
  },
  {
   "name": "jevk5-4b-v0.3-Q4_K_M.gguf",
   "size": 2708804000,
   "sha256": "94ca0d7745c47f79091b0892ca657c81d9dc9e4ed0238ba0a7ea261d8938c882"
  },
  {
   "name": "jevk5-4b-v0.3-Q5_K_M.gguf",
   "size": 3074986400,
   "sha256": "b1df9869dd14c0f5b243fa956dd985f0141c3d23ec4847da4c503c73c1050601"
  },
  {
   "name": "jevk5-4b-v0.3-Q8_0.gguf",
   "size": 4482402720,
   "sha256": "aea433883bc7ed399f2fbd539e53d2eac7caf71a946fe6650995a413979d4a30"
  },
  {
   "name": "jevk5-9b-v0.3-Q5_K_M.gguf",
   "size": 6467969504,
   "sha256": "6238bf4513e49f503cf050f2a820849edb2b923a66fd632c914a55cdbc510240"
  },
  {
   "name": "jevk5-9b-v0.3-Q8_0.gguf",
   "size": 9527501280,
   "sha256": "3815aedcf91d6721af6835f47f45ba83f82d105fd112e0a3142a9e5cf0ad06a0"
  },
  {
   "name": "jevk5-9b-v0.3.3-Q5_K_M.gguf",
   "size": 6467969504,
   "sha256": "da4a4becd04c3beabd4cefbd09b546ce2648740d923adc8d14ae1d0cb921486e"
  },
  {
   "name": "jevk5-9b-v0.3.3-Q8_0.gguf",
   "size": 9527501280,
   "sha256": "283de8fd216ad2200506d9236e574ddb5902b16e6a806a6fa38e9dd1b4286edf"
  }
 ]
}
```


## 4. mohnish/laya-onnx and convaiinnovations/laya-onnx
- **NOT FOUND / UNVERIFIED (INFERRED, not confirmed)**: hf-mirror API returns `{"error":"Invalid username or password."}` for both `mohnish/laya-onnx` and `convaiinnovations/laya-onnx`, and huggingface.co answers HTTP 401 for both on 2026-10-07 - but Hugging Face (and the mirror) return the same 401 for repos that do not exist AND for private/gated ones, so neither response proves absence. The claim "no laya ONNX sibling repo exists on the hub" is therefore an inference from that and from laya generating its ONNX client-side via `laya[onnx]`; it was not independently verified. hf-mirror has no full-text model search endpoint usable here, so a broader search was skipped.

## Non-LFS files note
Small files (tokenizer.json, config.json, tokenizer_config.json, README etc.) are non-LFS: the API exposes only a git blobId (oid), **no sha256** — marked `null` above.
