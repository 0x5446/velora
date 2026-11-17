"""Plan the M1 baseline collection without running Swift or Ollama.

The shipping default remains ``qwen3:8b``. This measurement sets the existing
``VELORA_OLLAMA_MODEL`` variable for one process. It does not read the
microphone, copy to the pasteboard, or keep transcript text.
"""

from __future__ import annotations

import re
from pathlib import Path

SOURCE_DEFAULT_MODEL = "qwen3:8b"
BASELINE_MODEL = "qwen3:8b"
MODEL_ENV = "VELORA_OLLAMA_MODEL"
SCHEMA = "velora.m1_baseline.v1"

_ENV_SOURCE = 'environment["VELORA_OLLAMA_MODEL"] ?? "qwen3:8b"'
_RELOAD = re.compile(r"^ollama_model_reload:(\d+)ms$")
_PRESSURE = re.compile(r"^ollama_ctx_pressure:(\d+)$")
_DEADLINE = re.compile(r"^compose_deadline_fallback:(\d+)ms$")
_DIGEST = re.compile(r"sha256:([0-9a-fA-F]{64})")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def assert_model_env_matches_source(root: Path | None = None) -> None:
    """Fail if the collector names an environment variable the app does not read."""
    path = (root or repo_root()) / "Velora/Sources/Velora/LocalModelEngines.swift"
    text = path.read_text(encoding="utf-8")
    if _ENV_SOURCE not in text:
        raise RuntimeError("VELORA_OLLAMA_MODEL default was not found in LocalModelEngines.swift")


def swift_invocation(root: Path, audio: Path) -> list[str]:
    command = [
        "swift",
        "run",
        "--package-path",
        str(root / "Velora"),
        "VeloraMac",
        "--mode",
        "input",
        "--sensevoice",
        "--audio",
        str(audio),
        "--source",
        "zh",
        "--json",
    ]
    if "--copy" in command:
        raise RuntimeError("baseline collection must not copy to the pasteboard")
    return command


def process_env(model: str, inherited: dict[str, str]) -> dict[str, str]:
    if model != BASELINE_MODEL:
        raise ValueError("M1 baseline is qwen3:8b; qwen3:14b is not a measured baseline")
    env = dict(inherited)
    env[MODEL_ENV] = model
    env.pop("VELORA_ALLOW_REMOTE_LLM", None)
    return env


def parse_ollama_show(text: str) -> dict[str, str | None]:
    """Keep digest, parameter size, and quantization. Drop the Modelfile body."""
    digest = None
    parameters = None
    quantization = None
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        match = _DIGEST.search(lines[index])
        if match:
            digest = match.group(1).lower()
        label, value = _split_field(lines, index)
        if label == "parameters" and value:
            parameters = value
        elif label == "quantization" and value:
            quantization = value
        index += 1
    return {"digest": digest, "parameters": parameters, "quantization": quantization}


def missing_model_report(model: str) -> dict:
    return {
        "schema": SCHEMA,
        "baseline_model": model,
        "source_default_model": SOURCE_DEFAULT_MODEL,
        "config_mechanism": MODEL_ENV,
        "persistent_preferences_changed": False,
        "copied_to_pasteboard": False,
        "microphone_used": False,
        "model_present": False,
        "n": 0,
        "runs": [],
        "limitations": [
            "ollama show failed, so no clip was timed",
            "n=0 is a failed collection, not a latency result",
        ],
    }


def redact_run(payload: dict, *, audio_sha256: str, audio_bytes: int, pass_index: int, exit_code: int) -> dict:
    """Drop transcript fields. Keep engine, stage times, and the reload warning."""
    stages = []
    for stage in (payload.get("trace") or {}).get("stages") or []:
        stages.append(
            {
                "name": stage.get("name"),
                "durationMS": stage.get("durationMS"),
                "phase": stage.get("phase"),
                "critical": stage.get("critical"),
            }
        )
    release = sum(item["durationMS"] or 0 for item in stages if item["critical"])
    asr = payload.get("asr") or {}
    compose = payload.get("compose") or {}
    insertion = payload.get("insertion") or {}
    reload_ms = None
    ctx_pressure = None
    deadline_fallback_ms = None
    llm_error = False
    rule_floor = False
    redacted_warnings = 0
    for warning in compose.get("warnings") or []:
        if not isinstance(warning, str):
            redacted_warnings += 1
            continue
        reload = _RELOAD.fullmatch(warning)
        pressure = _PRESSURE.fullmatch(warning)
        deadline = _DEADLINE.fullmatch(warning)
        if reload:
            reload_ms = int(reload.group(1))
        elif pressure:
            ctx_pressure = int(pressure.group(1))
        elif deadline:
            deadline_fallback_ms = int(deadline.group(1))
        elif warning == "compose_polished_rule_fallback":
            rule_floor = True
            continue
        elif warning.startswith("compose_llm_error"):
            llm_error = True
            redacted_warnings += 1
        else:
            redacted_warnings += 1
    if reload_ms is not None and reload_ms > 500:
        temperature = "reload_warning"
    else:
        temperature = "no_reload_warning"
    return {
        "audio_sha256": audio_sha256,
        "bytes": audio_bytes,
        "pass_index": pass_index,
        "exit": exit_code,
        "asr_engine": asr.get("engine"),
        "asr_model": asr.get("modelVersion"),
        "asr_chars": len(asr.get("text") or ""),
        "compose_engine": compose.get("engine"),
        "final_chars": len(payload.get("finalText") or ""),
        "reviewRequired": payload.get("reviewRequired"),
        "insertion_inserted": insertion.get("inserted"),
        "insertion_strategy": _strategy_name(insertion.get("strategy")),
        "release_to_insert_ms": release,
        "stages": stages,
        "ollama_reload_ms": reload_ms,
        "ollama_ctx_pressure_tokens": ctx_pressure,
        "deadline_fallback_ms": deadline_fallback_ms,
        "redacted_warning_count": redacted_warnings,
        "llm_error": llm_error,
        "rule_floor_used": rule_floor,
        "load_observation": temperature,
    }


def accepts_llm_baseline(row: dict, model: str) -> bool:
    """A rule floor or an LLM error is a failed collection, not a baseline sample."""
    if model != BASELINE_MODEL or row.get("exit") != 0:
        return False
    if row.get("compose_engine") != f"ollama:{model}":
        return False
    if row.get("llm_error") or row.get("rule_floor_used"):
        return False
    if row.get("deadline_fallback_ms") is not None:
        return False
    return True


def report_limitations() -> list[str]:
    return [
        "process environment only; UserDefaults and the source default stay qwen3:8b",
        "no microphone and no pasteboard copy; insertion strategy in the CLI is none",
        "release_to_insert_ms sums critical pipeline stages and is not an OS insert",
        "each audio path is run twice; pass_index 0 then 1 is script order, not a warm proof",
        "no_reload_warning is not proof the weights were already resident",
        "qwen3:14b produced no accepted LLM sample (n=0) and is not this baseline",
        "the restored qwen3:8b tag is not a claim of the July 2026 digest or quantization",
        "compose.engine=rules or compose_llm_error is not an LLM success",
        "historical qwen3:8b quality scores are not this HEAD's pass",
        "transcript text is not stored",
        "powermetrics was not sampled",
    ]


def parse_api_show(payload: dict) -> dict[str, str | None]:
    """Keep the local /api/show identity fields and drop the Modelfile prompt."""
    details = payload.get("details") if isinstance(payload.get("details"), dict) else {}
    raw = payload.get("digest") or ""
    digest = None
    if isinstance(raw, str):
        match = _DIGEST.search(raw if raw.startswith("sha256:") else f"sha256:{raw}")
        if match:
            digest = match.group(1).lower()
    parameters = details.get("parameter_size")
    quantization = details.get("quantization_level")
    return {
        "digest": digest,
        "parameters": parameters if isinstance(parameters, str) else None,
        "quantization": quantization if isinstance(quantization, str) else None,
    }


def keep_time_lines(stderr: str) -> str:
    """Keep /usr/bin/time -l accounting. Drop any other stderr, which may quote text."""
    kept = []
    for line in stderr.splitlines():
        if "real" in line and "user" in line and "sys" in line:
            kept.append(line)
        elif re.match(r"\s+\d+\s+\S", line):
            kept.append(line)
    return "\n".join(kept) + ("\n" if kept else "")


def parse_rss(ps_output: str) -> dict[str, int | None]:
    ollama = None
    sidecar = None
    for line in ps_output.splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        rss = int(parts[0])
        command = parts[1].lower()
        if ollama is None and re.search(r"(^|/)ollama(\s|$)", command):
            ollama = rss
        if sidecar is None and "sensevoice_sidecar.py" in command:
            sidecar = rss
    return {"ollama_rss_kb": ollama, "sensevoice_rss_kb": sidecar}


def _split_field(lines: list[str], index: int) -> tuple[str, str | None]:
    raw = lines[index].strip()
    if not raw or raw.lower().startswith("sha256:"):
        return "", None
    parts = raw.split(None, 1)
    label = parts[0].lower().rstrip(":")
    if label not in {"parameters", "quantization"}:
        return "", None
    if len(parts) > 1 and parts[1].strip():
        return label, parts[1].strip()
    if index + 1 < len(lines):
        nxt = lines[index + 1].strip()
        if nxt and nxt.lower().rstrip(":") not in {"parameters", "quantization", "digest", "model", "name", "size"}:
            return label, nxt
    return label, None


def _strategy_name(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return value.get("rawValue") or value.get("name")
    return None
