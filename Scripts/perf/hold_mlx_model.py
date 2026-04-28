#!/usr/bin/env python3
"""Load an MLX-LM model, hold weights resident in unified memory, run a
fixed refine prompt, then idle until killed.

Used by perf S6 to simulate a co-resident local refiner alongside the
VoiceTyping ASR backend. While this script is alive, its process holds
the LM weights in RAM — the foreground sampler measures VoiceTyping
process RSS independently, and macOS adds ours to total system pressure.

Usage:
  hold_mlx_model.py --model mlx-community/Qwen3.5-4B-MLX-4bit \\
                    [--hold-seconds 60] [--max-tokens 200]

Output (printed to stdout):
  pid=...
  load_seconds=...
  weights_loaded_rss_mb=...
  refine_seconds=...
  refine_tokens_per_sec=...
  refine_output_rss_mb=...
  ---refine output---
  <text>
  ---end output---
  holding for N seconds...
  done.
"""
import argparse
import os
import resource
import sys
import time


# A realistic ASR-output sample (zh-EN mix with filler / no punctuation),
# representative of what VoiceTyping's refiner would actually receive.
SAMPLE_ASR_OUTPUT = (
    "嗯 那个 我们今天 主要要做的事情就是 把这个 voice typing 的 perf "
    "baseline 这个事情收完 然后看一下 candidate B 那个本地 refiner "
    "能不能上 嗯就这样"
)

REFINE_SYSTEM_PROMPT = (
    "You are a text refiner for voice dictation. The input is raw ASR "
    "transcription with filler words, missing punctuation, and possible "
    "ASR errors. Output the cleaned-up text only — preserve meaning, "
    "remove fillers (嗯/那个/呃/uh/um), add proper punctuation, fix "
    "obvious errors. Keep the original mix of Chinese and English. "
    "Output only the refined text, no commentary or quotes."
)


def rss_mb() -> float:
    # macOS returns ru_maxrss in bytes (Linux returns KB). On macOS the
    # value is the *peak* RSS, not current — close enough for our use.
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    # macOS bytes vs Linux KB: detect by sniffing platform
    if sys.platform == "darwin":
        return rss / (1024 * 1024)
    return rss / 1024


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--hold-seconds", type=int, default=60,
                    help="Stay alive (holding weights) this many seconds "
                         "after refine completes, so the sampler can "
                         "capture the steady-state.")
    ap.add_argument("--max-tokens", type=int, default=200)
    args = ap.parse_args()

    print(f"pid={os.getpid()}", flush=True)
    print(f"model={args.model}", flush=True)
    print(f"loading...", flush=True)

    t0 = time.time()
    from mlx_lm import load, generate
    model, tokenizer = load(args.model)
    load_s = time.time() - t0
    print(f"load_seconds={load_s:.2f}", flush=True)
    print(f"weights_loaded_rss_mb={rss_mb():.0f}", flush=True)

    # Build a chat-formatted prompt if the tokenizer supports it (most
    # mlx-lm-quantized chat models do); otherwise fall back to plain.
    user_msg = f"{REFINE_SYSTEM_PROMPT}\n\nInput:\n{SAMPLE_ASR_OUTPUT}\n\nOutput:"
    try:
        if hasattr(tokenizer, "apply_chat_template"):
            messages = [
                {"role": "system", "content": REFINE_SYSTEM_PROMPT},
                {"role": "user", "content": SAMPLE_ASR_OUTPUT},
            ]
            # Try to disable thinking mode for reasoning models (Qwen3+).
            # Falls back to default template if the kwarg isn't supported.
            try:
                prompt = tokenizer.apply_chat_template(
                    messages, add_generation_prompt=True, tokenize=False,
                    enable_thinking=False,
                )
            except TypeError:
                prompt = tokenizer.apply_chat_template(
                    messages, add_generation_prompt=True, tokenize=False
                )
        else:
            prompt = user_msg
    except Exception:
        prompt = user_msg

    print(f"prompt_chars={len(prompt)}", flush=True)
    t0 = time.time()
    out = generate(model, tokenizer, prompt=prompt,
                   max_tokens=args.max_tokens, verbose=False)
    refine_s = time.time() - t0
    out_text = out if isinstance(out, str) else str(out)
    out_token_estimate = len(tokenizer.encode(out_text)) if hasattr(tokenizer, "encode") else len(out_text.split())

    print(f"refine_seconds={refine_s:.2f}", flush=True)
    if refine_s > 0:
        print(f"refine_tokens_per_sec={out_token_estimate / refine_s:.1f}", flush=True)
    print(f"refine_output_rss_mb={rss_mb():.0f}", flush=True)
    print("---refine output---", flush=True)
    print(out_text, flush=True)
    print("---end output---", flush=True)

    print(f"holding for {args.hold_seconds}s...", flush=True)
    time.sleep(args.hold_seconds)
    print(f"final_rss_mb={rss_mb():.0f}", flush=True)
    print("done.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
