#!/usr/bin/env python3
"""Resident SenseVoice ASR sidecar for Velora.

Protocol (line-delimited JSON over stdin/stdout):
  in : {"id": "<req>", "audio": "/abs/path.wav"[, "language": "auto|zh|en|ja|ko|yue"]}
  out: {"id": "<req>", "ok": true, "text": "...", "language": "zh", "ms": 42}
       {"id": "<req>", "ok": false, "error": "..."}

The model is loaded once and stays resident — that's the whole point versus
spawning whisper-cli per utterance. First line emitted is a readiness banner:
  {"ready": true, "engine": "sensevoice", "model": "<name>"}

Kept dependency-light (sherpa_onnx + soundfile + numpy) and stdlib only
otherwise, so the app can point it at a bundled venv.
"""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
import sherpa_onnx
import soundfile as sf


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def load_audio(path):
    data, sr = sf.read(path, dtype="float32")
    if data.ndim > 1:
        data = data.mean(axis=1)
    if sr != 16000:
        idx = np.linspace(0, len(data) - 1, int(len(data) * 16000 / sr)).astype(int)
        data, sr = data[idx], 16000
    return data, sr


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--tokens", required=True)
    parser.add_argument("--threads", type=int, default=4)
    # HomophoneReplacer assets (optional): learned hotwords compiled into an
    # in-decoder pinyin-replacement FST (see scripts/build_hotword_fst.py).
    # This is the official hotword channel for SenseVoice — sherpa-onnx
    # contextual biasing only exists for transducer models.
    parser.add_argument("--hr-dict-dir", default="")
    parser.add_argument("--hr-lexicon", default="")
    parser.add_argument("--hr-rule-fsts", default="")
    args = parser.parse_args()

    if not Path(args.model).exists() or not Path(args.tokens).exists():
        emit({"ready": False, "error": f"model_or_tokens_missing"})
        return 1

    hr_enabled = bool(
        args.hr_dict_dir and args.hr_lexicon and args.hr_rule_fsts
        and Path(args.hr_dict_dir).is_dir()
        and Path(args.hr_lexicon).exists()
        and Path(args.hr_rule_fsts).exists()
    )

    def build(with_hr):
        kwargs = dict(
            model=args.model,
            tokens=args.tokens,
            num_threads=args.threads,
            use_itn=True,
            language="auto",
        )
        if with_hr:
            kwargs.update(
                hr_dict_dir=args.hr_dict_dir,
                hr_lexicon=args.hr_lexicon,
                hr_rule_fsts=args.hr_rule_fsts,
            )
        return sherpa_onnx.OfflineRecognizer.from_sense_voice(**kwargs)

    try:
        try:
            recognizer = build(hr_enabled)
        except TypeError:
            # Older sherpa-onnx without hr_* kwargs: degrade to plain decode
            # rather than dying — HR is an enhancement, not a dependency.
            hr_enabled = False
            recognizer = build(False)
    except Exception as exc:  # noqa: BLE001 — surface any load failure to the app
        emit({"ready": False, "error": f"load_failed:{exc}"})
        return 1

    emit({
        "ready": True,
        "engine": "sensevoice",
        "model": Path(args.model).name,
        "hr": hr_enabled,
    })

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            emit({"ok": False, "error": f"bad_json:{exc}"})
            continue
        req_id = req.get("id", "")
        audio_path = req.get("audio", "")
        try:
            t0 = time.monotonic()
            data, sr = load_audio(audio_path)
            stream = recognizer.create_stream()
            stream.accept_waveform(sr, data)
            recognizer.decode_stream(stream)
            result = stream.result
            emit({
                "id": req_id,
                "ok": True,
                "text": result.text,
                "language": getattr(result, "lang", "") or "",
                "ms": int((time.monotonic() - t0) * 1000),
            })
        except Exception as exc:  # noqa: BLE001
            emit({"id": req_id, "ok": False, "error": str(exc)})

    return 0


if __name__ == "__main__":
    sys.exit(main())
