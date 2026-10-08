#!/bin/bash
tag=$1; run=${2:-1}; cd ~/llmctl-work; mkdir -p out certs
export LD_LIBRARY_PATH=llama.cpp-$tag/build/bin
port=$(python3 -c "import socket;s=socket.socket();s.bind((\"127.0.0.1\",0));print(s.getsockname()[1]);s.close()")
llama.cpp-$tag/build/bin/llama-server -m models/Julia-1-Q8_0.gguf --host 127.0.0.1 --port $port --api-key-file keyfile -c 4096 -t 4 -np 1 > out/server-julia-$tag-r$run.log 2>&1 &
spid=$!
for i in $(seq 1 90); do c=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$port/health); [ "$c" = 200 ] && break; sleep 1; done
echo "tag=$tag run=$run port=$port health=$c"
if [ "$c" = 200 ]; then
  python3 sys1.py $port "$(cat keyfile)" out $tag-julia-r$run
  grep -E "VmHWM|VmRSS" /proc/$spid/status | sed "s/^/server /"
  curl -s -H "Authorization: Bearer $(cat keyfile)" http://127.0.0.1:$port/v1/models | head -c 300; echo
fi
kill $spid; wait $spid 2>/dev/null
