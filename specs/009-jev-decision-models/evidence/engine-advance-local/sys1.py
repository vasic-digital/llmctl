import sys,json,urllib.request,urllib.error
port,key,outdir,tag=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
req={"state":"Customer message: I was charged twice for my order last week and nobody has replied.",
"questions":{
 "route":{"type":"choice","instructions":"Which team should handle this?","criteria":{"billing":None,"shipping":None,"technical":None}},
 "angry":{"type":"noul","instructions":"Is the customer angry?"},
 "urgency":{"type":"score","instructions":"How urgent is this?","criteria":["can wait","this week","today","right now"]}}}
body=json.dumps(req).encode()
def call(auth=True,path="/v1/systemone"):
    h={"Content-Type":"application/json"}
    if auth: h["Authorization"]="Bearer "+key
    r=urllib.request.Request(f"http://127.0.0.1:{port}{path}",data=body,headers=h,method="POST")
    try:
        with urllib.request.urlopen(r,timeout=120) as f: return f.status,f.read()
    except urllib.error.HTTPError as e: return e.code,e.read()
results=[]
for i in range(8):
    results.append(call())
for i,(c,b) in enumerate(results): open(f"{outdir}/{tag}-systemone-{i}.json","wb").write(b)
print("status codes",[c for c,_ in results])
print("byte-identical 8/8:",len({b for _,b in results})==1)
print(results[0][1].decode()[:1500])
c,b=call(auth=False); print("noauth ->",c,b[:200])
