# decide-tiny "no usable answer" (T044) - root cause, 2026-10-08

## Finding

decide-tiny (`chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF`, pin `edf37c26`) was catalogued with
`decision.protocol: letter-logit`. The vendor does not define that protocol for this model:

- `readout_config.json` at the pinned revision says `"readout": "verdict"` and `"template": "macjev-render-v1"`.
  The score of option k is `logit(" yes") - logit(" no")` at the k-th `" ->"` token, read from one
  rendered input (state, question, option list, then `<option> ->` once per option).
- The README says: "Chat or text generation does **not** give you the model's decisions."

So the first token " no"/" yes" in the live run is the model's verdict token, not a broken template.

## Evidence (CPU only, `-ngl 0`, port 8092, this host, 2026-10-08)

`letter_probe.py` / `letter_probe.out`: the gateway's exact letter prompt, total A/B letter mass:
- chat template, default (what the gateway sends): 0.0001 (`reasoning_content` = "no")
- chat template, `enable_thinking=false`: 0.0000 (content = "no")
- raw `/completion`, no template: 0.0000

None of the three moves the letter mass, so this is not a `reasoning_content` stripping problem and not a
leading-space spelling problem (" A" and "A" are both already in the readout).

`verdict_probe.py` / `verdict_probe.out`: the vendor's verdict layout on the same server (segments
tokenised separately, special tokens not parsed, one `/completion` per `" ->"` slot):
- invoice routing, 2 options: billing 0.788 / legal 0.212 (global T 0.88)
- 4 options: billing 0.741
- noul "disk 12% and stable": false 0.932; "disk 97% and rising": true 0.518

The model answers correctly in its own format. These numbers are not a parity claim against the vendor's
`jev-score` (no parity run was made).

## Fix

Catalog: decide-tiny is `jev-verdict`, with a `tier_note` saying it is not servable yet. Gateway: the
protocol is known but unimplemented; the profile is never listed or routed, and a request for it gets a
non-retryable 500 that names the profile, the protocol and the reason, with no engine call.
Download smoke: "NOT EXERCISED" (warning), never a letter probe and never a PASS.

Not done here: a `jev-verdict` driver (a separate feature with its own parity test against `jev-score`).
