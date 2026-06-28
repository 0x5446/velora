#!/usr/bin/env python3
"""
POC: local context and hotword selection for dictation correction.

This validates a concrete memory contract:

- user dictionary entries are weighted by app, domain, recency, and edit count
- current app/window/selection context changes which terms are injected
- correction uses the selected terms, not the whole private memory
- the result is explainable enough to show in diagnostics
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import sqlite3


NOW = datetime(2026, 6, 27, tzinfo=timezone.utc).timestamp()


@dataclass(frozen=True)
class ContextSnapshot:
    app_bundle: str
    window_title: str
    selected_text: str
    nearby_text: str
    mode: str


@dataclass(frozen=True)
class HotwordCandidate:
    term: str
    replacement: str
    domains: list[str]
    apps: list[str]
    edit_count: int
    last_seen_days: int
    score: float
    reasons: list[str]


SEED_TERMS = [
    {
        "term": "prompt injection",
        "replacement": "prompt injection",
        "domains": "ai,security",
        "apps": "com.tinyspeck.slackmacgap,com.apple.mail,com.microsoft.VSCode",
        "edit_count": 19,
        "last_seen_days": 1,
    },
    {
        "term": "提示注入",
        "replacement": "提示注入",
        "domains": "ai,security,zh",
        "apps": "com.apple.mail,com.tinyspeck.slackmacgap",
        "edit_count": 8,
        "last_seen_days": 4,
    },
    {
        "term": "Velora",
        "replacement": "Velora",
        "domains": "product,dictation",
        "apps": "com.apple.Notes,com.apple.mail",
        "edit_count": 13,
        "last_seen_days": 0,
    },
    {
        "term": "Qwen3-ASR",
        "replacement": "Qwen3-ASR",
        "domains": "asr,model",
        "apps": "com.microsoft.VSCode,com.apple.Terminal",
        "edit_count": 11,
        "last_seen_days": 2,
    },
    {
        "term": "WhisperKit",
        "replacement": "WhisperKit",
        "domains": "asr,apple",
        "apps": "com.microsoft.VSCode,com.apple.mail",
        "edit_count": 7,
        "last_seen_days": 7,
    },
    {
        "term": "agenda",
        "replacement": "agenda",
        "domains": "meeting,work",
        "apps": "com.apple.mail,com.tinyspeck.slackmacgap",
        "edit_count": 22,
        "last_seen_days": 0,
    },
]


CONFUSIONS = {
    "prom injection": "prompt injection",
    "prompt in jackson": "prompt injection",
    "velora": "Velora",
    "qwen three asr": "Qwen3-ASR",
    "whisper kit": "WhisperKit",
    "a gender": "agenda",
}


def setup_db(path: Path) -> sqlite3.Connection:
    if path.exists():
        path.unlink()
    conn = sqlite3.connect(path)
    conn.execute(
        """
        create table memory_terms (
          term text primary key,
          replacement text not null,
          domains text not null,
          apps text not null,
          edit_count integer not null,
          last_seen_days integer not null
        )
        """
    )
    conn.executemany(
        """
        insert into memory_terms(term, replacement, domains, apps, edit_count, last_seen_days)
        values(:term, :replacement, :domains, :apps, :edit_count, :last_seen_days)
        """,
        SEED_TERMS,
    )
    conn.commit()
    return conn


def detect_domains(snapshot: ContextSnapshot) -> set[str]:
    text = " ".join([snapshot.window_title, snapshot.selected_text, snapshot.nearby_text]).lower()
    domains: set[str] = set()
    if any(token in text for token in ["prompt", "injection", "security", "安全", "提示注入"]):
        domains.update(["ai", "security"])
    if any(token in text for token in ["asr", "speech", "whisper", "qwen", "语音"]):
        domains.update(["asr", "model"])
    if any(token in text for token in ["meeting", "agenda", "calendar", "会议"]):
        domains.update(["meeting", "work"])
    if any(token in text for token in ["typeless", "dictation", "输入法"]):
        domains.update(["product", "dictation"])
    return domains


def rank_hotwords(conn: sqlite3.Connection, snapshot: ContextSnapshot, limit: int = 8) -> list[HotwordCandidate]:
    active_domains = detect_domains(snapshot)
    candidates: list[HotwordCandidate] = []
    for row in conn.execute("select term, replacement, domains, apps, edit_count, last_seen_days from memory_terms"):
        term, replacement, domains_raw, apps_raw, edit_count, last_seen_days = row
        domains = domains_raw.split(",")
        apps = apps_raw.split(",")
        reasons: list[str] = []
        score = 0.0

        if snapshot.app_bundle in apps:
            score += 3.0
            reasons.append("app_match")

        domain_hits = active_domains.intersection(domains)
        if domain_hits:
            score += 2.0 * len(domain_hits)
            reasons.append("domain_match:" + ",".join(sorted(domain_hits)))

        if term.lower() in snapshot.nearby_text.lower() or term.lower() in snapshot.selected_text.lower():
            score += 4.0
            reasons.append("nearby_text_match")

        score += min(3.0, math.log1p(edit_count))
        reasons.append(f"edit_count={edit_count}")

        recency_bonus = max(0.0, 2.0 - (last_seen_days / 7.0))
        score += recency_bonus
        reasons.append(f"recency_bonus={recency_bonus:.2f}")

        if snapshot.mode == "translate" and ("zh" in domains or "meeting" in domains):
            score += 0.75
            reasons.append("translation_mode_bonus")

        candidates.append(
            HotwordCandidate(
                term=term,
                replacement=replacement,
                domains=domains,
                apps=apps,
                edit_count=edit_count,
                last_seen_days=last_seen_days,
                score=round(score, 3),
                reasons=reasons,
            )
        )

    return sorted(candidates, key=lambda candidate: candidate.score, reverse=True)[:limit]


def correct_with_hotwords(raw_text: str, candidates: list[HotwordCandidate]) -> tuple[str, list[dict]]:
    corrected = raw_text
    selected_replacements = {candidate.replacement for candidate in candidates}
    edits: list[dict] = []
    for wrong, right in CONFUSIONS.items():
        if right not in selected_replacements:
            continue
        if wrong in corrected.lower():
            before = corrected
            corrected = corrected.replace(wrong, right).replace(wrong.title(), right)
            if corrected != before:
                edits.append({"from": wrong, "to": right, "reason": "selected_hotword"})
    return corrected, edits


def main() -> None:
    out_dir = Path(__file__).resolve().parent / "out"
    out_dir.mkdir(exist_ok=True)
    db_path = out_dir / "context_hotword_poc.sqlite"
    conn = setup_db(db_path)

    snapshot = ContextSnapshot(
        app_bundle="com.apple.mail",
        window_title="Draft: Velora translation mode design",
        selected_text="",
        nearby_text="Need to explain prompt injection risk and bilingual translation review.",
        mode="translate",
    )
    raw_text = "The biggest risk is prom injection in velora when we keep long term context."
    ranked = rank_hotwords(conn, snapshot)
    corrected, edits = correct_with_hotwords(raw_text, ranked)

    report = {
        "snapshot": asdict(snapshot),
        "raw_text": raw_text,
        "selected_hotwords": [asdict(item) for item in ranked],
        "corrected_text": corrected,
        "edits": edits,
        "privacy_note": "Only selected hotwords leave memory and enter the ASR/LLM prompt. Full history is not injected.",
    }
    out_path = out_dir / "context_hotword_poc.json"
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"Wrote {out_path}")
    print("Raw:      " + raw_text)
    print("Correct:  " + corrected)
    print("\nSelected hotwords:")
    for item in ranked:
        print(f"- {item.term} score={item.score} reasons={';'.join(item.reasons)}")
    print("\nEdits:")
    for edit in edits:
        print(f"- {edit['from']} -> {edit['to']} ({edit['reason']})")


if __name__ == "__main__":
    main()
