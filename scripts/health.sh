#!/usr/bin/env bash
# Check that the Spark and the server are in a state that gives full speed.
#
#   ./scripts/health.sh
#
# The most important check is the GPU clock under load. A healthy GB10 runs at
# ~2,400 MHz while generating. After an out-of-memory crash it can get stuck at
# ~700 MHz with no error anywhere, and everything runs 3x slower.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
problems=0

step "Memory"
total="$(mem_gib MemTotal)"; avail="$(mem_gib MemAvailable)"
swap_used="$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{printf "%.1f", (t-f)/1048576}' /proc/meminfo)"
info "$avail of $total GiB available, $swap_used GiB swap in use"
sw="$(cat /proc/sys/vm/swappiness)"
if [ "$sw" -le 10 ]; then ok "vm.swappiness $sw"; else warn "vm.swappiness is $sw, 10 is recommended"; problems=$((problems+1)); fi
if pgrep -fi 'lm.?studio|llmster' >/dev/null; then
  warn "LM Studio is running: make sure it has no model loaded and JIT loading is off"
fi

step "Server"
state="$(container_state)"
if [ "$state" != running ]; then
  bad "$NAME is $state. Start it with ./scripts/serve.sh"
  exit 1
fi
ok "$NAME is running"
args="$(docker inspect -f '{{join .Args " "}}' "$NAME")"
policy="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$NAME")"
info "$(grep -oE 'gpu-memory-utilization [^ ]+|max-model-len [^ ]+' <<<"$args" | tr '\n' ' ')"
if [ "$policy" = no ]; then ok "restart policy 'no'"; else warn "restart policy '$policy': run  docker update --restart=no $NAME"; problems=$((problems+1)); fi
if grep -q -- '--api-key' <<<"$args"; then ok "API key required"; else warn "no API key: anyone on your network can use the server"; fi

if ! curl -sf -m 3 "http://127.0.0.1:$PORT/health" >/dev/null; then
  warn "API not answering yet (still loading?). Try again in a minute."
  exit 1
fi
ok "API answering on port $PORT"
oom="$(docker logs "$NAME" 2>&1 | grep -ciE 'out of memory|OutOfMemory' || true)"
[ "$oom" = 0 ] || { warn "the server log mentions out-of-memory $oom times"; problems=$((problems+1)); }

step "GPU clock under load"
python3 - "$PORT" "$SPARK_API_KEY" <<'PY' &
import json, sys, urllib.request
port, key = sys.argv[1], sys.argv[2]
body = json.dumps({"model": "qwen3.8-flash-next", "max_tokens": 400, "temperature": 0,
                   "messages": [{"role": "user", "content": "Write a long story about a lighthouse."}],
                   "chat_template_kwargs": {"enable_thinking": False}}).encode()
h = {"Content-Type": "application/json"}
if key:
    h["Authorization"] = f"Bearer {key}"
urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", body, h), timeout=120).read()
PY
load_pid=$!
sleep 3
max=0
for _ in 1 2 3 4 5; do
  c="$(nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits | head -1 | tr -d ' ')"
  [ "${c:-0}" -gt "$max" ] && max="$c"
  sleep 1
done
wait "$load_pid" || { bad "test request failed (wrong API key in .env?)"; problems=$((problems+1)); }
if [ "$max" -ge 2000 ]; then
  ok "SM clock $max MHz under load"
else
  bad "SM clock only $max MHz under load (healthy: ~2,400). The GPU is stuck in a slow state."
  info "fix: shut down, unplug the power brick for 10+ minutes, power on. See docs/TROUBLESHOOTING.md"
  problems=$((problems+1))
fi

echo
[ "$problems" = 0 ] && echo "All good." || echo "$problems problem(s) found, see above."
