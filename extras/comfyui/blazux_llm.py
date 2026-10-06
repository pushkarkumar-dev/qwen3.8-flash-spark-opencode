"""ComfyUI node: call an OpenAI-compatible chat server (default: the Qwen3.8-Flash-Next server on a DGX Spark).

Copy this file into ComfyUI's `custom_nodes` folder and restart ComfyUI.
Standard library only, so there is nothing to pip install.
"""
import json
import os
import re
import urllib.error
import urllib.request

# Change this to your Spark's host name or IP, or set it in the node.
DEFAULT_URL = os.environ.get("SPARK_LLM_URL", "http://YOUR-SPARK-HOST:18300/v1")
DEFAULT_MODEL = "qwen3.8-flash-next"


class BlazuxLLM:
    CATEGORY = "LLM"
    RETURN_TYPES = ("STRING", "STRING")
    RETURN_NAMES = ("text", "reasoning")
    FUNCTION = "generate"

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "prompt": ("STRING", {"multiline": True, "default": ""}),
                "system": ("STRING", {"multiline": True, "default": ""}),
                "base_url": ("STRING", {"default": DEFAULT_URL}),
                "model": ("STRING", {"default": DEFAULT_MODEL}),
                "reasoning_effort": (["low", "medium", "xhigh"], {"default": "low"}),
                "max_tokens": ("INT", {"default": 4096, "min": 16, "max": 131072}),
                "temperature": ("FLOAT", {"default": 0.7, "min": 0.0, "max": 2.0, "step": 0.05}),
                # Changing the seed forces a new answer; ComfyUI reuses cached output when inputs are unchanged.
                "seed": ("INT", {"default": 0, "min": 0, "max": 0xFFFFFFFF}),
            },
            "optional": {
                "api_key": ("STRING", {"default": ""}),
            },
        }

    def generate(self, prompt, system, base_url, model, reasoning_effort, max_tokens, temperature, seed, api_key=""):
        messages = []
        if system.strip():
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})
        body = {
            "model": model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "seed": seed,
            "reasoning_effort": reasoning_effort,
        }
        headers = {"Content-Type": "application/json"}
        # Falling back to the environment keeps the key out of saved workflow files.
        api_key = api_key.strip() or os.environ.get("SPARK_API_KEY", "")
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"
        req = urllib.request.Request(
            base_url.rstrip("/") + "/chat/completions", json.dumps(body).encode(), headers
        )
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                data = json.load(r)
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"LLM server returned {e.code}: {e.read().decode(errors='replace')[:500]}")
        except urllib.error.URLError as e:
            raise RuntimeError(f"Cannot reach LLM server at {base_url}: {e.reason}")

        msg = data["choices"][0]["message"]
        text = msg.get("content") or ""
        reasoning = msg.get("reasoning_content") or msg.get("reasoning") or ""
        # In case the server does not split reasoning out, drop any <think> block from the answer.
        m = re.search(r"<think>(.*?)</think>", text, re.S)
        if m:
            reasoning = reasoning or m.group(1)
            text = text.replace(m.group(0), "")
        if data["choices"][0].get("finish_reason") == "length" and not text.strip():
            raise RuntimeError("Ran out of max_tokens while reasoning; raise max_tokens or lower reasoning_effort.")
        return (text.strip(), reasoning.strip())


NODE_CLASS_MAPPINGS = {"BlazuxLLM": BlazuxLLM}
NODE_DISPLAY_NAME_MAPPINGS = {"BlazuxLLM": "Blazux LLM (OpenAI-compatible)"}
