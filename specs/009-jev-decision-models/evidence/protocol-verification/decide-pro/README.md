---
license: apache-2.0
base_model:
  - XHToken/Spark-X2.5-4B
  - XHToken/Spark-X2.5-1.7B
library_name: peft
tags:
  - gguf
  - lora
  - classification
  - typed-decisions
  - rizzo-flow
language:
  - en
---

# Rizzo Flow: Spark-X2.5 (4B and 1.7B) + typed-decisions LoRA

These are LoRA fine-tunes of [XHToken/Spark-X2.5-4B](https://huggingface.co/XHToken/Spark-X2.5-4B)
(recommended) and [XHToken/Spark-X2.5-1.7B](https://huggingface.co/XHToken/Spark-X2.5-1.7B), for [Rizzo Flow](https://github.com/Rizzo-AI-Academy/rizzo-flow). Rizzo Flow turns an unstructured
state into typed decisions (`boolean`, `choice`, `score`) with probabilities, and it **generates no
text**. The model runs one forward pass per question. The answer is the softmax over the logits of
the answer letters (`A`, `B`, …) at the last prompt position.

Training works the same way. There is no text target: the loss is a soft cross-entropy between the
target distribution and the softmax over the answer letters. Only the LoRA adapters are trained.

This model is not affiliated with TypeSafe, and it is not Jev.

## Files

| File | What it is |
| --- | --- |
| `model-0000*-of-00005.safetensors`, `config.json`, tokenizer files | Merged model, BF16 safetensors (8.2 GB): for the MLX backend and transformers. Same weights as the BF16 GGUF, bit for bit |
| `spark-x2.5-4b-rizzo-flow-lora-q8_0.gguf` | Merged model, Q8_0 (4.4 GB): the default for `rizzo serve` |
| `spark-x2.5-4b-rizzo-flow-lora-bf16.gguf` | Merged model, BF16 (8.2 GB) |
| `spark-x2.5-4b-rizzo-flow-lora-q4_k_m.gguf` | Merged model, Q4_K_M (2.6 GB), for GPUs with little memory |
| `lora/` | The PEFT adapter alone (r 16, alpha 32), to apply to the BF16 HF checkpoint |
| `training/history.json` | Arguments, training loss and dev evaluations of the 4B run |
| `spark-x2.5-1.7b-rizzo-flow-lora-q8_0.gguf` | 1.7B merged model, Q8_0 (1.8 GB) |
| `spark-x2.5-1.7b-rizzo-flow-lora-bf16.gguf` | 1.7B merged model, BF16 (3.4 GB) |
| `lora-1.7b/` | The 1.7B PEFT adapter alone (r 16, alpha 32) |
| `training/history-1.7b.json` | The same for the 1.7B run |

## Use

These GGUF files are what [Rizzo Flow](https://github.com/Rizzo-AI-Academy/rizzo-flow) downloads
by default. It pins this repository by commit and checks the sha256 of every file:

```bash
git clone https://github.com/Rizzo-AI-Academy/rizzo-flow && cd rizzo-flow
uv sync --locked
uv run rizzo download          # llama.cpp for this machine + this model, Q8_0 (4.4 GB)
uv run rizzo serve             # → http://127.0.0.1:8017/playground
```

`--quant bf16` or `--quant q4_k_m` picks another file, `--size 1.7b` the small model (also in its own repository,
[`rizzoaiacademy/rizzo-flow-1.7b`](https://huggingface.co/rizzoaiacademy/rizzo-flow-1.7b)), and
`--weights base` the original Spark-X2.5 GGUF files. The server answers as `rizzo-flow-4b-q8_0`.

**MLX** (Apple Silicon, or MLX-CUDA) uses the safetensors checkpoint at the root of this
repository instead of the GGUF files:

```bash
uv sync --locked --extra mlx
uv run --no-sync rizzo download --backend mlx      # the safetensors only, 8.2 GB
uv run --no-sync rizzo serve --backend mlx --bits 8
```

It answers as `rizzo-flow-4b-bf16` (or `…-q8`/`…-q4` with `--bits`). On an RTX 5060 Ti with MLX-CUDA, BF16, the
4B gives the same prompts (same hashes) and the same probabilities as llama.cpp BF16 within 0.001.

**transformers** loads the checkpoint with the original Spark code (`trust_remote_code=True`,
`modeling_spark.py` is XHToken's file, unchanged): `AutoModelForCausalLM.from_pretrained(
"rizzoaiacademy/rizzo-flow", trust_remote_code=True, dtype="bfloat16")`. Use the prompts of
Rizzo Flow and read the answer-letter logits at the last position; generating text is not what
it was trained for.

The GGUF files are plain GGUF (architecture `spark2_5`; Rizzo Flow runs them on llama.cpp release b11081), but the model is
meant to be **read, not chatted with**: Rizzo Flow builds the prompt, then reads the logits of the
answer letters. In a chat app it behaves like a lightly changed Spark-X2.5, and the fine-tune
brings nothing there.

The adapter was trained on the exact prompts of `PROMPT_VERSION = "spark-decisions-v3"`, commit
`c30cc63` of rizzo-flow. Any other prompt format can make the adapter useless.

## Results

We ran the test split of the
[`LocalLLaMA/typed-decisions`](https://huggingface.co/datasets/LocalLLaMA/typed-decisions) benchmark
(config `all`, 400 cases, 2,000 decisions). The model is fine-tuned for typed decisions, so this
is not a zero-shot result, but training used no data from these four workflows: the Open-Jev config
that shares them (`workflow-controls-v1`) was excluded, and so was every training state containing
text from the test set. Base and fine-tune were measured on the same machine: llama.cpp b11081,
CUDA, RTX 5060 Ti.

| | Accuracy ↑ | KL from gold ↓ | Brier ↓ | ECE ↓ | p50 per case |
| --- | ---: | ---: | ---: | ---: | ---: |
| Spark-X2.5-4B Q8_0, base | 0.574 | 2.899 | 0.480 | 0.349 | 201 ms |
| **This model, Q8_0** | **0.648** | **0.452** | **0.205** | **0.112** | 195 ms |
| TypeSafe Jev 1.13.0 (from its dataset card, not re-measured) | 0.727 | 1.442 | 0.148 | – | – |

Accuracy +0.074, 95% interval [+0.050, +0.101] (paired bootstrap over cases). On an RTX PRO 6000
the same file scores 0.650 / 0.454 / 0.205 / 0.111: the difference between GPUs is below 0.002.

**Q4_K_M** (made with `llama-quantize` b11081 from the BF16 GGUF, no importance matrix) scores
0.650 / 0.436 / 0.201 / 0.093 on the RTX 5060 Ti, p50 198 ms: tied with Q8_0 on this benchmark
(+0.002 [−0.011, +0.015]). On the original weights Q4_K_M cost 4 points on SemIf's fixtures, which
we have not re-run here, so check it on your own data before relying on it.

Per workflow (accuracy / KL): customer_service 0.710 / 0.350, invoice_processing 0.714 / 0.506,
security_incidents 0.674 / 0.434, agent_trace_observability 0.500 / 0.526 (base: 0.366).
By type: noul 0.738, choice 0.637, score 0.593.

Dev split of the training mixture (600 questions): loss 1.928 → 0.393, accuracy 0.547 → 0.857.

### 1.7B

We measured the base model and the fine-tuned one on the same machine, with the same runtime
(RTX PRO 6000; on the RTX 5060 Ti: 0.530 → 0.544, KL 3.031 → 0.694):

| | Accuracy ↑ | KL from gold ↓ | Brier ↓ | ECE ↓ | p50 per case |
| --- | ---: | ---: | ---: | ---: | ---: |
| Spark-X2.5-1.7B Q8_0, base | 0.531 | 3.032 | 0.494 | 0.348 | 50 ms |
| **This model, 1.7B Q8_0** | **0.546** | **0.692** | **0.274** | **0.167** | 52 ms |

On the 1.7B, fine-tuning mostly improves the probabilities (KL, Brier, ECE). Accuracy barely
moves: +0.015 is within noise. The change is not uniform across workflows:
agent_trace_observability goes 0.372 → 0.490 and customer_service 0.644 → 0.674, but
security_incidents drops 0.608 → 0.520. By type, noul goes 0.603 → 0.675 and score 0.441 → 0.461,
but choice drops 0.578 → 0.532. On the dev split, loss goes 3.117 → 0.460 and accuracy
0.408 → 0.820. Use the 4B when accuracy matters.

The probabilities are **not calibrated**. Fit temperature scaling on data from your own domain
(`rizzo calibrate`) before you use thresholds. The accuracy is still below Jev's published
number, and the gold labels of the benchmark come from a ~4B teacher model, not from humans. We
have not yet re-run the smoke and SemIf fixtures on this model.

## Training

- Base: Spark-X2.5-4B BF16, rev. `0bcb356`. LoRA r 16, alpha 32, dropout 0.05, on all linear
  layers of attention and MLP. Embedding and `lm_head` are not trained because they are tied.
  32.4M trainable parameters.
- AdamW, lr 5e-5, 3% warmup then cosine decay, no weight decay, clip 1.0. 16 questions per step.
  1 epoch = 1,770 steps. Seed 0.
- 28,321 training questions (14.7M prompt tokens, max 2,048 tokens per prompt), from
  [`tasksource/procedural-typed-decisions`](https://huggingface.co/datasets/tasksource/procedural-typed-decisions)
  (Apache-2.0), [`ZefanCai/Open-Jev`](https://huggingface.co/datasets/ZefanCai/Open-Jev)
  `release-v2-redistributable` (CC0) and 12 configs of
  [`Praveenrajus/jev-bench`](https://huggingface.co/datasets/Praveenrajus/jev-bench). None of the
  labels come from Jev or TypeSafe. We removed every training state that contains text from the
  evaluation sets.
- Hardware: 1× RTX PRO 6000 Blackwell 96 GB, no gradient checkpointing. 4B: batch 4 / 2,048
  tokens per forward, ~6,700 prompt tokens/s, 41 minutes, 38 GiB peak. 1.7B (rev. `14d6e83`,
  16.7M trainable parameters, same data and hyperparameters): batch 8 / 3,072 tokens,
  ~15,500 tokens/s, 19 minutes, 22 GiB peak.

Full pipeline and reasoning:
[`docs/training.md`](https://github.com/Rizzo-AI-Academy/rizzo-flow/blob/main/docs/training.md).

## Licenses of the training data

The base model is Apache-2.0. Among the jev-bench configs, `stsb` is **CC-BY-SA**.
`measuring_hate_speech` and the HelpSteer2 configs are CC-BY-4.0: *Measuring Hate Speech*
(Kennedy et al., 2020; Sachdeva et al., 2022) and *HelpSteer2* (Wang et al., 2024, NVIDIA).
Check whether these terms matter for your use before you redistribute derivatives.
