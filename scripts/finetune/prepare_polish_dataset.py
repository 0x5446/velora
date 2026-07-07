#!/usr/bin/env python3
"""Build a polish-LoRA dataset from Velora's local corrections journal.

Reads corrections.jsonl, joins `insertion` triples with `post_insert_edit`
spans on session_id, applies the cleaning rules from the learning-pipeline
design (docs/LEARNING_PIPELINE.md §D2), and writes mlx-lm chat-format JSONL:

  {"messages": [{"role": "system", ...}, {"role": "user", "content": <asr>},
                {"role": "assistant", "content": <user_final|polished>}]}

Cleaning rules:
  - char edit ratio (user_final vs polished) > 0.25 → whole-rewrite, dropped
  - length ratio outside [0.5, 2.0] → dropped
  - near-duplicate (normalized) pairs → deduped
  - ~10% zero-edit pairs kept as regularization so the model does not learn
    that it must always change something

Usage:
  python3 prepare_polish_dataset.py [--journal PATH] [--out-dir PATH] [--valid-ratio 0.1]
"""
import argparse
import hashlib
import json
import random
import sys
from pathlib import Path

SYSTEM_PROMPT = "你是听写文本整理引擎：修正同音错字、标点、断句与排版，保持原语言，不添加原文没有的信息。"


def edit_ratio(a: str, b: str) -> float:
    if not a and not b:
        return 0.0
    # Levenshtein / max-len, O(len^2) fine for utterance-sized text.
    m, n = len(a), len(b)
    if m == 0 or n == 0:
        return 1.0
    prev = list(range(n + 1))
    for i in range(1, m + 1):
        cur = [i] + [0] * n
        for j in range(1, n + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] != b[j - 1]))
        prev = cur
    return prev[n] / max(m, n)


def normalized(text: str) -> str:
    return "".join(ch for ch in text.lower() if not ch.isspace())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    default_journal = Path.home() / "Library/Application Support/Velora/corrections.jsonl"
    parser.add_argument("--journal", default=str(default_journal))
    parser.add_argument("--out-dir", default="data/polish")
    parser.add_argument("--valid-ratio", type=float, default=0.1)
    parser.add_argument("--identity-ratio", type=float, default=0.1)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()

    journal = Path(args.journal)
    if not journal.exists():
        print(f"journal not found: {journal}", file=sys.stderr)
        return 1

    insertions = {}
    finals = {}
    for line in journal.read_text(encoding="utf-8").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = event.get("kind")
        session = event.get("session_id")
        if not session:
            continue
        if kind == "insertion" and event.get("mode") == "input":
            insertions[session] = event
        elif kind == "post_insert_edit" and not event.get("is_rewrite", False):
            # Later events win: the lazy next-session diff supersedes the
            # live-window settle for the same session.
            finals[session] = event.get("user_final_span", "")

    pairs = []
    identity_pool = []
    seen = set()
    for session, event in insertions.items():
        asr = (event.get("asr_text") or "").strip()
        polished = (event.get("polished_text") or "").strip() or (event.get("final_text") or "").strip()
        if not asr or not polished:
            continue
        user_final = (finals.get(session) or "").strip()
        target = user_final or polished

        ratio = edit_ratio(target, polished) if user_final else 0.0
        if ratio > 0.25:
            continue  # whole rewrite — no supervision signal
        length_ratio = len(target) / max(1, len(asr))
        if not 0.5 <= length_ratio <= 2.0:
            continue

        key = hashlib.sha1((normalized(asr) + "→" + normalized(target)).encode()).hexdigest()
        if key in seen:
            continue
        seen.add(key)

        row = {
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": asr},
                {"role": "assistant", "content": target},
            ]
        }
        if user_final and normalized(user_final) != normalized(polished):
            pairs.append(row)  # user-corrected: the valuable examples
        else:
            identity_pool.append(row)  # model already satisfied the user

    rng = random.Random(args.seed)
    rng.shuffle(identity_pool)
    keep_identity = int(len(pairs) * args.identity_ratio / max(1e-9, 1 - args.identity_ratio)) + 1
    dataset = pairs + identity_pool[:keep_identity]
    rng.shuffle(dataset)

    # Require at least one genuinely corrected pair — an all-identity or
    # single-row set would write an empty train.jsonl that run_qlora.sh then
    # feeds to mlx_lm.lora, "succeeding" with nothing to learn.
    if not pairs or len(dataset) < 2:
        print(f"not enough usable pairs yet (corrected={len(pairs)}, total={len(dataset)}) — keep dictating")
        return 0

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    # Never let the validation split swallow every training row.
    split = min(len(dataset) - 1, max(1, int(len(dataset) * args.valid_ratio)))
    valid, train = dataset[:split], dataset[split:]
    if not train:
        print("not enough usable pairs after split — keep dictating")
        return 0
    for name, rows in (("train", train), ("valid", valid)):
        with (out_dir / f"{name}.jsonl").open("w", encoding="utf-8") as fh:
            for row in rows:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"train={len(train)} valid={len(valid)} (corrected={len(pairs)}, identity={len(dataset) - len(pairs)})")
    print(f"wrote {out_dir}/train.jsonl and valid.jsonl")
    if len(train) < 100:
        print("note: <100 pairs — below the LoRA useful threshold, keep collecting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
