#!/usr/bin/env python3
"""
POC: release-to-insert latency budget.

This is not a model benchmark. It is an executable latency contract for the
product architecture. The purpose is to make "fast" concrete:

- measure from speech end / key release to text inserted
- move context, memory, partial ASR, and speculative text work before release
- keep cold model load out of the critical path
- fail the POC if any mode exceeds the target budget
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
import json
from pathlib import Path


@dataclass(frozen=True)
class Stage:
    name: str
    duration_ms: int
    phase: str
    critical: bool
    note: str


@dataclass(frozen=True)
class Scenario:
    name: str
    platform: str
    mode: str
    target_p50_ms: int
    target_p95_ms: int
    pre_release_stages: list[Stage]
    release_stages: list[Stage]
    cold_start_penalty_ms: int


def release_latency_ms(scenario: Scenario) -> int:
    return sum(stage.duration_ms for stage in scenario.release_stages if stage.critical)


def p95_estimate_ms(scenario: Scenario) -> int:
    # Conservative local estimate: p95 is p50 plus scheduler/UI/model jitter.
    jitter_by_platform = {
        "macos": 220,
        "ios": 420,
    }
    mode_extra = {
        "dictate": 80,
        "polish": 140,
        "translate": 180,
    }
    return release_latency_ms(scenario) + jitter_by_platform[scenario.platform] + mode_extra[scenario.mode]


def scenario_report(scenario: Scenario) -> dict:
    p50 = release_latency_ms(scenario)
    p95 = p95_estimate_ms(scenario)
    cold_p50 = p50 + scenario.cold_start_penalty_ms
    return {
        "name": scenario.name,
        "platform": scenario.platform,
        "mode": scenario.mode,
        "target_p50_ms": scenario.target_p50_ms,
        "target_p95_ms": scenario.target_p95_ms,
        "estimated_p50_ms": p50,
        "estimated_p95_ms": p95,
        "cold_start_p50_ms": cold_p50,
        "passes_warm_path": p50 <= scenario.target_p50_ms and p95 <= scenario.target_p95_ms,
        "passes_cold_path": cold_p50 <= scenario.target_p50_ms,
        "pre_release_stages": [asdict(stage) for stage in scenario.pre_release_stages],
        "release_stages": [asdict(stage) for stage in scenario.release_stages],
        "critical_path_ms": {
            stage.name: stage.duration_ms
            for stage in scenario.release_stages
            if stage.critical
        },
        "required_architecture": [
            "Prewarm ASR and text engines before recording starts.",
            "Run context capture and hotword ranking while the user is speaking.",
            "Use streaming ASR partials and speculative correction before release.",
            "Keep large LLM generation off the default critical path.",
            "Insert first, then offer background improvement when quality work is slow.",
            "Record per-stage latency for every session.",
        ],
    }


COMMON_PRE_RELEASE = [
    Stage("engine_prewarm", 0, "before_recording", False, "Models must already be resident."),
    Stage("context_capture", 28, "during_recording", False, "Active app, window, selection, nearby text."),
    Stage("hotword_rank", 14, "during_recording", False, "Top K memory terms selected before release."),
    Stage("streaming_asr_partial", 0, "during_recording", False, "Partial transcript continuously updated."),
    Stage("speculative_correction", 0, "during_recording", False, "Draft correction starts from partial transcript."),
]


SCENARIOS = [
    Scenario(
        name="macos_dictate_fast_path",
        platform="macos",
        mode="dictate",
        target_p50_ms=700,
        target_p95_ms=1200,
        cold_start_penalty_ms=1400,
        pre_release_stages=COMMON_PRE_RELEASE,
        release_stages=[
            Stage("vad_flush", 30, "after_release", True, "Close final audio segment."),
            Stage("asr_finalize", 260, "after_release", True, "Finalize streaming ASR."),
            Stage("correction_reconcile", 90, "after_release", True, "Apply final hotword-aware diff."),
            Stage("render_insert_text", 8, "after_release", True, "Build insertion payload."),
            Stage("insert_text", 36, "after_release", True, "IMK/AX/pasteboard insertion."),
        ],
    ),
    Scenario(
        name="macos_polish_fast_path",
        platform="macos",
        mode="polish",
        target_p50_ms=900,
        target_p95_ms=1500,
        cold_start_penalty_ms=1800,
        pre_release_stages=COMMON_PRE_RELEASE
        + [
            Stage("speculative_polish", 0, "during_recording", False, "Run on partial transcript when possible."),
        ],
        release_stages=[
            Stage("vad_flush", 30, "after_release", True, "Close final audio segment."),
            Stage("asr_finalize", 260, "after_release", True, "Finalize streaming ASR."),
            Stage("correction_reconcile", 90, "after_release", True, "Apply final hotword-aware diff."),
            Stage("polish_reconcile", 170, "after_release", True, "Small local model or rules only."),
            Stage("render_insert_text", 8, "after_release", True, "Build insertion payload."),
            Stage("insert_text", 36, "after_release", True, "IMK/AX/pasteboard insertion."),
        ],
    ),
    Scenario(
        name="macos_translate_fast_path",
        platform="macos",
        mode="translate",
        target_p50_ms=1100,
        target_p95_ms=1800,
        cold_start_penalty_ms=2200,
        pre_release_stages=COMMON_PRE_RELEASE
        + [
            Stage("speculative_translation", 0, "during_recording", False, "Prepare target language draft from partial."),
        ],
        release_stages=[
            Stage("vad_flush", 30, "after_release", True, "Close final audio segment."),
            Stage("asr_finalize", 260, "after_release", True, "Finalize streaming ASR."),
            Stage("correction_reconcile", 90, "after_release", True, "Correct source before translation."),
            Stage("translation_reconcile", 260, "after_release", True, "Local translation final pass."),
            Stage("render_bilingual_text", 12, "after_release", True, "Source + target render."),
            Stage("insert_text", 42, "after_release", True, "IMK/AX/pasteboard insertion."),
        ],
    ),
    Scenario(
        name="ios_translate_bridge_path",
        platform="ios",
        mode="translate",
        target_p50_ms=1600,
        target_p95_ms=2600,
        cold_start_penalty_ms=2400,
        pre_release_stages=COMMON_PRE_RELEASE
        + [
            Stage("keyboard_bridge_prepare", 0, "during_recording", False, "Prepare App Group output slot."),
        ],
        release_stages=[
            Stage("vad_flush", 40, "after_release", True, "Close final audio segment."),
            Stage("asr_finalize", 360, "after_release", True, "Finalize mobile ASR."),
            Stage("correction_reconcile", 120, "after_release", True, "Apply final hotword-aware diff."),
            Stage("translation_reconcile", 360, "after_release", True, "Local translation final pass."),
            Stage("write_app_group_result", 30, "after_release", True, "Make result visible to keyboard."),
            Stage("keyboard_insert_text", 90, "after_release", True, "User returns and taps insert."),
        ],
    ),
]


def main() -> None:
    reports = [scenario_report(scenario) for scenario in SCENARIOS]
    out_dir = Path(__file__).resolve().parent / "out"
    out_dir.mkdir(exist_ok=True)
    out_path = out_dir / "latency_budget_poc.json"
    out_path.write_text(json.dumps(reports, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"Wrote {out_path}")
    failed = False
    for report in reports:
        print("\n---")
        print(report["name"])
        print(
            f"warm p50={report['estimated_p50_ms']}ms "
            f"target={report['target_p50_ms']}ms"
        )
        print(
            f"warm p95={report['estimated_p95_ms']}ms "
            f"target={report['target_p95_ms']}ms"
        )
        print(f"cold p50={report['cold_start_p50_ms']}ms")
        print(f"passes_warm_path={report['passes_warm_path']}")
        print(f"passes_cold_path={report['passes_cold_path']}")
        if not report["passes_warm_path"]:
            failed = True

    if failed:
        raise SystemExit("Latency budget failed")


if __name__ == "__main__":
    main()
