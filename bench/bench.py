#!/usr/bin/env python3
"""Single-stream speed benchmark for any OpenAI-compatible server.

Standard library only, so it runs anywhere Python 3.8+ does: on the Spark itself,
or on your Mac over the network.

What it measures:
  decode tok/s   = generated tokens / time between the first and last token
                   (greedy, 256 tokens, 4 prompts x 3 repeats, median reported)
  prefill tok/s  = prompt tokens / time to first token, for ~8k and ~32k prompts
                   (a unique prefix per run, so the prefix cache cannot help)

  python3 bench/bench.py --url http://localhost:18300/v1 --label spark-speed
  python3 bench/bench.py --url http://spark-1234.local:18300/v1 --label from-mac

The API key is read from --api-key or the SPARK_API_KEY environment variable.
Results go to results/results-<label>.json.
"""
import argparse, json, os, statistics, time, urllib.request

PROMPTS = {
    "prose": "Write a detailed short story about a lighthouse keeper who discovers a message in a bottle.",
    "code": "Write a Python module implementing an LRU cache with TTL expiry, thread safety, and unit tests.",
    "json": "Return a JSON array of 12 fictional employees with fields id, name, department, salary, skills (list).",
    "math": "Solve step by step: a train leaves at 3pm at 80 km/h, another at 4pm at 110 km/h on the same track. When and where does the second catch up?",
}
# Long-context prefill probes: filler text of roughly N tokens, then a question.
LONG_CONTEXTS = [8_000, 32_000]
FILLER = "The quick brown fox jumps over the lazy dog while the archivist catalogues every page. "


def stream(url, model, prompt, max_tokens, api_key):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
        "stream_options": {"include_usage": True},
        # Keep thinking off so every run generates the same kind of tokens.
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(f"{url}/chat/completions", body, headers)
    t0 = time.perf_counter()
    t_first = t_last = None
    usage = None
    with urllib.request.urlopen(req, timeout=1800) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            chunk = json.loads(line[5:])
            if chunk.get("usage"):
                usage = chunk["usage"]
            for c in chunk.get("choices", []):
                d = c.get("delta", {})
                if d.get("content") or d.get("reasoning_content") or d.get("reasoning"):
                    now = time.perf_counter()
                    t_first = t_first or now
                    t_last = now
    ttft = t_first - t0
    n_out = usage["completion_tokens"]
    return {
        "prompt_tokens": usage["prompt_tokens"],
        "completion_tokens": n_out,
        "ttft_s": round(ttft, 3),
        "prefill_tps": round(usage["prompt_tokens"] / ttft, 1),
        "decode_tps": round((n_out - 1) / (t_last - t_first), 2) if n_out > 1 else None,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True, help="base URL ending in /v1")
    ap.add_argument("--model", default="qwen3.8-flash-next")
    ap.add_argument("--label", required=True, help="name for this run, used in the output file name")
    ap.add_argument("--api-key", default=os.environ.get("SPARK_API_KEY", ""))
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--out-dir", default="results")
    args = ap.parse_args()
    url = args.url.rstrip("/")

    print("warmup ...", flush=True)
    stream(url, args.model, "Say hello.", 16, args.api_key)

    results = {"label": args.label, "url": url, "short": {}, "long": {}}
    for name, prompt in PROMPTS.items():
        runs = [stream(url, args.model, prompt, args.max_tokens, args.api_key) for _ in range(args.repeats)]
        med = statistics.median(r["decode_tps"] for r in runs)
        results["short"][name] = {"decode_tps_median": med, "runs": runs}
        print(f"{name:6s} decode {med:6.2f} tok/s  (runs: {[r['decode_tps'] for r in runs]})", flush=True)

    for n in LONG_CONTEXTS:
        # A unique prefix per run defeats prefix caching, so this measures cold prefill.
        filler = FILLER * (n // 18)
        prompt = f"[run {time.time_ns()}]\n{filler}\nIn one sentence, what is the archivist doing?"
        r = stream(url, args.model, prompt, 64, args.api_key)
        results["long"][str(n)] = r
        # The answer is only ~10 tokens long, so its decode speed is too noisy to report.
        print(f"ctx~{n//1000}k prefill {r['prefill_tps']:8.1f} tok/s  ttft {r['ttft_s']}s", flush=True)

    all_dec = [v["decode_tps_median"] for v in results["short"].values()]
    results["decode_tps_overall_median"] = round(statistics.median(all_dec), 2)
    print(f"\n{args.label}: overall median decode {results['decode_tps_overall_median']:.2f} tok/s")
    os.makedirs(args.out_dir, exist_ok=True)
    out = os.path.join(args.out_dir, f"results-{args.label}.json")
    with open(out, "w") as f:
        json.dump(results, f, indent=2)
    print(f"saved {out}")


if __name__ == "__main__":
    main()
