# T064 — option-order flip rate and accuracy vs option count, per profile

Generated 2026-10-09 from existing golden `results.json` files only (no new model runs). Machine-readable twin: `t064-option-count.json`. Method code: appendix (uses `wilson` from `scripts/golden/stats.py`).

## Method and honesty limits

- Source: `live-models/<run>/golden/results.json`, `type == choice` records. Runs chosen per `live-models/INDEX.md` validity: post-thinking-fix trees for letter-logit profiles (decide-2b, decide-pro, decide-max), valid runs for native (systemone-native) and onnx (decide-nli). Excluded: pre-fix runs, `decide-nli-main-79268f5-INVALID...`, `decide-nli` (0/132), `nezha-pinned-decide-2026-10-09` (base `decide`, 151 x 422 readout_failed), the pro default-8s control (13 of 41 choice items are 502 deadline, not a model answer), `anton-decide-pro-thinkingfix` (12 x 502), the incomplete `decide-kev-9b` anton dir. `decide-tiny` has no golden run; `decide` (base) has no usable run.
- Accuracy = original-order items only (same as `stats.py`); Wilson 95% CI. Permuted records feed only the flip rate (same rule as `stats.py flip_rate`: groups with >= 2 well-formed answers; flipped = answers disagree).
- Refused (limit): items with HTTP 422 whose `option_count` exceeds the catalog `max_options` are excluded from the option-count rows. These runs predate G-160, so the records carry no `refused` flag; I inferred it from status 422 AND option_count > max_options. That inference is exact for decide-2b / decide-max (4 items at 20 options, error text just `http 422`, so the cause is UNCONFIRMED beyond that match). No other non-200 choice items remain in the selected runs.
- Fixture: the golden choice set has only 41 original items spread over option counts 2(6) 3(7) 4(7) 5(6) 8(6) 12(5) 20(4). **Every cell has n <= 7, so every row is "insufficient (n<10)"**. No count is statistically established; the CI floors are mere directional signals. The fixture is labelled `agent-authored; human-review-pending`.
- "Highest count where lower CI > chance" uses chance = 1/n for that count. With n = 4..7 correct-of-n, a 4/4 already clears chance at 20 options (0.51 > 0.05); this says "better than guessing", NOT "reliable at 20".
- Only counts 2,3,4,5,8,12,20 exist in the data. Nothing was measured at 6, 7, 9-11, 13-19 or above 20. Native profiles' catalog value 255 therefore has zero evidence above 20.
- Letter mass per letter-logit profile: **not recorded**. Records carry `p_pred`/`confidence` (probability of the predicted answer) but no letter-mass field, and no file in the selected runs contains "mass". T062 data not present in these runs.
- The task's probe set (arithmetic, dates, double negatives, injection) was not analysed here; this covers the golden `--permute-groups` data only.

## Result table (correct/n [Wilson lo, hi])

| profile (run) | catalog max_options | flip rate (groups) | 2 | 3 | 4 | 5 | 8 | 12 | 20 | highest count lo > chance | highest measured |
|---|---|---|---|---|---|---|---|---|---|---|---|
| decide-2b (nezha-pinned) | 16 | 0.108 (4/37) | 6/6 [.61,1.0] | 5/7 [.36,.92] | 5/7 [.36,.92] | 4/6 [.30,.90] | 5/6 [.44,.97] | 5/5 [.57,1.0] | refused (4 items) | 12 | 12 |
| decide-pro (nezha-pinned, 300 s) | 20 | 0.024 (1/41) | 6/6 [.61,1.0] | 7/7 [.65,1.0] | 6/7 [.49,.97] | 5/6 [.44,.97] | 6/6 [.61,1.0] | 5/5 [.57,1.0] | 4/4 [.51,1.0] | 20 | 20 |
| decide-max (nezha-pinned) | 16 | 0.027 (1/37) | 6/6 [.61,1.0] | 7/7 [.65,1.0] | 7/7 [.65,1.0] | 5/6 [.44,.97] | 6/6 [.61,1.0] | 5/5 [.57,1.0] | refused (4 items) | 12 | 12 |
| decide-nli (wiredfix) | 20 | 0.000 (0/41) | 6/6 [.61,1.0] | 6/7 [.49,.97] | **2/7 [.08,.64]** | 6/6 [.61,1.0] | 6/6 [.61,1.0] | 4/5 [.38,.96] | 4/4 [.51,1.0] | 20 | 20 |
| decide-kev-08b | 255 | 0.024 (1/41) | 6/6 | 7/7 | 5/7 [.36,.92] | 5/6 | 4/6 [.30,.90] | 5/5 | 4/4 [.51,1.0] | 20 | 20 |
| decide-kev-4b (anton; nezha identical) | 255 | 0.000 (0/41) | 6/6 | 7/7 | 7/7 | 6/6 | 6/6 | 5/5 | 4/4 | 20 | 20 |
| decide-kev-9b (nezha) | 255 | 0.000 (0/41) | 6/6 | 7/7 | 7/7 | 6/6 | 6/6 | 5/5 | 4/4 | 20 | 20 |
| decide-lev (anton; nezha identical) | 255 | 0.000 (0/41) | 6/6 | 7/7 | 7/7 | 5/6 | 6/6 | 5/5 | 4/4 | 20 | 20 |
| decide-julia | 255 | **0.415 (17/41)** | 3/6 [.19,.81] | 3/7 [.16,.75] | 2/7 [.08,.64] | 2/6 [.10,.70] | **0/6 [.00,.39]** | 3/5 [.23,.88] | 1/4 [.05,.70] | 12 (chance-level elsewhere) | 20 |
| decide-laya | 255 | 0.195 (8/41) | 6/6 | 6/7 | 6/7 | 5/6 | 3/6 [.19,.81] | 5/5 | 2/4 [.15,.85] | 20 (2/4 lo .15 > .05) | 20 |

Unabbreviated CIs for every cell are in the JSON. Replicates: decide-nli, decide-kev-4b, decide-lev replicate runs reproduce the primary table exactly; decide-2b anton-run2 reproduces every accuracy cell but flips 3/37 vs 4/37 (different host; run-to-run difference of one group). Flips per option count are under `flip_by_count` in the JSON (2b: at 4, 5, 8 options; max: at 5; pro: at 2; julia: at every count).

Notes:
- decide-julia's 0.55/0.34/0.26 golden numbers (INDEX.md) say no model result beats baseline; its 41% flip rate agrees. Its "highest lo > chance" is not evidence of usable accuracy, it is noise on n <= 7.
- decide-nli 4-option accuracy 2/7 is far below its 3 and 5 option rows, but at 7 items it is not interpretable beyond "anomalous, UNCONFIRMED cause" (the profile is a binary-head NLI model; the pattern may be item/label-specific).

## Comparison with the catalog (`models/catalog.json`, all `max_options_status = evidence-pending`)

| profile | catalog | evidence | contradiction? |
|---|---|---|---|
| decide-2b | 16 | 12 options measured n=5 (5/5); 20 options refused at the gateway (consistent with the 16 limit); **nothing measured between 13 and 16** | Not contradicted, not supported: 16 rests on the JevK5 16-letter single-pass vendor limit (validator comment), not on accuracy data. Flip rate 0.11, the highest of the three letter-logit profiles. |
| decide-max | 16 | same as 2b: 12 -> 5/5, 20 -> refused, 13..16 unmeasured | same as above |
| decide-pro | 20 | 20 options measured 4/4 (lo .51), flip 0.02 | Consistent, but n=4 and run used the 300 s timeout; under the product default 8 s a different run (control) gave 502 deadline on 13/41 choice items, so latency, not accuracy, may bind at high option counts (UNCONFIRMED per option count). |
| decide-nli | 20 | 20 options 4/4, but 4-option 2/7 | Max not contradicted; accuracy at 4 options is a separate anomaly. |
| decide-kev-4b/-9b/-lev/-kev-08b | 255 | measured only up to 20 | **Unsupported above 20**: zero evidence for 21..255. Accuracy at 20 is 4/4 for 4b/9b/lev. |
| decide-julia | 255 | accuracy at chance-like levels for all counts, flip 0.41 | 255 is not supported by any evidence; the profile itself has no demonstrated skill. |
| decide-laya | 255 | accuracy drops at 8 (3/6) and 20 (2/4); flip 0.20 | 255 unsupported; 8+ options look weaker (n<=6, UNCONFIRMED). |
| decide-tiny, decide (base) | 20 | no valid golden run | no evidence either way |

No hard contradiction was found: no profile shows a measured accuracy collapse at or below its catalog cap with a sample large enough to claim it. The consistent finding is that all caps are unsupported by data beyond 12 (2b, max), 20 (pro, nli, native), and that the native 255 is a vendor/hosted limit, not a measured one.

## Proposal (NOT applied; models/catalog.json untouched)

Validator rules read from `tests/test_catalog_json.sh` (lines ~260-268): `max_options` must be an int in [2, 255], letter-logit profiles <= 26, `alibiserikbay/JevK5-GGUF` profiles <= 16; `max_options_status` must be one of `evidence-pending` | `measured`. There is no check that ties `measured` to an evidence file, so flipping to `measured` is only honest if done deliberately and cited.

1. Keep `max_options_status = evidence-pending` for every profile. The data is n <= 7 per cell on an agent-authored, human-review-pending fixture; it cannot back `measured`.
2. A value change to `measured` would be valid only together with a larger option-count probe (>= 10 items per tested count, incl. counts 13-16 for 2b/max and 21+ for native) and a pointer to the evidence file; the validator would still accept it syntactically, so the guard has to be procedural (suggest extending the validator to require an evidence reference when status is `measured`).
3. If the operator wants to reflect this analysis now without a status change: describe the measured ceiling in `decision.tier_note` (e.g. "option counts above 12 not measured") rather than changing `max_options`. Lowering decide-2b/decide-max from 16 to 12 would be valid for the validator but is not required by the data (12 is merely the last count measured, 13-16 unmeasured).
4. decide-julia: consider flagging as having no demonstrated skill (existing golden result), independent of max_options.
5. For native profiles, 255 could stay as the hosted limit, but `evidence-pending` is accurate: nothing above 20 was ever run.

## Appendix: method code (stdlib + `wilson` from scripts/golden/stats.py)

```python
import json,sys,collections
sys.path.insert(0,'scripts/golden')
from stats import wilson
L='specs/009-jev-decision-models/evidence/live-models/'
cat=json.load(open('models/catalog.json'))['profiles']
# profile -> (primary run, [replicate runs]) ; only VALID runs (INDEX.md)
RUNS={
 'decide-2b':('nezha-pinned-decide-2b-2026-10-09',['anton-decide-2b-thinkingfix-run2-2026-10-09']),
 'decide-pro':('nezha-pinned-decide-pro-2026-10-09',[]),
 'decide-max':('nezha-pinned-decide-max-2026-10-09',[]),
 'decide-nli':('decide-nli-main-wiredfix',['nezha-pinned-decide-nli-2026-10-09']),
 'decide-kev-08b':('decide-kev-08b',[]),
 'decide-kev-4b':('decide-kev-4b',['nezha-decide-kev-4b-2026-10-08']),
 'decide-kev-9b':('nezha-decide-kev-9b-2026-10-08',[]),
 'decide-lev':('decide-lev',['nezha-decide-lev-2026-10-08']),
 'decide-julia':('decide-julia',[]),
 'decide-laya':('decide-laya',[]),
}
BUCKETS=[2,3,4,5,8,12,20]
def analyse(run,prof):
    recs=json.load(open(L+run+'/golden/results.json'))['records']
    mo=cat[prof]['decision']['max_options']
    ch=[r for r in recs if r['type']=='choice']
    def cls(r):
        if r.get('refused') or (r['status']==422 and r['option_count']>mo): return 'refused'
        if r['status']!=200: return 'infra'   # 502/503: no model answer, not an accuracy datum
        return 'ok'
    orig=[r for r in ch if r['variant']=='orig']
    out={'run':run,'catalog_max_options':mo,'orig_choice_items':len(orig)}
    out['refused_limit_items']=sum(1 for r in orig if cls(r)=='refused')
    out['infra_excluded_items']=sum(1 for r in orig if cls(r)=='infra')
    by={}
    for n in BUCKETS:
        rows=[r for r in orig if r['option_count']==n and cls(r)=='ok']
        k=sum(1 for r in rows if r['well_formed'] and r['predicted']==r['expected'])
        lo,hi=wilson(k,len(rows)) if rows else (None,None)
        tot=sum(1 for r in orig if r['option_count']==n)
        by[str(n)]={'items_in_set':tot,'n':len(rows),'correct':k,'acc':(k/len(rows)) if rows else None,
                    'wilson_low':lo,'wilson_high':hi,'chance':1.0/n,
                    'low_gt_chance':(lo>1.0/n) if rows else None,
                    'sufficiency':('insufficient (n<10)' if len(rows)<10 else 'ok')}
    out['by_count']=by
    groups=collections.defaultdict(list); gn={}
    for r in ch:
        if cls(r)=='ok' and r['well_formed'] and r['predicted'] is not None and r.get('perm_group'):
            groups[r['perm_group']].append(r['predicted']); gn[r['perm_group']]=r['option_count']
    cons={g:v for g,v in groups.items() if len(v)>=2}
    fl=sum(1 for v in cons.values() if len(set(v))>1)
    out['flip']={'groups':len(cons),'flipped':fl,'rate':(fl/len(cons)) if cons else None}
    fbc={}
    for n in BUCKETS:
        gs=[v for g,v in cons.items() if gn[g]==n]
        fbc[str(n)]={'groups':len(gs),'flipped':sum(1 for v in gs if len(set(v))>1)}
    out['flip_by_count']=fbc
    # highest count with lower CI bound > chance, among buckets with data
    ok=[n for n in BUCKETS if by[str(n)]['low_gt_chance']]
    out['highest_count_low_gt_chance']=max(ok) if ok else None
    meas=[n for n in BUCKETS if by[str(n)]['n']>0]
    out['highest_count_measured']=max(meas) if meas else None
    out['all_buckets_insufficient']=all(by[str(n)]['sufficiency']!='ok' for n in meas)
    return out
res={}
for p,(prim,reps) in RUNS.items():
    r=analyse(prim,p); r['replicates']=[analyse(x,p) for x in reps]
    for x in r['replicates']:
        x['matches_primary']=(x['by_count']==r['by_count'] and x['flip']==r['flip'])
    res[p]=r
json.dump(res,open('specs/009-jev-decision-models/evidence/t064-option-count.json','w'),indent=1,sort_keys=True)
def f(x): return '-' if x is None else '%.2f'%x
print('| profile | cat max | flip (groups) | '+' | '.join(str(n) for n in BUCKETS)+' | hi lowCI>chance | hi measured |')
for p,r in res.items():
    cells=[]
    for n in BUCKETS:
        b=r['by_count'][str(n)]
        cells.append('%d/%d [%s,%s]'%(b['correct'],b['n'],f(b['wilson_low']),f(b['wilson_high'])) if b['n'] else ('refused' if b['items_in_set'] else '-'))
    fl=r['flip']
    print('| %s | %s | %s (%d) | %s | %s | %s |'%(p,r['catalog_max_options'],f(fl['rate']),fl['groups'],' | '.join(cells),r['highest_count_low_gt_chance'],r['highest_count_measured']))
for p,r in res.items():
    print(p,'refused',r['refused_limit_items'],'infra',r['infra_excluded_items'],'reps',[(x['run'],x['matches_primary']) for x in r['replicates']], 'flipbycount',{k:v for k,v in r['flip_by_count'].items() if v['groups']})
```
