#!/usr/bin/env python3
"""Build a polish-LoRA dataset from Velora's local corrections journal.

Reads corrections.jsonl, joins `insertion` triples with `post_insert_edit`
spans on session_id, applies the cleaning rules from the learning-pipeline
design (docs/LEARNING_PIPELINE.md §D2), and writes mlx-lm chat-format JSONL:

  {"messages": [{"role": "system", ...}, {"role": "user", "content":
                "app_format_profile=...\\n输入：<asr>"}, {"role": "assistant",
                "content": "{\\\"polished\\\": ...}"}]}

The system prompt is loaded from the production prompt export. This is
intentional: training on a shorter prompt or raw assistant text creates a
model whose contract differs from the JSON-only runtime contract.

Cleaning rules:
  - char edit ratio (user_final vs polished) > 0.25 → whole-rewrite, dropped
  - length ratio outside [0.5, 2.0] → dropped
  - near-duplicate (normalized) pairs → deduped
  - ~10% zero-edit pairs kept as regularization so the model does not learn
    that it must always change something

Usage:
  VELORA_EXPORT_PROMPTS=1 swift test --filter exportPromptCandidates
  python3 prepare_polish_dataset.py [--journal PATH] [--out-dir PATH] [--valid-ratio 0.1]
"""
import argparse
import hashlib
import json
import random
import sys
from pathlib import Path

DEFAULT_PROMPT_EXPORT = Path("/tmp/velora-eval/input_system.txt")


def app_format_profile(bundle: str) -> str:
    """Keep in sync with OllamaTextIntelligenceEngine.appFormatProfile."""
    value = (bundle or "").lower()
    if any(key in value for key in ("terminal", "iterm", "warp", "cursor", "vscode", "xcode", "zed", "code")):
        return "developer: preserve code identifiers, paths, flags, acronyms, and Markdown; use lists only for explicit enumerations"
    if any(key in value for key in ("slack", "lark", "feishu", "teams", "discord")):
        return "work_chat: concise paragraphs with light punctuation; avoid formal email framing"
    if any(key in value for key in ("messages", "imessage", "whatsapp", "telegram", "wechat")):
        return "personal_chat: short natural paragraphs with light punctuation"
    if any(key in value for key in ("mail", "outlook", "superhuman", "gmail")):
        return "email: complete punctuation and readable paragraphs; do not invent greetings or sign-offs"
    if any(key in value for key in ("notion", "obsidian", "pages", "word", "docs")):
        return "document: complete punctuation, topic paragraphs, and lists for explicit enumerations"
    return "other: neutral punctuation; preserve wording and use structure only when clearly signaled"


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
    parser.add_argument("--system-prompt-file", default=str(DEFAULT_PROMPT_EXPORT))
    args = parser.parse_args()

    journal = Path(args.journal)
    if not journal.exists():
        print(f"journal not found: {journal}", file=sys.stderr)
        return 1

    prompt_file = Path(args.system_prompt_file)
    if not prompt_file.exists():
        print(
            f"production prompt export not found: {prompt_file}\n"
            "run: cd Velora && VELORA_EXPORT_PROMPTS=1 swift test --filter exportPromptCandidates",
            file=sys.stderr,
        )
        return 1
    system_prompt = prompt_file.read_text(encoding="utf-8").strip()
    if not system_prompt:
        print(f"production prompt export is empty: {prompt_file}", file=sys.stderr)
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
                {"role": "system", "content": system_prompt},
                {
                    "role": "user",
                    "content": f"app_format_profile={app_format_profile(event.get('app_bundle', ''))}\n输入：{asr}",
                },
                {
                    "role": "assistant",
                    "content": json.dumps({"polished": target}, ensure_ascii=False, separators=(",", ":")),
                },
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
