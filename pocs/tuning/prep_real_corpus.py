#!/usr/bin/env python3
"""Build the real-microphone eval manifest from AISHELL-1 + ASCEND (+ LibriSpeech if present)."""
import json
import random
import re
import wave
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf

CORPUS = Path("/tmp/velora-eval/corpus")
OUT = CORPUS / "clips"
OUT.mkdir(exist_ok=True)
random.seed(20260705)

clips = []

# ---- AISHELL-1 (real-mic Mandarin read speech, Apache 2.0) ----
transcripts = {}
for line in (CORPUS / "aishell_transcript.txt").read_text().splitlines():
    parts = line.split(maxsplit=1)
    if len(parts) == 2:
        transcripts[parts[0]] = parts[1].replace(" ", "")

wavs = sorted(CORPUS.glob("train/S000*/*.wav"))
wavs = [w for w in wavs if w.stem in transcripts]
sampled = random.sample(wavs, 30)
for w in sampled:
    with wave.open(str(w), "rb") as f:
        dur = f.getnframes() / f.getframerate()
    clips.append({
        "id": f"aishell_{w.stem}",
        "file": str(w),
        "lang": "zh",
        "expected": transcripts[w.stem],
        "duration": round(dur, 2),
        "corpus": "aishell1",
    })

# ---- ASCEND (real conversational Mandarin-English code-switching, CC BY-SA) ----
table = pq.read_table(CORPUS / "ascend_test.parquet").to_pylist()
def clean_ascend(t):
    t = re.sub(r"\[[A-Z\-]+\]", "", t)  # [UNK]/[LAUGHTER] etc.
    return t.strip()

mixed = [r for r in table if r["language"] == "mixed" and 2.0 <= r["duration"] <= 15.0
         and clean_ascend(r["transcription"])]
sampled_mixed = random.sample(mixed, 30)
for r in sampled_mixed:
    audio = r["audio"]
    raw = audio["bytes"] if isinstance(audio, dict) else audio
    path = OUT / f"ascend_{r['id']}.wav"
    import io
    data, sr = sf.read(io.BytesIO(raw))
    if data.ndim > 1:
        data = data.mean(axis=1)
    if sr != 16000:
        idx = np.linspace(0, len(data) - 1, int(len(data) * 16000 / sr)).astype(int)
        data = data[idx]
        sr = 16000
    sf.write(path, data, sr, subtype="PCM_16")
    clips.append({
        "id": f"ascend_{r['id']}",
        "file": str(path),
        "lang": "zh",
        "expected": clean_ascend(r["transcription"]),
        "duration": round(r["duration"], 2),
        "corpus": "ascend",
    })

# ---- LibriSpeech test-clean (real-mic English read speech, CC BY 4.0) ----
ls_parquet = CORPUS / "librispeech_test_clean.parquet"
if ls_parquet.exists():
    import io
    rows = pq.read_table(ls_parquet).to_pylist()
    usable = [r for r in rows if 2.0 <= len(r["audio"]["bytes"]) / 32000 <= 15.0] if rows and "duration" not in rows[0] else rows
    for r in random.sample(rows, 20):
        audio = r["audio"]
        raw = audio["bytes"] if isinstance(audio, dict) else audio
        path = OUT / f"libri_{r['id']}.wav"
        data, sr = sf.read(io.BytesIO(raw))
        if data.ndim > 1:
            data = data.mean(axis=1)
        if sr != 16000:
            idx = np.linspace(0, len(data) - 1, int(len(data) * 16000 / sr)).astype(int)
            data, sr = data[idx], 16000
        sf.write(path, data, sr, subtype="PCM_16")
        clips.append({
            "id": f"libri_{r['id']}",
            "file": str(path),
            "lang": "en",
            "expected": r["text"],
            "duration": round(len(data) / sr, 2),
            "corpus": "librispeech",
        })
else:
    print("(LibriSpeech parquet not present; skipping en clips)")

manifest = {"clips": clips}
(Path("/tmp/velora-eval") / "real_manifest.json").write_text(
    json.dumps(manifest, ensure_ascii=False, indent=1)
)
from collections import Counter
print("clips:", len(clips), Counter(c["corpus"] for c in clips))
print("duration span:", min(c["duration"] for c in clips), "-", max(c["duration"] for c in clips), "s")
