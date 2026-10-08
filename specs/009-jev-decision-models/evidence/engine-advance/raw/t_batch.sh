#!/bin/bash
tag=b11379; cd ~/llmctl-work; export LD_LIBRARY_PATH=llama.cpp-$tag/build/bin; K=$(cat keyfile)
port=$(python3 -c "import socket;s=socket.socket();s.bind((\"127.0.0.1\",0));print(s.getsockname()[1]);s.close()")
llama.cpp-$tag/build/bin/llama-server -m models/Julia-1-Q8_0.gguf --host 127.0.0.1 --port $port --api-key-file keyfile -c 8192 -b 4096 -ub 4096 -t 4 -np 1 > out/server-julia-$tag-b4096.log 2>&1 &
spid=$!
for i in $(seq 1 60); do c=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$port/health); [ "$c" = 200 ] && break; sleep 1; done
python3 - $port <<"P"
import json,sys,urllib.request
K=open("keyfile").read().strip()
st=("The invoice was sent to accounting. "*300)
b=json.dumps({"state":st,"questions":{"angry":{"type":"noul","instructions":"Is the sender angry?"}}}).encode()
r=urllib.request.Request(f"http://127.0.0.1:{sys.argv[1]}/v1/systemone",data=b,headers={"Authorization":"Bearer "+K,"Content-Type":"application/json"})
try:
    f=urllib.request.urlopen(r,timeout=60); print("with -b/-ub 4096:",f.status,f.read().decode()[:260])
except Exception as e: print("ERR",getattr(e,"code",None),getattr(e,"read",lambda:b"")()[:300])
P
kill $spid; wait $spid 2>/dev/null
