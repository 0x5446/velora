#!/usr/bin/env python3
"""Real-mic gate experiment: does greedy hold up vs beam on real speech?

Combos mirror production exactly (audio-ctx = ceil(sec)*50+64, floor 512).
"""
import json
import math
import re
import subprocess
import sys
import time
from pathlib import Path

WHISPER = "/opt/homebrew/bin/whisper-cli"
EVAL = Path("/tmp/velora-eval")
MODELS = {
    "base": "/Users/alpha/workspace/velora/Models/whisper.cpp/ggml-base.bin",
    "large": "/Users/alpha/workspace/velora/Models/whisper.cpp/ggml-large-v3-turbo-q5_0.bin",
}

COMBOS = [
    {"id": "greedy-noac", "args": ["-bs", "1", "-bo", "1", "-sns"]},
    {"id": "greedy-ac768", "args": ["-bs", "1", "-bo", "1", "-sns", "-ac", "AUTO768"]},
    {"id": "greedy-ac1024", "args": ["-bs", "1", "-bo", "1", "-sns", "-ac", "AUTO1024"]},
]


def normalize(text):
    text = text.lower()
    return re.sub(r"[\s,\.\!\?，。！？、；;:：\"'“”‘’\-—…·()（）\[\]]+", "", text)


def edit_distance(a, b):
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def resolve_args(args, duration):
    out = []
    i = 0
    while i < len(args):
        if args[i] == "-ac" and args[i + 1].startswith("AUTO"):
            floor = int(args[i + 1][4:] or 512)
            out += ["-ac", str(min(1500, max(floor, math.ceil(duration) * 50 + 64)))]
            i += 2
        else:
            out.append(args[i])
            i += 1
    return out


def main():
    model_key = sys.argv[1]
    manifest = json.loads((EVAL / "real_manifest.json").read_text())["clips"]
    model = MODELS[model_key]
    # warm
    subprocess.run([WHISPER, "-m", model, "-l", "zh", "-nt", "-np", "-otxt", "-of",
                    "/tmp/velora-eval/warm", manifest[0]["file"]], capture_output=True, timeout=300)
    results = []
    for combo in COMBOS:
        for clip in manifest:
            out_base = f"/tmp/velora-eval/r-{combo['id']}-{clip['id']}"
            args = [WHISPER, "-m", model, "-l", clip["lang"], "-otxt", "-of", out_base,
                    "-nt", "-np"] + resolve_args(combo["args"], clip["duration"]) + [clip["file"]]
            t0 = time.monotonic()
            subprocess.run(args, capture_output=True, timeout=300)
            wall = int((time.monotonic() - t0) * 1000)
            try:
                text = Path(out_base + ".txt").read_text().strip()
                Path(out_base + ".txt").unlink()
            except FileNotFoundError:
                text = ""
            exp, got = normalize(clip["expected"]), normalize(text)
            cer = edit_distance(exp, got) / max(1, len(exp))
            results.append({"model": model_key, "combo": combo["id"], "clip": clip["id"],
                            "corpus": clip["corpus"], "dur": clip["duration"],
                            "wall_ms": wall, "cer": round(cer, 4), "text": text})
            print(f"{model_key} {combo['id']:15s} {clip['id']:28s} {wall:5d}ms cer={cer:.3f}", flush=True)
    (EVAL / f"real-decomp-{model_key}.json").write_text(json.dumps(results, ensure_ascii=False, indent=1))
    print("saved", EVAL / f"real-decomp-{model_key}.json")


if __name__ == "__main__":
    main()
