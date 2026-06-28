#!/usr/bin/env python3
"""
POC: bilingual translation-mode output contract.

This intentionally uses a deterministic in-file translator. The purpose is not
translation quality. The purpose is to prove the product contract we need from
any local translator/LLM backend:

1. preserve the recognized source text
2. produce a target-language text
3. render both texts for review when the mode requires it
4. keep insertion behavior configurable
5. keep terminology rules visible and testable
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
import json
from pathlib import Path
from typing import Literal


InsertPolicy = Literal["bilingual", "target_only", "review_card"]


@dataclass(frozen=True)
class TranslationMode:
    source_language: str
    target_language: str
    insert_policy: InsertPolicy
    source_label: str = "原文"
    target_label: str = "译文"
    separator: str = "\n"


@dataclass(frozen=True)
class TranslationResult:
    mode: TranslationMode
    source_text: str
    corrected_source_text: str
    target_text: str
    display_text: str
    insert_text: str
    glossary_hits: list[str]
    warnings: list[str]


GLOSSARY = {
    "prompt injection": "提示注入",
    "agenda": "议程",
    "Typeless": "Typeless",
    "Velora": "Velora",
    "hotword": "热词",
    "context": "语境",
}


FIXTURES = {
    "en->zh": {
        "Please help me confirm the agenda before tomorrow morning.": "请帮我在明天上午之前确认议程。",
        "The biggest risk is prompt injection in the local context layer.": "最大的风险是本地语境层里的提示注入。",
        "Velora should keep the source text on screen for translation review.": "Velora 应该把原文保留在屏幕上，方便校验译文。",
    },
    "zh->en": {
        "明天上午十点我和 Alex 开会，帮我确认一下 agenda。": "I have a meeting with Alex tomorrow at 10 a.m. Please help me confirm the agenda.",
        "翻译模式要同时上屏原文和译文。": "Translation mode should insert both the source text and the translated text.",
        "热词和长期语境要参与纠错。": "Hotwords and long-term context should participate in correction.",
    },
}


def normalize_source(text: str) -> str:
    """Mechanical cleanup before translation. No semantic rewrite here."""
    return " ".join(text.strip().split())


def translate_stub(text: str, source_language: str, target_language: str) -> tuple[str, list[str], list[str]]:
    key = f"{source_language}->{target_language}"
    glossary_hits = [term for term in GLOSSARY if term.lower() in text.lower()]
    warnings: list[str] = []
    target = FIXTURES.get(key, {}).get(text)
    if not target:
        warnings.append("translation_stub_missing_fixture")
        target = f"[{target_language}] {text}"
    return target, glossary_hits, warnings


def render_result(mode: TranslationMode, source_text: str) -> TranslationResult:
    corrected_source = normalize_source(source_text)
    target, glossary_hits, warnings = translate_stub(
        corrected_source,
        mode.source_language,
        mode.target_language,
    )

    bilingual_block = (
        f"{mode.source_label}:\n{corrected_source}"
        f"{mode.separator}{mode.target_label}:\n{target}"
    )

    if mode.insert_policy == "bilingual":
        insert_text = bilingual_block
    elif mode.insert_policy == "target_only":
        insert_text = target
    else:
        insert_text = (
            f"> {corrected_source}\n\n"
            f"{target}"
        )

    return TranslationResult(
        mode=mode,
        source_text=source_text,
        corrected_source_text=corrected_source,
        target_text=target,
        display_text=bilingual_block,
        insert_text=insert_text,
        glossary_hits=glossary_hits,
        warnings=warnings,
    )


def main() -> None:
    modes = [
        TranslationMode("zh", "en", "bilingual"),
        TranslationMode("en", "zh", "bilingual"),
        TranslationMode("zh", "en", "target_only"),
        TranslationMode("zh", "en", "review_card"),
    ]
    samples = [
        "明天上午十点我和 Alex 开会，帮我确认一下 agenda。",
        "翻译模式要同时上屏原文和译文。",
        "The biggest risk is prompt injection in the local context layer.",
        "Velora should keep the source text on screen for translation review.",
    ]

    results = []
    for mode in modes:
        for sample in samples:
            if sample in FIXTURES.get(f"{mode.source_language}->{mode.target_language}", {}):
                results.append(render_result(mode, sample))

    out_dir = Path(__file__).resolve().parent / "out"
    out_dir.mkdir(exist_ok=True)
    out_path = out_dir / "translation_mode_poc.json"
    out_path.write_text(
        json.dumps([asdict(result) for result in results], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print(f"Wrote {out_path}")
    for result in results:
        print("\n---")
        print(f"{result.mode.source_language}->{result.mode.target_language} / {result.mode.insert_policy}")
        print(result.insert_text)
        if result.glossary_hits:
            print(f"glossary_hits={', '.join(result.glossary_hits)}")


if __name__ == "__main__":
    main()
