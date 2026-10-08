#!/usr/bin/env bash
# curl matrix adapter (see README.md for the protocol). Reads headers from a file,
# never prints them.
set -u
method="$1"; url="$2"; cacert="$3"; tmo="$4"; bodyf="$5"; hdrf="$6"
command -v curl >/dev/null || { echo "ERROR curl not installed"; exit 2; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
args=(--silent --show-error --max-time "$tmo" -X "$method" -o "$tmp/body" -D "$tmp/hdr")
[[ "$cacert" != "-" ]] && args+=(--cacert "$cacert")
if [[ "$hdrf" != "-" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && args+=(-H "$line")
  done <"$hdrf"
fi
# keep curl from inventing a Content-Type when a body is sent without one
[[ "$bodyf" != "-" ]] && args+=(--data-binary "@$bodyf")
args+=(-w '%{http_code}' "$url")
code="$(curl "${args[@]}" 2>"$tmp/err")"; rc=$?
if [[ $rc -ne 0 || "$code" == "000" ]]; then
  echo "ERROR curl rc=$rc: $(tr '\n' ' ' <"$tmp/err")"
  exit 0
fi
echo "STATUS $code"
# last header block only (curl -D keeps interim blocks such as 100-continue)
awk 'BEGIN{RS="\r\n\r\n"} {blk=$0} END{n=split(blk,l,"\r\n"); for(i=2;i<=n;i++) if(l[i]!="") print "HEADER " tolower(substr(l[i],1,index(l[i],":")-1)) ":" substr(l[i],index(l[i],":")+1)}' "$tmp/hdr"
echo "BODY_B64 $(base64 -w0 <"$tmp/body")"
