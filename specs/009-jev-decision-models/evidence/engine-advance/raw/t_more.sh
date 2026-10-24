#!/bin/bash
tag=b11379; cd ~/llmctl-work; export LD_LIBRARY_PATH=llama.cpp-$tag/build/bin; K=$(cat keyfile)
(umask 077; printf 'Authorization: Bearer %s\n' "$K" > hdrfile)   # header file: key never on a command line (class sweep C2)
mkdir -p certs; [ -f certs/key.pem ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout certs/key.pem -out certs/cert.pem -days 1 -subj /CN=localhost 2>/dev/null; chmod 600 certs/key.pem
pp() { python3 -c "import socket;s=socket.socket();s.bind((\"127.0.0.1\",0));print(s.getsockname()[1]);s.close()"; }
port=$(pp)
llama.cpp-$tag/build/bin/llama-server -m models/Julia-1-Q8_0.gguf --host 127.0.0.1 --port $port --api-key-file keyfile -c 4096 -t 4 -np 1 --ssl-key-file certs/key.pem --ssl-cert-file certs/cert.pem > out/server-julia-$tag-tls.log 2>&1 &
spid=$!
# TLS-OFF-OK: recorded evidence script, loopback 127.0.0.1 only, throw-away self-signed certificate generated above (class sweep 2026-10-22)
for i in $(seq 1 60); do c=$(curl -sk -o /dev/null -w "%{http_code}" https://127.0.0.1:$port/health); [ "$c" = 200 ] && break; sleep 1; done
echo "=== HTTPS (compiled-in OpenSSL) health=$c"
echo "plain HTTP to TLS port ->" $(curl -s -m 5 -o /dev/null -w "%{http_code}" http://127.0.0.1:$port/health) "(000 = reset/refused)"
BODY="{\"state\":\"I was charged twice.\",\"questions\":{\"angry\":{\"type\":\"noul\",\"instructions\":\"Is the customer angry?\"}}}"
# TLS-OFF-OK: recorded evidence script, loopback 127.0.0.1 only, throw-away self-signed certificate generated above (class sweep 2026-10-22)
echo "https systemone ->"; curl -sk -H @hdrfile -H "Content-Type: application/json" https://127.0.0.1:$port/v1/systemone -d "$BODY"; echo
# TLS-OFF-OK: recorded evidence script, loopback 127.0.0.1 only, throw-away self-signed certificate generated above (class sweep 2026-10-22)
echo "=== 400 invalid"; curl -s -o /dev/stdout -w " [%{http_code}]\n" -H @hdrfile -H "Content-Type: application/json" -k https://127.0.0.1:$port/v1/systemone -d "{\"state\":\"x\",\"questions\":{\"q\":{\"type\":\"choice\",\"instructions\":\"i\",\"criteria\":{\"only\":null}}}}"
echo "=== large input (default batch) ~ 1500 tokens"
python3 - $port <<"P" > out/large.txt
import json,sys,urllib.request,ssl
# TLS-OFF-OK: recorded evidence script, loopback 127.0.0.1 only, throw-away self-signed certificate generated above (class sweep 2026-10-22)
ctx=ssl._create_unverified_context(); K=open("keyfile").read().strip()
st=("The invoice was sent to accounting. "*300)
b=json.dumps({"state":st,"questions":{"angry":{"type":"noul","instructions":"Is the sender angry?"}}}).encode()
r=urllib.request.Request(f"https://127.0.0.1:{sys.argv[1]}/v1/systemone",data=b,headers={"Authorization":"Bearer "+K,"Content-Type":"application/json"})
try:
    f=urllib.request.urlopen(r,context=ctx,timeout=60); print(f.status,f.read().decode()[:300])
except Exception as e: print("ERR",getattr(e,"code",None),getattr(e,"read",lambda:b"")()[:300])
P
cat out/large.txt
grep -E "VmHWM" /proc/$spid/status | sed "s/^/julia-server /"
kill $spid; wait $spid 2>/dev/null
echo "=== chat model on NEW build -> /v1/systemone"
port=$(pp)
llama.cpp-$tag/build/bin/llama-server -m models/Llama-3.2-3B-Instruct-Q4_K_M.gguf --host 127.0.0.1 --port $port --api-key-file keyfile -c 2048 -t 4 -np 1 > out/server-chat-$tag-sys1.log 2>&1 &
spid=$!
for i in $(seq 1 90); do c=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$port/health); [ "$c" = 200 ] && break; sleep 1; done
curl -s -w " [%{http_code}]\n" -H @hdrfile -H "Content-Type: application/json" http://127.0.0.1:$port/v1/systemone -d "$BODY"
kill $spid; wait $spid 2>/dev/null
echo "=== old build --help ssl flags"; llama.cpp-b10969/build/bin/llama-server --help 2>&1 | grep -c -E "ssl-(key|cert)-file"
echo "listening sockets of ours: $(ss -ltnp 2>/dev/null | grep -c llama-server)"
