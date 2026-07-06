#!/usr/bin/env python3
"""SenseVoice (sherpa-onnx) vs whisper on the 60-clip real corpus.

Model stays resident in-process (the whole point vs whisper-cli), so we time
transcribe() only, not process spawn. CER computed identically to sweep_real.
"""
import json
import re
import time
from pathlib import Path

import numpy as np
import sherpa_onnx
import soundfile as sf

EVAL = Path("/tmp/velora-eval")
MODEL_DIR = EVAL / "models" / "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"


def normalize(text):
    text = text.lower()
    return re.sub(r"[\s,\.\!\?，。！？、；;:：\"'“”‘’\-—…·()（）\[\]<>|]+", "", text)


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


def load_audio(path):
    data, sr = sf.read(path, dtype="float32")
    if data.ndim > 1:
        data = data.mean(axis=1)
    if sr != 16000:
        idx = np.linspace(0, len(data) - 1, int(len(data) * 16000 / sr)).astype(int)
        data, sr = data[idx], 16000
    return data, sr


def main():
    recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=str(MODEL_DIR / "model.onnx"),
        tokens=str(MODEL_DIR / "tokens.txt"),
        num_threads=4,
        use_itn=True,
        language="auto",
    )
    clips = json.loads((EVAL / "real_manifest.json").read_text())["clips"]

    # Warm (model + graph) so the first clip isn't penalized.
    warm = recognizer.create_stream()
    wd, wsr = load_audio(clips[0]["file"])
    warm.accept_waveform(wsr, wd)
    recognizer.decode_stream(warm)

    results = []
    for clip in clips:
        data, sr = load_audio(clip["file"])
        t0 = time.monotonic()
        stream = recognizer.create_stream()
        stream.accept_waveform(sr, data)
        recognizer.decode_stream(stream)
        text = stream.result.text
        ms = int((time.monotonic() - t0) * 1000)
        exp, got = normalize(clip["expected"]), normalize(text)
        cer = edit_distance(exp, got) / max(1, len(exp))
        results.append({"clip": clip["id"], "corpus": clip["corpus"], "dur": clip["duration"],
                        "wall_ms": ms, "cer": round(cer, 4), "text": text})
        print(f"{clip['id']:28s} {ms:5d}ms cer={cer:.3f}", flush=True)

    (EVAL / "sensevoice-results.json").write_text(json.dumps(results, ensure_ascii=False, indent=1))
    from statistics import median
    for corpus in ["aishell1", "ascend", "librispeech"]:
        rs = [r for r in results if r["corpus"] == corpus]
        if rs:
            cers = [r["cer"] for r in rs]
            walls = sorted(r["wall_ms"] for r in rs)
            print(f"== {corpus}: n={len(rs)} p50={int(median(walls))}ms meanCER={sum(cers)/len(cers):.3f}")


if __name__ == "__main__":
    main()
