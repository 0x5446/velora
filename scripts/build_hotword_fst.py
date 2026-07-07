#!/usr/bin/env python3
"""Compile learned hotwords into sherpa-onnx HomophoneReplacer assets.

SenseVoice (CTC) has no contextual-biasing/hotword support in sherpa-onnx —
the official channel is the HomophoneReplacer (v1.11.4+): decoded Chinese text
is converted to pinyin (jieba dict + lexicon) and rewritten by replace.fst.
This script turns Velora's ACTIVE learned pairs (memory.sqlite, promoted &&
enabled && pure-Han) into that FST.

Inputs:
  --memory     path to memory.sqlite   (default: app-support Velora/memory.sqlite)
  --hr-files   dir containing the universal `dict/` folder and `lexicon.txt`
               from https://github.com/k2-fsa/sherpa-onnx/releases/tag/hr-files
  --out        output dir              (default: app-support Velora/hr)

Requires: pip install pypinyin pynini  (pynini via conda on some setups)

After a rebuild, restart Velora (the sidecar loads HR assets at startup).
"""
import argparse
import shutil
import sqlite3
import sys
from pathlib import Path


def app_support() -> Path:
    return Path.home() / "Library/Application Support/Velora"


def han_only(text: str) -> bool:
    return bool(text) and all("一" <= ch <= "鿿" for ch in text)


def load_pairs(memory_path: Path):
    conn = sqlite3.connect(memory_path)
    rows = conn.execute(
        """
        SELECT term, replacement, edit_count FROM terms
        WHERE disabled = 0 AND promoted = 1 AND language = 'zh'
        ORDER BY edit_count DESC
        """
    ).fetchall()
    conn.close()
    return [(t, r, c) for t, r, c in rows if han_only(t) and han_only(r) and t != r]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--memory", default=str(app_support() / "memory.sqlite"))
    parser.add_argument("--hr-files", default=str(app_support() / "hr-files"))
    parser.add_argument("--out", default=str(app_support() / "hr"))
    args = parser.parse_args()

    memory_path = Path(args.memory)
    hr_files = Path(args.hr_files)
    out_dir = Path(args.out)

    if not memory_path.exists():
        print(f"memory store not found: {memory_path}", file=sys.stderr)
        return 1

    # Cleanup path runs FIRST and needs only the memory store: if there are no
    # active terms left (user disabled/deleted them all), remove any stale
    # assets so the sidecar stops applying old replacements — even when the
    # hr-files download is no longer around. resolvedHRDirectory() then returns
    # nil and HR is skipped on restart.
    pairs = load_pairs(memory_path)
    if not pairs:
        removed = False
        for name in ("replace.fst", "lexicon.txt"):
            target = out_dir / name
            if target.exists():
                target.unlink()
                removed = True
        if (out_dir / "dict").exists():
            shutil.rmtree(out_dir / "dict")
            removed = True
        if removed:
            print(f"no active learned zh pairs; cleared stale HR assets in {out_dir}")
            print("restart Velora so the ASR sidecar drops the old dictionary")
        else:
            print("no active learned zh pairs to compile; nothing to do")
        return 0

    # Build path needs the universal hr-files assets and the compilers.
    if not (hr_files / "dict").is_dir() or not (hr_files / "lexicon.txt").exists():
        print(
            "hr-files assets missing. Download `dict/` and `lexicon.txt` from\n"
            "  https://github.com/k2-fsa/sherpa-onnx/releases/tag/hr-files\n"
            f"and place them under {hr_files}",
            file=sys.stderr,
        )
        return 1

    try:
        from pypinyin import Style, lazy_pinyin
    except ImportError:
        print("pip install pypinyin", file=sys.stderr)
        return 1
    try:
        import pynini
        from pynini import cdrewrite
        from pynini.lib import utf8
    except ImportError:
        print("pip install pynini  (or: conda install -c conda-forge pynini)", file=sys.stderr)
        return 1

    def toned(text: str) -> str:
        # HR rules match tone-numbered pinyin without separators: 超时 → chao1shi2
        return "".join(lazy_pinyin(text, style=Style.TONE3, neutral_tone_with_five=True))

    # One rule per pinyin key. Conflicting outputs for the same sound keep the
    # highest-edit-count pair (list is pre-sorted); HR replaces unconditionally,
    # so ambiguity must be resolved here, not at decode time.
    rules = {}
    for term, replacement, _count in pairs:
        key = toned(term)
        if key and key not in rules:
            rules[key] = replacement

    sigma = utf8.VALID_UTF8_CHAR.star
    fst = None
    for key, replacement in rules.items():
        rule = pynini.cross(key, replacement)
        fst = rule if fst is None else fst | rule
    fst = cdrewrite(fst.optimize(), "", "", sigma)

    out_dir.mkdir(parents=True, exist_ok=True)
    fst.write(str(out_dir / "replace.fst"))
    shutil.copy2(hr_files / "lexicon.txt", out_dir / "lexicon.txt")
    if (out_dir / "dict").exists():
        shutil.rmtree(out_dir / "dict")
    shutil.copytree(hr_files / "dict", out_dir / "dict")

    print(f"compiled {len(rules)} rules -> {out_dir}/replace.fst")
    print("restart Velora to load the new dictionary into the ASR sidecar")
    return 0


if __name__ == "__main__":
    sys.exit(main())
