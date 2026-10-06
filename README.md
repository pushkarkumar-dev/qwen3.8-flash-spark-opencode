# Qwen3.8-Flash-Next on a DGX Spark, used from a Mac with opencode

Run **Qwen3.8-Flash-Next** (176B parameters, 6B active) on one **NVIDIA DGX Spark** at
**~50 tokens/s**, and use it as a local coding agent from your **Mac** over your home
network with [opencode](https://opencode.ai). No cloud, no API bills, and your code stays
on your network.

The hard part, fitting a 125 GiB checkpoint plus a usable context window into the Spark's
128 GB, is solved by the excellent
**[Blazux recipe](https://github.com/blazux/qwen3.8-Flash-DGX)** (a patched vLLM). This repo
does not change that recipe. It adds what I needed to run it day to day and to use it from
another machine:

- **One-command setup and start** with settings tested on a real Spark, plus a memory check
  that refuses to boot when the boot would crash
- **A health check** that catches the GB10's silent "stuck at 700 MHz" slowdown
- **An opencode config for the Mac**, and a script that tests the connection
- **A benchmark** you can run on the Spark or from the Mac, with my reference numbers
- **Troubleshooting notes** for everything that went wrong along the way

```
┌──────────────── Mac ─────────────────┐            ┌────────────── DGX Spark ───────────────┐
│ opencode ─── HTTP + API key ─────────┼── LAN ────►│ :18300  vLLM (Blazux recipe, Docker)   │
│ (or any OpenAI-compatible client)    │            │         Qwen3.8-Flash-Next NVFP4, 262k │
└──────────────────────────────────────┘            └────────────────────────────────────────┘
```

## Results

Measured on my DGX Spark: one request at a time, greedy decoding, 256 generated tokens,
median of 3 runs. Made with [`bench/bench.py`](bench/bench.py); the raw files are in
[`results/reference/`](results/reference/).

| Setup | Decode, tok/s | Prefill, tok/s (8k / 32k prompt) |
|---|---|---|
| **This guide:** Blazux `speed`, 262k context, `GPU_MEM=0.76` | **51.0** | **2,830 / 3,024** |
| Blazux `speed`, 128k context, `GPU_MEM=0.72` | 52.4 | 2,339 / 3,004 |
| Blazux `default`, 128k context, `GPU_MEM=0.72` | 47.8 | 2,539 / 2,977 |
| llama.cpp, Unsloth UD-IQ4_XS GGUF + MTP draft (n_max 3) | 55.5 | 594 / 541 |

Decode speed depends on the kind of text: prose is slowest (~33 tok/s), code ~48, JSON and
math 54–58, because speculative decoding (MTP) guesses predictable text better.

**Why vLLM rather than llama.cpp for a coding agent:** decode speed is about the same, but
prefill is **~5x faster**. A coding agent sends long prompts (system prompt, tool
definitions, file contents) on every turn. With a 32k-token prompt, the first token arrives
after **~11 s** here, versus **~60 s** with llama.cpp.

## What you need

**On the Spark**
- NVIDIA DGX Spark (or another GB10 box, such as the ASUS Ascent GX10) with DGX OS, Docker
  and the NVIDIA container runtime (all preinstalled on DGX OS)
- **~140 GB free disk** for the model, and a decent internet connection for the one-time
  ~124 GiB download
- Optional: a [Hugging Face token](https://huggingface.co/settings/tokens)
  (`export HF_TOKEN=hf_...` before setup) so the download isn't rate-limited
- Nothing else big running: the model takes ~93 GiB of the 128 GB memory pool. Unload LM
  Studio, Ollama and similar while it runs.

**On the Mac**
- [opencode](https://opencode.ai)
- The same network as the Spark (wired Ethernet on both is best, Wi-Fi works)

## Part 1: on the Spark

### 1. Clone and set up (one time, 30–90 min)

```bash
git clone https://github.com/pushkarkumar-dev/qwen3.8-flash-spark-opencode.git
cd qwen3.8-flash-spark-opencode
./scripts/setup.sh
```

`setup.sh` does three things, and skips any that are already done:
1. Creates `.env` with a random **API key**, so only you can use the server on your network.
   The key is optional: on a home network you trust, you can empty the `SPARK_API_KEY=` line
   in `.env` and skip the key steps on the Mac. Keep it on shared networks (office, dorm).
2. Clones the [Blazux recipe](https://github.com/blazux/qwen3.8-Flash-DGX) into
   `qwen3.8-Flash-DGX/`, at the commit this guide was tested with (`5d944b3`).
3. Runs the recipe's own `./flash setup`: builds the vLLM Docker image, downloads
   `nvidia/Qwen3.8-Flash-Next-NVFP4` (~124 GiB, resumable), and prepares its faster
   "hybrid" layout.

### 2. Lower swappiness (one time, needs sudo)

The Spark's default `vm.swappiness` of 60 lets Linux swap out memory the model is using,
which slows it down. The recipe recommends 10:

```bash
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl --system
```

### 3. Start the server (~4 min)

```bash
./scripts/serve.sh
```

The script:
- **checks free memory first** and refuses to start if the boot would run out of memory
  (see [why that matters](docs/TROUBLESHOOTING.md#decode-is-3x-slower-than-it-should-be-gpu-stuck-at-700-mhz))
- starts the recipe's `speed` profile with 262k context, your API key, and the model table
  pre-loaded into memory
- turns off Docker's auto-restart, so the server does not race your desktop for memory at
  power-on. After a reboot, start it again with `./scripts/serve.sh`.
- waits until the model is loaded, then prints the addresses your Mac can use, for example
  `http://spark-1234.local:18300/v1`

### 4. Check it is healthy

```bash
./scripts/health.sh
```

This checks memory, swap, the server settings, and, most importantly, the **GPU clock while
generating**. It should be ~2,400 MHz. If it says ~700 MHz, see
[Troubleshooting](docs/TROUBLESHOOTING.md#decode-is-3x-slower-than-it-should-be-gpu-stuck-at-700-mhz).

## Part 2: on the Mac

### 1. Install opencode

```bash
curl -fsSL https://opencode.ai/install | bash
```

(or see [opencode.ai](https://opencode.ai) for Homebrew and other options)

### 2. Get this repo (and your API key)

```bash
git clone https://github.com/pushkarkumar-dev/qwen3.8-flash-spark-opencode.git
cd qwen3.8-flash-spark-opencode
```

If you use an API key, copy it from the Spark (run this on the Spark: `grep SPARK_API_KEY .env`),
then add it to your shell on the Mac:

```bash
echo 'export SPARK_API_KEY=paste-your-key-here' >> ~/.zshrc
source ~/.zshrc
```

### 3. Test the connection

Use the host name or IP that `serve.sh` printed:

```bash
./mac/check-connection.sh spark-1234.local
```

```
1. server reachable ... OK
2. API key accepted ... OK
3. test generation  ... OK: first token after 0.18s, 34.4 tok/s
```

(The test prompt is short prose, the slowest kind of text; code runs faster.)

### 4. Configure opencode

Open [`mac/opencode.json`](mac/opencode.json), replace `YOUR-SPARK-HOST` with your Spark's
host name or IP, and install it as your global opencode config:

```bash
mkdir -p ~/.config/opencode
cp mac/opencode.json ~/.config/opencode/opencode.json
```

Already have an `~/.config/opencode/opencode.json`? Don't overwrite it: copy the `"spark"`
entry into its `"provider"` section instead. (Or drop the file into a single project's root
as `opencode.json` to use the Spark only there.)

### 5. Code

```bash
cd ~/your-project
opencode
```

The Spark model is the default. Use `/models` inside opencode to switch between it and
other providers.

## Day to day (on the Spark)

| What | Command |
|---|---|
| Start (also after a reboot) | `./scripts/serve.sh` |
| Restart with other settings | `RESTART=1 CTX=131072 GPU_MEM=0.72 ./scripts/serve.sh` |
| Stop and free the memory | `./scripts/stop.sh` |
| Health check | `./scripts/health.sh` |
| Server logs | `docker logs -f qwen38-flash` |
| Benchmark | `python3 bench/bench.py --url http://localhost:18300/v1 --label my-run` |

The benchmark runs from the Mac too: point `--url` at the Spark. It reads the key from
`SPARK_API_KEY`.

## The settings, and why

All settings live in `.env` (see [`.env.example`](.env.example)), and environment
variables on the command line override them.

| Setting | Value | Why |
|---|---|---|
| `PROFILE` | `speed` | The recipe's fastest profile: MTP speculative decoding with 3 draft tokens. `default` is ~7% slower and scores slightly better on the recipe author's agentic tests. |
| `CTX` | `262144` | The model's native context, no RoPE scaling needed, and plenty for opencode. The recipe can go to 500k with YaRN, but that needs more memory. |
| `GPU_MEM` | `0.76` | Share of the 128 GB pool vLLM takes. 0.76 fits 262k context with a ~2 GiB margin and leaves ~20 GiB for the OS, the desktop and page cache. At 0.80, decode slowed down from memory pressure and swapping. |
| `PREWARM` | `1` | Loads the model's 48 GiB lookup table (read from disk at runtime) into memory at boot, so the first requests aren't slow. |
| restart policy | `no` | The recipe sets `unless-stopped`. On my Spark, auto-starting at power-on raced the desktop for memory and crashed the boot. |

Need memory for something else? `CTX=131072 GPU_MEM=0.72` frees ~5 GB at the same speed.

## Other clients

The server is a standard OpenAI-compatible API, so anything that lets you set a base URL,
an API key and a model name works: base URL `http://<spark>:18300/v1`, model
`qwen3.8-flash-next`. Tool calling and reasoning output are on.

- **Open WebUI:** Settings → Connections → add an OpenAI connection with that URL and key.
- **ComfyUI:** [`extras/comfyui/blazux_llm.py`](extras/comfyui/blazux_llm.py) is a custom
  node for text generation in a workflow. Copy it into ComfyUI's `custom_nodes` folder and
  restart ComfyUI. It reads `SPARK_LLM_URL` and `SPARK_API_KEY` from the environment, so the
  key doesn't end up in saved workflow files.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). The most common problems:
- **Everything is ~3x slower than the numbers above:** the GPU is stuck at ~700 MHz. A full
  power-off with the power brick unplugged fixes it.
- **The server crashes while booting:** something else took memory (often LM Studio).
- **The Mac can't connect:** host name, firewall, or API key.

## Security

- The server listens on all network interfaces. Anyone on your network who has the API key
  can use it, so keep the key in `.env` (which git ignores) and in your Mac's shell profile,
  not in committed files.
- The API key is not encryption: traffic on your LAN is plain HTTP. Don't expose port 18300
  to the internet. To reach the Spark from outside, use a VPN such as Tailscale.
- `/health` and `/metrics` don't need the key, which is vLLM's normal behavior.

## Credits and licenses

- **[blazux/qwen3.8-Flash-DGX](https://github.com/blazux/qwen3.8-Flash-DGX)** (Apache-2.0)
  does all the real work: the vLLM patches, the mmapped lookup table, MTP, and the profiles.
  If this helps you, star that repo, and report recipe bugs there.
- **Qwen3.8-Flash-Next** is by the Qwen team; the NVFP4 checkpoint is by NVIDIA. The weights
  are not included here and come with their own license, which has usage conditions. Read it
  before any commercial use.
- [opencode](https://opencode.ai) is the coding agent used on the Mac.
- The code in this repo is MIT-licensed, see [LICENSE](LICENSE).
