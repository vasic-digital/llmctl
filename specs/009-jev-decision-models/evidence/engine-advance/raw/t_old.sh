#!/bin/bash
tag=b10969; cd ~/llmctl-work; export LD_LIBRARY_PATH=llama.cpp-$tag/build/bin
K=$(cat keyfile)
echo "=== (a) Julia on old pin"
port=$(python3 -c "import socket;s=socket.socket();s.bind((\"127.0.0.1\",0));print(s.getsockname()[1]);s.close()")
llama.cpp-$tag/build/bin/llama-server -m models/Julia-1-Q8_0.gguf --host 127.0.0.1 --port $port --api-key-file keyfile -c 4096 -t 4 -np 1 > out/server-julia-$tag.log 2>&1 &
spid=$!
for i in $(seq 1 40); do c=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$port/health); [ "$c" = 200 ] && break; kill -0 $spid 2>/dev/null || break; sleep 1; done
echo "julia old-pin health=$c alive=$(kill -0 $spid 2>/dev/null && echo yes || echo no)"
if [ "$c" = 200 ]; then python3 sys1.py $port "$K" out $tag-julia; fi
kill $spid 2>/dev/null; wait $spid 2>/dev/null
grep -i -E "error|unknown|unsupported|failed" out/server-julia-$tag.log | head -5
echo "=== (b) /v1/systemone on old pin with chat model"
port=$(python3 -c "import socket;s=socket.socket();s.bind((\"127.0.0.1\",0));print(s.getsockname()[1]);s.close()")
llama.cpp-$tag/build/bin/llama-server -m models/Llama-3.2-3B-Instruct-Q4_K_M.gguf --host 127.0.0.1 --port $port --api-key-file keyfile -c 2048 -t 4 -np 1 > out/server-chat-$tag-systemone.log 2>&1 &
spid=$!
for i in $(seq 1 90); do c=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$port/health); [ "$c" = 200 ] && break; sleep 1; done
echo "chat old-pin health=$c"
python3 sys1.py $port "$K" out $tag-chat
kill $spid; wait $spid 2>/dev/null
