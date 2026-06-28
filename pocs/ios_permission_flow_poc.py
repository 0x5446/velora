#!/usr/bin/env python3
"""
POC: iPhone authorization flow contract.

This is a product/architecture POC, not an iOS runtime test. It models which
system permission prompts are allowed in each user journey. The goal is to keep
the first value moment as low-friction as possible:

- first launch asks for nothing
- default local ASR recording asks for microphone only
- Apple Speech permission is not on the default path
- custom keyboard "Full Access" is optional because it is a scary iOS prompt
- contacts/calendar learning is opt-in after the core dictation value is proven
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
import json
from pathlib import Path


@dataclass(frozen=True)
class PermissionEvent:
    name: str
    system_prompt: bool
    timing: str
    reason: str
    fallback: str


@dataclass(frozen=True)
class Journey:
    name: str
    default_path: bool
    events: list[PermissionEvent]
    max_prompts_before_first_value: int
    max_prompts_in_single_step: int


JOURNEYS = [
    Journey(
        name="first_launch",
        default_path=True,
        events=[],
        max_prompts_before_first_value=0,
        max_prompts_in_single_step=0,
    ),
    Journey(
        name="default_record_with_local_asr",
        default_path=True,
        events=[
            PermissionEvent(
                name="microphone",
                system_prompt=True,
                timing="on_first_record_tap",
                reason="capture speech audio locally",
                fallback="manual text input, import audio later, or open Settings",
            ),
        ],
        max_prompts_before_first_value=1,
        max_prompts_in_single_step=1,
    ),
    Journey(
        name="optional_apple_speech_engine",
        default_path=False,
        events=[
            PermissionEvent(
                name="speech_recognition",
                system_prompt=True,
                timing="only_after_user_selects_apple_speech_engine",
                reason="use Apple Speech recognition backend",
                fallback="switch back to WhisperKit/local ASR engine",
            ),
        ],
        max_prompts_before_first_value=0,
        max_prompts_in_single_step=1,
    ),
    Journey(
        name="optional_fast_insert_keyboard",
        default_path=False,
        events=[
            PermissionEvent(
                name="add_keyboard",
                system_prompt=False,
                timing="after_user_enables_fast_insert",
                reason="let the user insert recent results inside other apps",
                fallback="copy/share result from main app",
            ),
            PermissionEvent(
                name="keyboard_full_access",
                system_prompt=True,
                timing="only_for_app_group_result_sharing",
                reason="keyboard reads the latest result from the containing app",
                fallback="keyboard can open the main app, or user can paste from clipboard",
            ),
        ],
        max_prompts_before_first_value=0,
        max_prompts_in_single_step=1,
    ),
    Journey(
        name="optional_context_personalization",
        default_path=False,
        events=[
            PermissionEvent(
                name="contacts",
                system_prompt=True,
                timing="only_after_user_enables_people_names",
                reason="improve local recognition of names",
                fallback="manual hotword list",
            ),
            PermissionEvent(
                name="calendar",
                system_prompt=True,
                timing="only_after_user_enables_meeting_terms",
                reason="improve local recognition of meeting names",
                fallback="manual hotword list",
            ),
        ],
        max_prompts_before_first_value=0,
        max_prompts_in_single_step=1,
    ),
]


def validate(journey: Journey) -> list[str]:
    issues: list[str] = []
    prompt_count = sum(1 for event in journey.events if event.system_prompt)
    if journey.default_path and journey.name == "first_launch" and prompt_count != 0:
        issues.append("first_launch_must_not_prompt")
    if journey.default_path and prompt_count > journey.max_prompts_before_first_value:
        issues.append("too_many_prompts_before_first_value")
    if journey.max_prompts_in_single_step > 1:
        issues.append("single_step_prompt_stack_not_allowed")
    for event in journey.events:
        if not event.fallback:
            issues.append(f"missing_fallback:{event.name}")
    return issues


def main() -> None:
    reports = []
    failed = False
    for journey in JOURNEYS:
        issues = validate(journey)
        failed = failed or bool(issues)
        reports.append(
            {
                **asdict(journey),
                "system_prompt_count": sum(1 for event in journey.events if event.system_prompt),
                "issues": issues,
            }
        )

    out_dir = Path(__file__).resolve().parent / "out"
    out_dir.mkdir(exist_ok=True)
    out_path = out_dir / "ios_permission_flow_poc.json"
    out_path.write_text(json.dumps(reports, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"Wrote {out_path}")
    for report in reports:
        print("\n---")
        print(report["name"])
        print(f"default_path={report['default_path']}")
        print(f"system_prompt_count={report['system_prompt_count']}")
        print(f"issues={report['issues']}")
        for event in report["events"]:
            prompt = "system" if event["system_prompt"] else "instruction"
            print(f"- {event['name']} ({prompt}) at {event['timing']}")

    if failed:
        raise SystemExit("Permission flow contract failed")


if __name__ == "__main__":
    main()
