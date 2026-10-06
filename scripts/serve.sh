#!/usr/bin/env bash
# Start the server on the DGX Spark with the settings this guide was tested with,
# after checking that there is enough free memory to boot safely.
#
#   ./scripts/serve.sh                       # speed profile, 262k context, GPU_MEM 0.76
#   CTX=131072 GPU_MEM=0.72 ./scripts/serve.sh   # more headroom for other apps
#   RESTART=1 ./scripts/serve.sh             # replace a server that is already running
#
# Why the pre-flight check: if vLLM runs out of memory while booting, the GB10
# can get stuck at ~700 MHz afterwards (about 1/3 of normal speed) until a full
# power-off. Refusing to boot is much cheaper than that.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_recipe

HEADROOM_GIB="${HEADROOM_GIB:-4}"
# Up to the model's native 262,144 tokens no RoPE scaling is needed; beyond it, YaRN.
if [ -z "${YARN:-}" ]; then
  if [ "$CTX" -le 262144 ]; then YARN=0; else YARN=1; fi
fi

step "Pre-flight"
state="$(container_state)"
if [ "$state" = running ]; then
  if [ "${RESTART:-0}" = 1 ]; then
    info "stopping the running $NAME"
    (cd "$RECIPE_DIR" && ./flash stop)
    sleep 5
  else
    die "$NAME is already running. Use RESTART=1 ./scripts/serve.sh to replace it, or ./scripts/stop.sh"
  fi
fi

total="$(mem_gib MemTotal)"; avail="$(mem_gib MemAvailable)"
need="$(awk -v t="$total" -v g="$GPU_MEM" -v h="$HEADROOM_GIB" 'BEGIN{printf "%.1f", t*g+h}')"
if awk -v a="$avail" -v n="$need" 'BEGIN{exit !(a>=n)}'; then
  ok "memory: $avail GiB available, $need GiB needed (GPU_MEM $GPU_MEM of $total GiB + $HEADROOM_GIB GiB headroom)"
else
  bad "memory: only $avail GiB available, $need GiB needed (GPU_MEM $GPU_MEM of $total GiB + $HEADROOM_GIB GiB headroom)"
  info "close other models first (LM Studio, Ollama, llama.cpp, ComfyUI), then check with: free -g"
  [ "${FORCE:-0}" = 1 ] || die "not booting. FORCE=1 overrides this check, at your own risk."
fi

if pgrep -fi 'lm.?studio|llmster' >/dev/null; then
  warn "LM Studio is running. If it loads a model during the boot, vLLM runs out of memory. Unload its models and turn off JIT loading."
fi
sw="$(cat /proc/sys/vm/swappiness)"
[ "$sw" -le 10 ] && ok "vm.swappiness $sw" || warn "vm.swappiness is $sw, 10 is recommended (see README)"

if [ -n "$SPARK_API_KEY" ]; then
  ok "API key set (from .env)"
  EXTRA="${EXTRA:-} --api-key $SPARK_API_KEY"
else
  warn "no SPARK_API_KEY: anyone on your network can use the server"
fi

step "Starting $NAME (profile $PROFILE, CTX $CTX, YARN $YARN, GPU_MEM $GPU_MEM)"
cd "$RECIPE_DIR"
./flash serve "$PROFILE" GPU_MEM="$GPU_MEM" CTX="$CTX" YARN="$YARN" PREWARM=1 EXTRA="${EXTRA:-}"

# The recipe starts the container with --restart unless-stopped. At power-on that
# makes it race the desktop for memory, which can crash the boot, so start it by hand.
docker update --restart=no "$NAME" >/dev/null
ok "restart policy set to 'no' (start it with this script after a reboot)"

step "Waiting for the model to load (~4 min)"
./flash wait

echo
echo "Ready. From another machine on your network, use one of:"
for a in $(lan_addresses); do echo "    http://$a:$PORT/v1"; done
echo "Model name: qwen3.8-flash-next"
