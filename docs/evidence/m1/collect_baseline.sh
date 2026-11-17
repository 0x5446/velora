#!/bin/zsh
# M1 baseline on this Mac: SenseVoice + Ollama qwen3:8b.
# The process sets VELORA_OLLAMA_MODEL itself, so a leftover 14b value is not inherited.
# Does not pass the pasteboard flag, does not use the microphone, and does not pull a model.
#
#   docs/evidence/m1/collect_baseline.sh /path/one.caf /path/two.wav
set -euo pipefail

ROOT="${VELORA_ROOT:-/Users/alpha/workspace/velora}"
OUT="${VELORA_M1_OUT:-/Users/alpha/specdict/evidence/m1-baseline-8b}"
MODEL="${VELORA_M1_MODEL:-qwen3:8b}"
mkdir -p "$OUT"
cd "$ROOT"

if [[ "$MODEL" != "qwen3:8b" ]]; then
  printf 'refusing %s; the M1 baseline is qwen3:8b\n' "$MODEL" >&2
  exit 2
fi

{
  printf 'when=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'head=%s\n' "$(git rev-parse HEAD)"
  printf 'baseline_model=%s\n' "$MODEL"
  printf 'source_default_model=qwen3:8b\n'
  printf 'config_mechanism=VELORA_OLLAMA_MODEL\n'
  sysctl -n machdep.cpu.brand_string
  sysctl -n hw.memsize
  sw_vers
  xcodebuild -version
  swift --version
  ollama --version
} > "$OUT/env.txt"

SENSE_MODEL="$ROOT/Models/sensevoice/model.int8.onnx"
TOKENS="$ROOT/Models/sensevoice/tokens.txt"
PYTHON="$ROOT/Models/sensevoice/.venv/bin/python"
SIDECAR="$ROOT/scripts/sensevoice_sidecar.py"
if [[ ! -f "$SENSE_MODEL" || ! -f "$TOKENS" || ! -x "$PYTHON" || ! -f "$SIDECAR" ]]; then
  printf 'MISSING sensevoice assets under %s\n' "$ROOT" >&2
  exit 2
fi
shasum -a 256 "$SENSE_MODEL" "$TOKENS" > "$OUT/sensevoice.sha256"

if [[ "$#" -lt 1 ]]; then
  printf 'pass at least one audio path\n' >&2
  exit 2
fi

export VELORA_M1_OUT="$OUT"
export VELORA_M1_MODEL="$MODEL"
export VELORA_OLLAMA_MODEL="$MODEL"
export VELORA_ROOT="$ROOT"
REPEATS="${VELORA_M1_REPEATS:-2}"

python3 - "$MODEL" "$OUT" "$REPEATS" "$@" <<'PY'
import hashlib, json, os, subprocess, sys
from pathlib import Path

sys.path.insert(0, str(Path(os.environ["VELORA_ROOT"]) / "pocs/m1_baseline"))
from plan import (
    assert_model_env_matches_source,
    keep_time_lines,
    missing_model_report,
    parse_api_show,
    parse_ollama_show,
    parse_rss,
    process_env,
    accepts_llm_baseline,
    redact_run,
    report_limitations,
    swift_invocation,
)

model = sys.argv[1]
out = Path(sys.argv[2])
repeats = int(sys.argv[3])
root = Path(os.environ["VELORA_ROOT"])
assert_model_env_matches_source(root)
if repeats < 1:
    raise SystemExit(2)

def identity():
    api = subprocess.run(
        [
            "curl", "-sS", "--max-time", "5",
            "http://127.0.0.1:11434/api/show",
            "-H", "Content-Type: application/json",
            "-d", json.dumps({"name": model}),
        ],
        text=True,
        capture_output=True,
    )
    if api.returncode == 0 and api.stdout.strip().startswith("{"):
        parsed = parse_api_show(json.loads(api.stdout))
        if parsed["digest"]:
            return parsed
    show = subprocess.run(["ollama", "show", model], text=True, capture_output=True)
    return parse_ollama_show(show.stdout)

parsed = identity()
if parsed["digest"] is None:
    report = missing_model_report(model)
    report["ollama_show"] = parsed
    (out / "runs.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(1)

def rss():
    proc = subprocess.run(["ps", "-ax", "-o", "rss=,command="], text=True, capture_output=True)
    return parse_rss(proc.stdout if proc.returncode == 0 else "")

runs = []
pass_index = 0
for raw in sys.argv[4:]:
    audio = Path(raw)
    blob = audio.read_bytes()
    digest = hashlib.sha256(blob).hexdigest()
    for _ in range(repeats):
        before = rss()
        command = swift_invocation(root, audio)
        env = process_env(model, os.environ.copy())
        proc = subprocess.run(
            ["/usr/bin/time", "-l", *command],
            cwd=root,
            env=env,
            text=True,
            capture_output=True,
        )
        (out / f"time-{digest[:12]}-{pass_index}.txt").write_text(keep_time_lines(proc.stderr), encoding="utf-8")
        after = rss()
        if proc.returncode != 0:
            runs.append({
                "audio_sha256": digest,
                "bytes": len(blob),
                "pass_index": pass_index,
                "exit": proc.returncode,
                "stdout_chars": len(proc.stdout),
                "rss_before": before,
                "rss_after": after,
            })
            pass_index += 1
            continue
        try:
            payload = json.loads(proc.stdout)
        except json.JSONDecodeError:
            runs.append({
                "audio_sha256": digest,
                "bytes": len(blob),
                "pass_index": pass_index,
                "exit": "json",
                "stdout_chars": len(proc.stdout),
                "rss_before": before,
                "rss_after": after,
            })
            pass_index += 1
            continue
        row = redact_run(payload, audio_sha256=digest, audio_bytes=len(blob), pass_index=pass_index, exit_code=0)
        row["rss_before"] = before
        row["rss_after"] = after
        runs.append(row)
        pass_index += 1

ok = [row for row in runs if accepts_llm_baseline(row, model)]
report = {
    "schema": "velora.m1_baseline.v1",
    "baseline_model": model,
    "source_default_model": "qwen3:8b",
    "config_mechanism": "VELORA_OLLAMA_MODEL",
    "persistent_preferences_changed": False,
    "copied_to_pasteboard": False,
    "microphone_used": False,
    "model_downloaded": False,
    "model_present": True,
    "ollama_show": parsed,
    "repeats_per_audio": repeats,
    "n": len(ok),
    "n_attempted": len(runs),
    "runs": runs,
    "limitations": report_limitations(),
}
(out / "runs.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(out / "runs.json")
if len(ok) != len(runs):
    raise SystemExit(1)
PY
