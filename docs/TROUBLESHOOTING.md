# Troubleshooting

Everything here happened on my DGX Spark while setting this up. For problems with the recipe
itself (image build, download, vLLM errors), see the
[recipe's README](https://github.com/blazux/qwen3.8-Flash-DGX#limitations--notes) and its
issues.

- [Decode is ~3x slower than it should be (GPU stuck at ~700 MHz)](#decode-is-3x-slower-than-it-should-be-gpu-stuck-at-700-mhz)
- [The server crashes while booting](#the-server-crashes-while-booting)
- [Larger context doesn't fit](#larger-context-doesnt-fit)
- [It got slower after running for a while](#it-got-slower-after-running-for-a-while)
- [The Mac can't connect](#the-mac-cant-connect)
- [`./flash test` fails, or `flash wait` shows model 'unknown'](#flash-test-fails-or-flash-wait-shows-model-unknown)

## Decode is ~3x slower than it should be (GPU stuck at ~700 MHz)

**Symptoms:** ~11–17 tok/s instead of ~50, and decode speed jumps around between identical
runs. While generating, `nvidia-smi` shows the GPU busy (~96%) but at a low clock and power,
with no throttle reason:

```bash
nvidia-smi --query-gpu=clocks.sm,power.draw,utilization.gpu --format=csv
# stuck:   689 MHz, 15 W, 96 %
# healthy: 2450 MHz, 40-90 W, 96 %
```

`./scripts/health.sh` checks this for you.

**Cause:** a known GB10 problem. The GPU gets stuck in a low clock state, most often after it
runs out of memory. On my Spark it happened each time vLLM crashed with out-of-memory errors
during boot. You can see those in the kernel log:

```bash
journalctl -k | grep NV_ERR_NO_MEMORY
```

Other people have reported the same state after a failed USB-C power negotiation.

**Fix:** a cold power cycle. A reboot is not enough, and neither is `sudo nvidia-smi -rgc`.
1. Shut down the Spark.
2. **Unplug the power brick** and wait at least 10 minutes. Once 7 minutes was not enough
   and it took ~30.
3. Power on and run `./scripts/health.sh` with the server running.

**Prevention:** don't let vLLM run out of memory. That is why `serve.sh` checks free memory
before it boots and turns off the container's auto-start.

## The server crashes while booting

**Symptoms:** `./flash wait` reports the container exited, and the log (`docker logs
qwen38-flash`) says there is not enough memory for the KV cache, or less than what
`GPU_MEM` asks for.

**Cause:** something else took memory while the model was loading. What did it on my Spark:
- **LM Studio** loaded a model during the boot. Even with its window closed, its background
  service (`llmster`) can load models on demand ("JIT loading") when something calls its API
  on port 1234, and any `lms` command starts that service. Unload all models and turn off JIT
  loading in LM Studio's developer settings, or quit LM Studio completely.
- **Auto-start at power-on:** with Docker's `--restart unless-stopped` (the recipe's default),
  the container started while the desktop and other apps were still starting, and lost the
  race for memory. `serve.sh` sets the restart policy to `no` after every start. If you start
  the server with the recipe's `./flash serve` directly, run
  `docker update --restart=no qwen38-flash` afterwards.

After a crash like this, check the GPU clock (see above) before benchmarking.

## Larger context doesn't fit

Context costs memory for the KV cache, and `GPU_MEM` limits the total. What I tested:

| `GPU_MEM` | `CTX` | Result |
|---|---|---|
| 0.72 | 131,072 | works, KV pool ~154–183k tokens |
| 0.72 | 200,000 or 500,000 | fails to boot: max ~192–216k at this `GPU_MEM` |
| **0.76** | **262,144** | **works, KV pool ~361k tokens (this guide's default)** |
| 0.80 | 262,144 | works, but only ~8 GiB left for the system: swapping, slower decode |

Above 262,144 the recipe uses YaRN scaling (`serve.sh` turns it on automatically) and needs a
higher `GPU_MEM`. The recipe's own default is 500k at 0.80, which assumes nothing else runs on
the Spark.

## It got slower after running for a while

Check whether the system is swapping while you generate:

```bash
vmstat 5      # the si/so columns should stay near 0
free -g
```

If they don't, something else is using memory: browsers, Docker containers, LM Studio,
ComfyUI. Close it, or restart the server with `RESTART=1 CTX=131072 GPU_MEM=0.72
./scripts/serve.sh` for ~5 GB more headroom. Also check that `vm.swappiness` is 10 (README,
Part 1, step 2).

## The Mac can't connect

Run `./mac/check-connection.sh <host>` on the Mac, which tells you which step fails.

- **Host name doesn't resolve:** `spark-xxxx.local` relies on mDNS, which some routers and
  VPNs block. Use the IP address instead (`hostname -I` on the Spark). To keep it stable,
  give the Spark a DHCP reservation in your router.
- **Firewall:** DGX OS includes `ufw` (inactive by default). If `sudo ufw status` says active, allow the port:
  `sudo ufw allow 18300/tcp`.
- **Different networks:** guest Wi-Fi networks usually block traffic between devices. Put
  both machines on the main network.
- **HTTP 401:** the key on the Mac doesn't match. Compare `echo $SPARK_API_KEY` on the Mac
  with `grep SPARK_API_KEY .env` on the Spark. Open a new terminal after editing `~/.zshrc`.
- **opencode shows no Spark model:** check that `~/.config/opencode/opencode.json` is valid
  JSON and that `YOUR-SPARK-HOST` is replaced, then restart opencode and run `/models`.

## `./flash test` fails, or `flash wait` shows model 'unknown'

That is expected when the server has an API key: the recipe's smoke test and `flash wait`
call the API without one. The server itself is fine; use `./scripts/health.sh` instead.
