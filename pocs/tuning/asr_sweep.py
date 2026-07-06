#!/usr/bin/env python3
"""Serial whisper-cli parameter sweep: CER / entity hits / latency per combo."""
import json
import re
import subprocess
import sys
import time
import wave
from pathlib import Path

WHISPER = "/opt/homebrew/bin/whisper-cli"
EVAL = Path("/tmp/velora-eval")
MODELS = {
    "base": "/Users/alpha/workspace/velora/Models/whisper.cpp/ggml-base.bin",
    "large": "/Users/alpha/workspace/velora/Models/whisper.cpp/ggml-large-v3-turbo-q5_0.bin",
}
HOTWORD_PROMPT = "prompt injection, Velora, agenda, Alex, release notes"

COMBOS = [
    {"id": "baseline", "args": []},
    {"id": "sns-only", "args": ["-sns"]},
    {"id": "ac-auto-only", "args": ["-ac", "AUTO"]},
    {"id": "greedy-only", "args": ["-bs", "1", "-bo", "1"]},
    {"id": "nf-only", "args": ["-nf"]},
    {"id": "beam-fast", "args": ["-ac", "AUTO", "-nf", "-sns"]},
    {"id": "greedy-fast", "args": ["-ac", "AUTO", "-bs", "1", "-bo", "1", "-nf", "-sns"]},
    {"id": "beam2-mid", "args": ["-ac", "AUTO", "-bs", "2", "-bo", "2", "-nf", "-sns"]},
    {"id": "greedy-fast-t8", "args": ["-ac", "AUTO", "-bs", "1", "-bo", "1", "-nf", "-sns", "-t", "8"]},
    {"id": "greedy-fast-mc0", "args": ["-ac", "AUTO", "-bs", "1", "-bo", "1", "-nf", "-sns", "-mc", "0"]},
    {"id": "greedy-safe", "args": ["-ac", "AUTO", "-bs", "1", "-bo", "1", "-sns"]},
]


def wav_duration(path):
    with wave.open(path, "rb") as w:
        return w.getnframes() / w.getframerate()


def normalize(text):
    text = text.lower()
    text = re.sub(r"[\s,\.\!\?，。！？、；;:：\"'“”‘’\-—…·()（）\[\]]+", "", text)
    return text


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
    it = iter(range(len(args)))
    i = 0
    while i < len(args):
        if args[i] == "-ac" and i + 1 < len(args) and args[i + 1] == "AUTO":
            ac = min(1500, max(256, int(duration * 50) + 64))
            out += ["-ac", str(ac)]
            i += 2
        else:
            out.append(args[i])
            i += 1
    return out


def run_one(model_path, clip, combo, use_prompt):
    out_base = f"/tmp/velora-eval/out-{combo['id']}-{clip['id']}"
    args = [WHISPER, "-m", model_path, "-l", clip["lang"], "-otxt", "-of", out_base, "-nt", "-np"]
    args += resolve_args(combo["args"], wav_duration(clip["file"])) if clip["file"].endswith(".wav") else combo["args"]
    if use_prompt and clip.get("entities"):
        args += ["--prompt", HOTWORD_PROMPT]
    args.append(clip["file"])
    t0 = time.monotonic()
    proc = subprocess.run(args, capture_output=True, text=True, timeout=120)
    wall_ms = int((time.monotonic() - t0) * 1000)
    try:
        text = Path(out_base + ".txt").read_text().strip()
    except FileNotFoundError:
        text = ""
    expected_n = normalize(clip["expected"])
    got_n = normalize(text)
    cer = edit_distance(expected_n, got_n) / max(1, len(expected_n))
    hits = sum(1 for e in clip.get("entities", []) if normalize(e) in got_n)
    return {
        "combo": combo["id"], "clip": clip["id"], "wall_ms": wall_ms,
        "cer": round(cer, 4), "entity_hits": hits, "entity_total": len(clip.get("entities", [])),
        "exit": proc.returncode, "text": text,
    }


def main():
    manifest = json.loads((EVAL / "manifest.json").read_text())
    clips = manifest["clips"]
    for c in clips:
        if "file" not in c:
            c["file"] = str(EVAL / "clips" / (c["id"] + ".wav"))
    model_key = sys.argv[1] if len(sys.argv) > 1 else "base"
    model_path = MODELS[model_key]
    # Warm the model file cache once so combo #1 isn't penalized.
    subprocess.run([WHISPER, "-m", model_path, "-l", "en", "-nt", "-np", "-otxt",
                    "-of", "/tmp/velora-eval/warmup", clips[0]["file"]], capture_output=True, timeout=180)
    results = []
    for combo in COMBOS:
        for clip in clips:
            r = run_one(model_path, clip, combo, use_prompt=True)
            r["model"] = model_key
            results.append(r)
            print(f"{model_key} {combo['id']:16s} {clip['id']:14s} {r['wall_ms']:5d}ms cer={r['cer']:.3f} ent={r['entity_hits']}/{r['entity_total']}", flush=True)
    out = EVAL / f"sweep-{model_key}.json"
    out.write_text(json.dumps(results, ensure_ascii=False, indent=1))
    print("saved", out)


if __name__ == "__main__":
    main()
