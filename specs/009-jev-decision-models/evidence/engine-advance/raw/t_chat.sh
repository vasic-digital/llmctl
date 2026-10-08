#!/bin/bash
tag=$1; cd ~/llmctl-work; export LD_LIBRARY_PATH=llama.cpp-$tag/build/bin; K=$(cat keyfile)
port=$(python3 -c "import socket;s=socket.socket();s.bind((\"127.0.0.1\",0));print(s.getsockname()[1]);s.close()")
llama.cpp-$tag/build/bin/llama-server -m models/Llama-3.2-3B-Instruct-Q4_K_M.gguf --host 127.0.0.1 --port $port --api-key-file keyfile -c 2048 -t 4 -np 1 > out/server-chat-$tag.log 2>&1 &
spid=$!
for i in $(seq 1 90); do c=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$port/health); [ "$c" = 200 ] && break; sleep 1; done
echo "tag=$tag health=$c"
for i in 1 2; do
curl -s -H "Authorization: Bearer $K" -H "Content-Type: application/json" http://127.0.0.1:$port/v1/chat/completions -d "{\"messages\":[{\"role\":\"user\",\"content\":\"List the first five prime numbers, comma separated, nothing else.\"}],\"temperature\":0,\"seed\":42,\"max_tokens\":40}" > out/chat-$tag-chat-$i.json
curl -s -H "Authorization: Bearer $K" -H "Content-Type: application/json" http://127.0.0.1:$port/completion -d "{\"prompt\":\"The capital of France is\",\"temperature\":0,\"seed\":42,\"n_predict\":24,\"cache_prompt\":false}" > out/chat-$tag-compl-$i.json
done
python3 - $tag <<"P"
import json,sys
t=sys.argv[1]
for k in ("chat","compl"):
    a=json.load(open(f"out/chat-{t}-{k}-1.json")); b=json.load(open(f"out/chat-{t}-{k}-2.json"))
    txt=(lambda d:d["choices"][0]["message"]["content"] if k=="chat" else d["content"])
    print(k,"repeat-identical-text:",txt(a)==txt(b),"|",repr(txt(a)))
P
grep -E "VmHWM" /proc/$spid/status | sed "s/^/server /"
kill $spid; wait $spid 2>/dev/null
