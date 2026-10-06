#!/usr/bin/env bash
# Run on the Mac (or any machine on the same network) to check that the Spark's
# server is reachable, the API key works, and how fast it answers from here.
#
#   SPARK_API_KEY=... ./mac/check-connection.sh spark-1234.local
#   SPARK_API_KEY=... ./mac/check-connection.sh 192.168.1.50
set -uo pipefail
host="${1:-}"
[ -n "$host" ] || { echo "usage: $0 <spark hostname or IP>"; exit 1; }
base="http://$host:${PORT:-18300}"
auth=()
[ -n "${SPARK_API_KEY:-}" ] && auth=(-H "Authorization: Bearer $SPARK_API_KEY")

printf '1. server reachable ... '
if curl -sf -m 5 "$base/health" >/dev/null; then echo OK; else
  echo FAILED
  echo "   Cannot reach $base. Check: the server is running (./scripts/health.sh on the Spark),"
  echo "   the host name or IP is right (try the IP if .local fails), both machines are on the same network,"
  echo "   and no firewall on the Spark blocks port ${PORT:-18300} (sudo ufw status)."
  exit 1
fi

printf '2. API key accepted ... '
# ${auth[@]+...}: macOS ships bash 3.2, where an empty array trips `set -u`.
code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' ${auth[@]+"${auth[@]}"} "$base/v1/models")"
case "$code" in
  200) echo OK ;;
  401) echo "FAILED (401): set SPARK_API_KEY to the value in .env on the Spark"; exit 1 ;;
  *)   echo "FAILED (HTTP $code)"; exit 1 ;;
esac

printf '3. test generation  ... '
python3 - "$base" "${SPARK_API_KEY:-}" <<'PY'
import json, sys, time, urllib.request
base, key = sys.argv[1], sys.argv[2]
body = json.dumps({"model": "qwen3.8-flash-next", "max_tokens": 200, "temperature": 0, "stream": True,
                   "stream_options": {"include_usage": True},
                   "messages": [{"role": "user", "content": "Write a haiku about a fast computer, then explain it."}],
                   "chat_template_kwargs": {"enable_thinking": False}}).encode()
h = {"Content-Type": "application/json"}
if key:
    h["Authorization"] = f"Bearer {key}"
t0 = time.perf_counter(); first = last = None; n = 0
with urllib.request.urlopen(urllib.request.Request(base + "/v1/chat/completions", body, h), timeout=120) as r:
    for raw in r:
        line = raw.decode().strip()
        if not line.startswith("data:") or line == "data: [DONE]":
            continue
        chunk = json.loads(line[5:])
        if chunk.get("usage"):
            n = chunk["usage"]["completion_tokens"]
        if any(c.get("delta", {}).get("content") for c in chunk.get("choices", [])):
            first = first or time.perf_counter(); last = time.perf_counter()
print(f"OK: first token after {first - t0:.2f}s, {(n - 1) / (last - first):.1f} tok/s")
PY
