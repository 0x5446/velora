#!/usr/bin/env python3
import datetime as _datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_DIR = ROOT / "Velora"
DIAG = PACKAGE_DIR / ".build" / "debug" / "VeloraDiagnostics"
OUT_ROOT = Path(os.environ.get("VELORA_QUALITY_OUT", ROOT / "pocs" / "out" / "quality-eval"))


def run_command(args, timeout=120):
    started = _datetime.datetime.now()
    completed = subprocess.run(
        args,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    elapsed_ms = int((_datetime.datetime.now() - started).total_seconds() * 1000)
    return {
        "args": args,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
        "elapsed_ms": elapsed_ms,
    }


def ensure_diagnostics():
    if DIAG.exists() and os.access(DIAG, os.X_OK):
        return
    result = run_command([
        "swift",
        "build",
        "--package-path",
        str(PACKAGE_DIR),
        "--product",
        "VeloraDiagnostics",
    ], timeout=180)
    if result["returncode"] != 0:
        sys.stderr.write(result["stdout"])
        sys.stderr.write(result["stderr"])
        raise SystemExit(result["returncode"])


def parse_report(result):
    try:
        return json.loads(result["stdout"])
    except json.JSONDecodeError:
        return {
            "module": "quality-eval",
            "ok": False,
            "summary": "invalid_json_report",
            "details": {
                "stdout": result["stdout"][-1200:],
                "stderr": result["stderr"][-1200:],
            },
            "metrics": {"wall_ms": result["elapsed_ms"]},
            "output": "",
        }


def normalize_for_distance(text):
    text = text.lower()
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def normalize_chars(text):
    return re.sub(r"\s+", "", normalize_for_distance(text))


def normalize_words(text):
    text = normalize_for_distance(text)
    text = re.sub(r"[^\w\u4e00-\u9fff]+", " ", text)
    return [part for part in text.split(" ") if part]


def edit_distance(left, right):
    if left == right:
        return 0
    if not left:
        return len(right)
    if not right:
        return len(left)

    previous = list(range(len(right) + 1))
    for i, left_item in enumerate(left, start=1):
        current = [i]
        for j, right_item in enumerate(right, start=1):
            cost = 0 if left_item == right_item else 1
            current.append(min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + cost,
            ))
        previous = current
    return previous[-1]


def distance_metrics(reference, hypothesis):
    reference_chars = list(normalize_chars(reference))
    hypothesis_chars = list(normalize_chars(hypothesis))
    reference_words = normalize_words(reference)
    hypothesis_words = normalize_words(hypothesis)

    cer_denominator = max(1, len(reference_chars))
    wer_denominator = max(1, len(reference_words))
    return {
        "cer": edit_distance(reference_chars, hypothesis_chars) / cer_denominator,
        "wer": edit_distance(reference_words, hypothesis_words) / wer_denominator,
        "reference_chars": len(reference_chars),
        "hypothesis_chars": len(hypothesis_chars),
        "reference_words": len(reference_words),
        "hypothesis_words": len(hypothesis_words),
    }


def contains_checks(output, expected=None, forbidden=None):
    expected = expected or []
    forbidden = forbidden or []
    missing = [item for item in expected if item not in output]
    present_forbidden = [item for item in forbidden if item in output]
    return missing, present_forbidden


def local_models_available():
    preference = os.environ.get("VELORA_EVAL_LOCAL_MODELS", "auto").lower()
    if preference in {"0", "false", "no"}:
        return False, "disabled_by_env"
    if preference in {"1", "true", "yes"}:
        return True, "forced_by_env"

    result = run_command([str(DIAG), "ollama", "--task", "prewarm"], timeout=45)
    report = parse_report(result)
    return bool(report.get("ok")), report.get("summary", "ollama_probe_unknown")


def text_cases(use_local_models):
    local_args = ["--local-models"] if use_local_models else []
    engine_id = "local" if use_local_models else "logic"
    return [
        {
            "id": f"{engine_id}_translate_bilingual_review_terms",
            "args": [
                str(DIAG),
                "text",
                "--mode",
                "translate",
                "--text",
                "展示给拥护确认之后再上评，终于门对照就是这个价值",
                "--source",
                "zh",
                "--target",
                "en",
                "--insert-policy",
                "bilingual",
                *local_args,
            ],
            "expected_contains": ["原文:", "译文:", "用户", "上屏", "中英文对照"],
            "forbidden_contains": ["拥护", "上评", "终于门对照"],
            "max_wall_ms": 15000 if use_local_models else 1500,
        },
        {
            "id": f"{engine_id}_translate_entity_retention",
            "args": [
                str(DIAG),
                "text",
                "--mode",
                "translate",
                "--text",
                "明天上午十点我和 Alex 开会，帮我确认一下 agenda",
                "--source",
                "zh",
                "--target",
                "en",
                "--insert-policy",
                "bilingual",
                *local_args,
            ],
            "expected_contains": ["原文:", "译文:", "Alex", "agenda"],
            "forbidden_contains": [],
            "max_wall_ms": 15000 if use_local_models else 1500,
        },
        {
            "id": f"{engine_id}_polish_keeps_entities",
            "args": [
                str(DIAG),
                "text",
                "--mode",
                "polish",
                "--text",
                "明天上午十点我和 Alex 开会 帮我确认一下 agenda",
                "--source",
                "zh",
                *local_args,
            ],
            "expected_contains": ["Alex", "agenda"],
            "forbidden_contains": ["输出：", "最终文本：", "<think>"],
            "max_wall_ms": 12000 if use_local_models else 1000,
        },
    ]


def evaluate_text_case(case):
    result = run_command(case["args"], timeout=max(30, int(case["max_wall_ms"] / 1000) + 20))
    report = parse_report(result)
    output = report.get("output") or ""
    missing, forbidden = contains_checks(
        output,
        expected=case.get("expected_contains"),
        forbidden=case.get("forbidden_contains"),
    )
    wall_ms = int(report.get("metrics", {}).get("wall_ms", result["elapsed_ms"]))
    ok = bool(report.get("ok")) and not missing and not forbidden and wall_ms <= case["max_wall_ms"]
    return {
        "id": case["id"],
        "type": "text",
        "ok": ok,
        "summary": report.get("summary", ""),
        "missing": missing,
        "forbidden": forbidden,
        "metrics": {"wall_ms": wall_ms},
        "output": output,
        "report": report,
    }


def load_asr_cases():
    manifest = os.environ.get("VELORA_ASR_AUDIO_MANIFEST")
    cases = []
    if manifest:
        with open(manifest, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    cases.append(json.loads(line))

    audio = os.environ.get("VELORA_TEST_AUDIO")
    reference = os.environ.get("VELORA_ASR_REFERENCE")
    if audio and reference:
        cases.append({
            "id": "env_audio",
            "audio": audio,
            "reference": reference,
            "source": os.environ.get("VELORA_ASR_SOURCE", "en"),
        })
    return cases


def evaluate_asr_case(case, mode):
    args = [
        str(DIAG),
        "asr",
        "--audio",
        case["audio"],
        "--source",
        case.get("source", "en"),
        "--asr-mode",
        mode,
    ]
    if case.get("context"):
        args.extend(["--context", case["context"]])

    result = run_command(args, timeout=180)
    report = parse_report(result)
    output = report.get("output") or ""
    metrics = {"wall_ms": int(report.get("metrics", {}).get("wall_ms", result["elapsed_ms"]))}
    if case.get("reference"):
        metrics.update(distance_metrics(case["reference"], output))

    max_cer = float(case.get("max_cer", os.environ.get("VELORA_EVAL_MAX_CER", "0.35")))
    max_wer = float(case.get("max_wer", os.environ.get("VELORA_EVAL_MAX_WER", "0.45")))
    ok = bool(report.get("ok")) and bool(output.strip())
    if "cer" in metrics:
        ok = ok and metrics["cer"] <= max_cer and metrics["wer"] <= max_wer

    return {
        "id": f"{case.get('id', Path(case['audio']).stem)}_{mode}",
        "type": "asr",
        "ok": ok,
        "summary": report.get("summary", ""),
        "metrics": metrics,
        "output": output,
        "reference": case.get("reference", ""),
        "report": report,
    }


def main():
    ensure_diagnostics()
    run_id = _datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = OUT_ROOT / run_id
    out_dir.mkdir(parents=True, exist_ok=True)

    results = []
    use_local_models, local_reason = local_models_available()

    for case in text_cases(use_local_models=False):
        results.append(evaluate_text_case(case))

    if use_local_models:
        for case in text_cases(use_local_models=True):
            results.append(evaluate_text_case(case))
    else:
        results.append({
            "id": "local_text_models",
            "type": "text",
            "ok": False,
            "summary": f"skipped:{local_reason}",
            "metrics": {},
            "output": "",
        })

    asr_modes = os.environ.get("VELORA_ASR_MODES", "fast accurate").split()
    for case in load_asr_cases():
        for mode in asr_modes:
            results.append(evaluate_asr_case(case, mode))

    pass_count = sum(1 for result in results if result["ok"])
    fail_count = len(results) - pass_count
    summary = {
        "ok": fail_count == 0,
        "run_id": run_id,
        "out_dir": str(out_dir),
        "pass": pass_count,
        "fail": fail_count,
        "local_models": use_local_models,
        "local_models_reason": local_reason,
    }

    with open(out_dir / "results.jsonl", "w", encoding="utf-8") as handle:
        for result in results:
            handle.write(json.dumps(result, ensure_ascii=False, sort_keys=True) + "\n")

    with open(out_dir / "summary.json", "w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")

    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    for result in results:
        status = "PASS" if result["ok"] else "FAIL"
        metric_preview = " ".join(f"{key}={value}" for key, value in result.get("metrics", {}).items())
        print(f"{status} {result['id']} {metric_preview}")

    raise SystemExit(0 if summary["ok"] else 1)


if __name__ == "__main__":
    main()
