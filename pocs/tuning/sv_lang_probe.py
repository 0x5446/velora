#!/usr/bin/env python3
"""Does SenseVoice's English suffer from auto language detection vs explicit en?

Compares language="auto" vs "en" vs "zh" on English + code-switch clips, and
reports the language tag SenseVoice itself emits (<|en|>/<|zh|>...) so we can
see whether auto is misrouting.
"""
import json
import re
from pathlib import Path

import numpy as np
import sherpa_onnx
import soundfile as sf

MODEL_DIR = Path("/tmp/velora-eval/models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17")


def norm(t):
    return re.sub(r"[\s,\.\!\?，。！？、；;:：\"'“”‘’\-—…·()（）\[\]<>|]+", "", t.lower())


def edist(a, b):
    if len(a) < len(b): a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def load(path):
    d, sr = sf.read(path, dtype="float32")
    if d.ndim > 1: d = d.mean(axis=1)
    if sr != 16000:
        idx = np.linspace(0, len(d) - 1, int(len(d) * 16000 / sr)).astype(int)
        d, sr = d[idx], 16000
    return d, sr


def make(lang):
    # from_sense_voice with an explicit language forces the decode language tag.
    return sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=str(MODEL_DIR / "model.onnx"),
        tokens=str(MODEL_DIR / "tokens.txt"),
        num_threads=4, use_itn=True, language=lang,
    )


def transcribe(rec, path):
    d, sr = load(path)
    s = rec.create_stream()
    s.accept_waveform(sr, d)
    rec.decode_stream(s)
    return s.result.text


manifest = json.loads(Path("/tmp/velora-eval/real_manifest.json").read_text())["clips"]
# English clips + code-switch clips (where auto is most likely to misroute).
targets = [c for c in manifest if c["corpus"] in ("librispeech", "ascend")][:24]

recs = {lang: make(lang) for lang in ["auto", "en"]}
# warm
for r in recs.values():
    transcribe(r, targets[0]["file"])

rows = []
for c in targets:
    row = {"id": c["id"], "corpus": c["corpus"], "expected": c["expected"][:50]}
    for lang, rec in recs.items():
        txt = transcribe(rec, c["file"])
        exp = norm(c["expected"]); got = norm(txt)
        row[f"cer_{lang}"] = round(edist(exp, got) / max(1, len(exp)), 3)
        row[f"txt_{lang}"] = txt[:60]
    rows.append(row)
    print(f"{c['id']:26s} {c['corpus']:11s} auto={row['cer_auto']:.2f} en={row['cer_en']:.2f}  | {row['txt_auto'][:45]}", flush=True)

json.dump(rows, open("/tmp/velora-eval/sv-lang-probe.json", "w"), ensure_ascii=False, indent=1)
for corpus in ("librispeech", "ascend"):
    rs = [r for r in rows if r["corpus"] == corpus]
    if rs:
        a = sum(r["cer_auto"] for r in rs) / len(rs)
        e = sum(r["cer_en"] for r in rs) / len(rs)
        print(f"== {corpus}: auto meanCER={a:.3f}  en meanCER={e:.3f}  (n={len(rs)})")
