# Decision Model Candidates — Verified HF Metadata

Source: `https://hf-mirror.com/api/models/<repo>?blobs=true` (huggingface.co was unreachable from this environment; hf-mirror mirrors the HF API). All values below come from `siblings[].lfs.size` / `siblings[].lfs.sha256` and `cardData.license` / repo tags. Verified 2025 — all six repos fetched successfully.

## JSON

```json
{
  "verified_via": "hf-mirror.com HF API (huggingface.co blocked)",
  "models": [
    {
      "repo": "chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF",
      "revision": "main",
      "commit": "edf37c26a1098f83cf4264b8adbe0dca2d2ebb0c",
      "license": "apache-2.0",
      "files": [
        {
          "filename": "Jev-Style-0.8B-Decision-v3-Q4_K_M.gguf",
          "size_bytes": 529296864,
          "sha256": "0a19bc29bacc33e0d871146c8612b24dd14c2ed2e61cedeb7a928b0852628bac"
        }
      ],
      "all_gguf_siblings": [
        {"name": "Jev-Style-0.8B-Decision-v3-F16.gguf", "size_bytes": 1516744160},
        {"name": "Jev-Style-0.8B-Decision-v3-Q4_K_M.gguf", "size_bytes": 529296864},
        {"name": "Jev-Style-0.8B-Decision-v3-Q8_0.gguf", "size_bytes": 811843040}
      ]
    },
    {
      "repo": "Mapika/decider-4b-GGUF",
      "revision": "main",
      "commit": "b79f09d9ba7837f1b744295ea267b55d08e958ec",
      "license": "apache-2.0",
      "refs": {"tags": [], "branches": ["main"]},
      "note": "No 'v2' tag exists; repo has only the 'main' branch. Current files on main are the v2.1 quantization set (decider-4b-v2.1-*).",
      "files": [
        {
          "filename": "decider-4b-v2.1-Q4_K_M.gguf",
          "size_bytes": 2708804640,
          "sha256": "c7083fcfc93f650cd66caeade4a3840ef9eeeeb1e80920907c554f70619d7c56"
        }
      ],
      "all_gguf_siblings": [
        {"name": "decider-4b-v2.1-BF16.gguf", "size_bytes": 8424393760},
        {"name": "decider-4b-v2.1-Q4_K_M.gguf", "size_bytes": 2708804640},
        {"name": "decider-4b-v2.1-Q8_0.gguf", "size_bytes": 4482403360}
      ]
    },
    {
      "repo": "rizzoaiacademy/rizzo-flow",
      "revision": "main",
      "commit": "55633c8cbd2b826bd3eefdeb05310450996649df",
      "license": "apache-2.0",
      "note": "Two sizes exist (1.7B and 4B LoRA-merged). Q4_K_M exists ONLY for the 4B variant; Q8_0 exists for both.",
      "files": [
        {
          "filename": "spark-x2.5-4b-rizzo-flow-lora-q4_k_m.gguf",
          "size_bytes": 2600224416,
          "sha256": "79de5cb8dbfd1a1f5cb3037252251594352841fe5e3dc1ae8cead053010fcd54"
        },
        {
          "filename": "spark-x2.5-4b-rizzo-flow-lora-q8_0.gguf",
          "size_bytes": 4375021216,
          "sha256": "dbec3c89d33984772324e65a8ed56b48e958e301b856cb870a7c1b385d01691a"
        },
        {
          "filename": "spark-x2.5-1.7b-rizzo-flow-lora-q8_0.gguf",
          "size_bytes": 1820112768,
          "sha256": "685403da9c62e0745cb77817ee2d66418e3ce85002ef403cf2680481e22bf16d"
        }
      ],
      "all_gguf_siblings": [
        {"name": "spark-x2.5-1.7b-rizzo-flow-lora-bf16.gguf", "size_bytes": 3420931968},
        {"name": "spark-x2.5-1.7b-rizzo-flow-lora-q8_0.gguf", "size_bytes": 1820112768},
        {"name": "spark-x2.5-4b-rizzo-flow-lora-bf16.gguf", "size_bytes": 8229920416},
        {"name": "spark-x2.5-4b-rizzo-flow-lora-q4_k_m.gguf", "size_bytes": 2600224416},
        {"name": "spark-x2.5-4b-rizzo-flow-lora-q8_0.gguf", "size_bytes": 4375021216}
      ]
    },
    {
      "repo": "alibiserikbay/JevK5-GGUF",
      "revision": "main",
      "commit": "ec67b0bfce5119a8b11a2cdb430bb43e3fa3e82a",
      "license": "apache-2.0",
      "note": "Multiple model sizes/versions have Q8_0; 2B (v0.2), 4B (v0.2/v0.3), 9B (v0.3/v0.3.3). Choose by intended size.",
      "files": [
        {
          "filename": "jevk5-2b-v0.2-Q8_0.gguf",
          "size_bytes": 2012012000,
          "sha256": "17222f27a89273aca7614e34083a530b0d90cd51cffeb225c7acc8e79a7e0eba"
        },
        {
          "filename": "jevk5-4b-v0.3-Q8_0.gguf",
          "size_bytes": 4482402720,
          "sha256": "aea433883bc7ed399f2fbd539e53d2eac7caf71a946fe6650995a413979d4a30"
        },
        {
          "filename": "jevk5-9b-v0.3.3-Q8_0.gguf",
          "size_bytes": 9527501280,
          "sha256": "283de8fd216ad2200506d9236e574ddb5902b16e6a806a6fa38e9dd1b4286edf"
        }
      ],
      "all_gguf_siblings": [
        {"name": "jevk5-2b-v0.2-Q8_0.gguf", "size_bytes": 2012012000},
        {"name": "jevk5-4b-v0.2-Q4_K_M.gguf", "size_bytes": 2708803936},
        {"name": "jevk5-4b-v0.2-Q8_0.gguf", "size_bytes": 4482402656},
        {"name": "jevk5-4b-v0.3-Q4_K_M.gguf", "size_bytes": 2708804000},
        {"name": "jevk5-4b-v0.3-Q5_K_M.gguf", "size_bytes": 3074986400},
        {"name": "jevk5-4b-v0.3-Q8_0.gguf", "size_bytes": 4482402720},
        {"name": "jevk5-9b-v0.3-Q5_K_M.gguf", "size_bytes": 6467969504},
        {"name": "jevk5-9b-v0.3-Q8_0.gguf", "size_bytes": 9527501280},
        {"name": "jevk5-9b-v0.3.3-Q5_K_M.gguf", "size_bytes": 6467969504},
        {"name": "jevk5-9b-v0.3.3-Q8_0.gguf", "size_bytes": 9527501280}
      ]
    },
    {
      "repo": "Mapika/decider-2b-GGUF",
      "revision": "main",
      "commit": "ff2e5e687327eda9ac34e9a3ca84d3f400672c87",
      "license": "apache-2.0",
      "files": [
        {
          "filename": "decider-2b-v11-Q4_K_M.gguf",
          "size_bytes": 1274396800,
          "sha256": "b7c132a67934d51c81abc96bb7724800f965ff5a288aed3e1ca7d8bc349c1386"
        }
      ],
      "all_gguf_siblings": [
        {"name": "decider-2b-v11-BF16.gguf", "size_bytes": 3775709312},
        {"name": "decider-2b-v11-Q4_K_M.gguf", "size_bytes": 1274396800},
        {"name": "decider-2b-v11-Q8_0.gguf", "size_bytes": 2012012672}
      ]
    },
    {
      "repo": "chaoliangUNSW/Jev-Style-Qwen3.5-2B-Decision-GGUF",
      "revision": "main",
      "commit": "adc5656741715ddd3e40dac44c6294cb888bc655",
      "license": "apache-2.0",
      "files": [
        {
          "filename": "Jev-Style-Qwen3.5-2B-Decision-Q4_K_M.gguf",
          "size_bytes": 1312156768,
          "sha256": "f3c14cd9d6d314d22f22ec527914e1cb7b5a9043823d4e815c0d232a9cd16cf6"
        },
        {
          "filename": "Jev-Style-Qwen3.5-2B-Decision-Q8_0.gguf",
          "size_bytes": 2076666976,
          "sha256": "470aa63b87fedf852e292580424fc4511778dffdbd459858f68abf4892dba040"
        }
      ],
      "all_gguf_siblings": [
        {"name": "Jev-Style-Qwen3.5-2B-Decision-BF16.gguf", "size_bytes": 3897379936},
        {"name": "Jev-Style-Qwen3.5-2B-Decision-Q4_K_M.gguf", "size_bytes": 1312156768},
        {"name": "Jev-Style-Qwen3.5-2B-Decision-Q8_0.gguf", "size_bytes": 2076666976}
      ]
    }
  ]
}
```

## Human table

| Repo | Rev (commit) | Filename | Size (bytes) | SHA256 | License |
|---|---|---|---|---|---|
| chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF | main (edf37c26) | Jev-Style-0.8B-Decision-v3-Q4_K_M.gguf | 529296864 | 0a19bc29bacc33e0d871146c8612b24dd14c2ed2e61cedeb7a928b0852628bac | apache-2.0 |
| Mapika/decider-4b-GGUF | main (b79f09d9) — NO v2 tag, only main | decider-4b-v2.1-Q4_K_M.gguf | 2708804640 | c7083fcfc93f650cd66caeade4a3840ef9eeeeb1e80920907c554f70619d7c56 | apache-2.0 |
| rizzoaiacademy/rizzo-flow | main (55633c8c) | spark-x2.5-4b-rizzo-flow-lora-q4_k_m.gguf | 2600224416 | 79de5cb8dbfd1a1f5cb3037252251594352841fe5e3dc1ae8cead053010fcd54 | apache-2.0 |
| rizzoaiacademy/rizzo-flow | main (55633c8c) | spark-x2.5-4b-rizzo-flow-lora-q8_0.gguf | 4375021216 | dbec3c89d33984772324e65a8ed56b48e958e301b856cb870a7c1b385d01691a | apache-2.0 |
| rizzoaiacademy/rizzo-flow | main (55633c8c) | spark-x2.5-1.7b-rizzo-flow-lora-q8_0.gguf | 1820112768 | 685403da9c62e0745cb77817ee2d66418e3ce85002ef403cf2680481e22bf16d | apache-2.0 |
| alibiserikbay/JevK5-GGUF | main (ec67b0bf) | jevk5-2b-v0.2-Q8_0.gguf | 2012012000 | 17222f27a89273aca7614e34083a530b0d90cd51cffeb225c7acc8e79a7e0eba | apache-2.0 |
| alibiserikbay/JevK5-GGUF | main (ec67b0bf) | jevk5-4b-v0.3-Q8_0.gguf | 4482402720 | aea433883bc7ed399f2fbd539e53d2eac7caf71a946fe6650995a413979d4a30 | apache-2.0 |
| alibiserikbay/JevK5-GGUF | main (ec67b0bf) | jevk5-9b-v0.3.3-Q8_0.gguf | 9527501280 | 283de8fd216ad2200506d9236e574ddb5902b16e6a806a6fa38e9dd1b4286edf | apache-2.0 |
| Mapika/decider-2b-GGUF | main (ff2e5e68) | decider-2b-v11-Q4_K_M.gguf | 1274396800 | b7c132a67934d51c81abc96bb7724800f965ff5a288aed3e1ca7d8bc349c1386 | apache-2.0 |
| chaoliangUNSW/Jev-Style-Qwen3.5-2B-Decision-GGUF | main (adc56567) | Jev-Style-Qwen3.5-2B-Decision-Q4_K_M.gguf | 1312156768 | f3c14cd9d6d314d22f22ec527914e1cb7b5a9043823d4e815c0d232a9cd16cf6 | apache-2.0 |
| chaoliangUNSW/Jev-Style-Qwen3.5-2B-Decision-GGUF | main (adc56567) | Jev-Style-Qwen3.5-2B-Decision-Q8_0.gguf | 2076666976 | 470aa63b87fedf852e292580424fc4511778dffdbd459858f68abf4892dba040 | apache-2.0 |

## Caveats

- **Mapika/decider-4b-GGUF**: `/refs` shows `tags: []` and a single `main` branch — there is **no "v2" tag**. The files on main are named `decider-4b-v2.1-*`; if a historical v2 file is needed it would have to come from an earlier commit, not a tag.
- **rizzoaiacademy/rizzo-flow**: Q4_K_M exists only for the 4B variant; the 1.7B variant has only bf16 and q8_0.
- **alibiserikbay/JevK5-GGUF**: multiple Q8_0 files exist (2B/4B/9B, several versions); all are listed above for selection.
- Everything else verified; nothing marked UNVERIFIED. Values were fetched from hf-mirror.com (HF API mirror) because huggingface.co was blocked in this environment; mirror responses are the canonical HF API payloads, but hashes were not re-checked by download.
