import json,sys,collections,os,re,statistics
d=sys.argv[1]
print("==",d)
for s in ("golden","probes"):
    p=os.path.join(d,s,"results.json")
    if not os.path.exists(p): print(s,"MISSING"); continue
    R=json.load(open(p)); recs=R["records"]
    st=collections.Counter(r["status"] for r in recs)
    print(s,"records",len(recs),"status",dict(st))
    fails=[r for r in recs if r["status"]!=200]
    byopt=collections.Counter((r["status"],r.get("option_count")) for r in fails)
    print("  non200 by (status,option_count):",dict(byopt))
    lat=sorted(r["latency_ms"] for r in recs if r["status"]==200)
    if lat: print("  200 latency ms: n=%d median=%d p95=%d max=%d"%(len(lat),statistics.median(lat),lat[int(.95*(len(lat)-1))],lat[-1]))
    fl=sorted(r["latency_ms"] for r in fails)
    if fl: print("  non200 latency ms: min=%d median=%d max=%d"%(fl[0],statistics.median(fl),fl[-1]))
    h=os.path.join(d,"hdr-%s.jsonl"%s)
    if os.path.exists(h):
        c=collections.Counter(); first=[]
        for l in open(h):
            r=json.loads(l); k=(r.get("status",r.get("exc")),r.get("headers",{}).get("x-llmctl-decide-reason"),(re.search(r'error_type":"(\w+)',r.get("body","")) or [None,None])[1]); c[k]+=1
            if r.get("status")!=200 and len(first)<3: first.append(r)
        print("  http attempts (status,reason-header,error_type):",{str(k):v for k,v in c.items()})
        json.dump(first,open(os.path.join(d,"%s-first3-failure-attempts.json"%s),"w"),indent=1)
    out=[{"id":r["id"],"status":r["status"],"request_id":r["request_id"],"attempts":r["attempts"],"latency_ms":r["latency_ms"],"error":r["error"]} for r in fails[:3]]
    json.dump(out,open(os.path.join(d,"%s-first3-failure-records.json"%s),"w"),indent=1)
ctx=open(os.path.join(d,"context.txt")).read()
print("  mem:",re.findall(r"(VmHWM:\s+\d+ kB)",ctx))
ps=[l for l in open(os.path.join(d,"psi-samples.txt")) if "psi_full10" in l]
if ps:
    f=max(float(re.search(r"psi_full10=([\d.]+)",l)[1]) for l in ps); s=max(float(re.search(r"psi_some10=([\d.]+)",l)[1]) for l in ps); sw=min(float(re.search(r"swap_free_pct=([\d.]+)",l)[1]) for l in ps); av=min(int(re.search(r"mem_avail_mib=(\d+)",l)[1]) for l in ps)
    print("  PSI max full10=%s some10=%s min swap_free%%=%s min MemAvailable MiB=%s samples=%d abort=%s"%(f,s,sw,av,len(ps),any("ABORT" in l for l in open(os.path.join(d,"psi-samples.txt")))))
