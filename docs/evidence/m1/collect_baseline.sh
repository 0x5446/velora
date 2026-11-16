#!/bin/zsh
# Measure the current Velora product path on the Mac.
# SenseVoice whole-file ASR + Ollama qwen3:8b. Does not pass --copy.
# Does not select the 1.7B sidecar. Writes outside the git worktree.
#
# Usage, from anywhere:
#   docs/evidence/m1/collect_baseline.sh /path/one.caf /path/two.wav
# Audio arguments are ordinary files. The script records their sha256 and
# byte size, then drops transcript text from the CLI JSON.
set -euo pipefail

ROOT="${VELORA_ROOT:-/Users/alpha/workspace/velora}"
OUT="${VELORA_M1_OUT:-/Users/alpha/specdict/evidence/m1-baseline-20261116}"
mkdir -p "$OUT"
cd "$ROOT"

{
  printf 'when=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'head=%s\n' "$(git rev-parse HEAD)"
  sysctl -n machdep.cpu.brand_string
  sysctl -n hw.memsize
  sw_vers
  xcodebuild -version
  swift --version
  ollama --version
  ollama show qwen3:8b | awk '/^Model$|^Name$|^Parameters$|^Quantization$|^Digest$|^Size$/{print; getline; print}'
} > "$OUT/env.txt"

MODEL="$ROOT/Models/sensevoice/model.int8.onnx"
TOKENS="$ROOT/Models/sensevoice/tokens.txt"
PYTHON="$ROOT/Models/sensevoice/.venv/bin/python"
SIDECAR="$ROOT/scripts/sensevoice_sidecar.py"
if [[ ! -f "$MODEL" || ! -f "$TOKENS" || ! -x "$PYTHON" || ! -f "$SIDECAR" ]]; then
  printf 'MISSING sensevoice assets under %s\n' "$ROOT" >&2
  printf 'resolvedDefault also checks VELORA_SENSEVOICE_ROOT and ~/workspace/velora\n' >&2
  exit 2
fi
shasum -a 256 "$MODEL" "$TOKENS" > "$OUT/sensevoice.sha256"

if [[ "$#" -lt 1 ]]; then
  printf 'pass at least one audio path\n' >&2
  exit 2
fi

export VELORA_M1_OUT="$OUT"
python3 - "$@" <<'PY'
import hashlib, json, os, subprocess, sys
from pathlib import Path

out = Path(os.environ["VELORA_M1_OUT"])
root = Path(os.environ.get("VELORA_ROOT", "/Users/alpha/workspace/velora"))
rows = []
for raw in sys.argv[1:]:
    audio = Path(raw)
    digest = hashlib.sha256(audio.read_bytes()).hexdigest()
    cmd = [
        "swift", "run", "--package-path", str(root / "Velora"), "VeloraMac",
        "--mode", "input",
        "--sensevoice",
        "--audio", str(audio),
        "--source", "zh",
        "--json",
    ]
    timed = ["/usr/bin/time", "-l", *cmd]
    proc = subprocess.run(timed, cwd=root, text=True, capture_output=True)
    (out / f"time-{digest[:12]}.txt").write_text(proc.stderr)
    if proc.returncode != 0:
        rows.append({"audio_sha256": digest, "bytes": audio.stat().st_size, "exit": proc.returncode})
        continue
    payload = json.loads(proc.stdout)
    stages = []
    for stage in payload.get("trace", {}).get("stages", []):
        stages.append({
            "name": stage.get("name"),
            "durationMS": stage.get("durationMS"),
            "phase": stage.get("phase"),
            "critical": stage.get("critical"),
        })
    release = sum(item["durationMS"] or 0 for item in stages if item["critical"])
    asr = payload.get("asr") or {}
    compose = payload.get("compose") or {}
    insertion = payload.get("insertion") or {}
    rows.append({
        "audio_sha256": digest,
        "bytes": audio.stat().st_size,
        "exit": 0,
        "asr_engine": asr.get("engine"),
        "asr_model": asr.get("modelVersion"),
        "asr_chars": len(asr.get("text") or ""),
        "compose_engine": compose.get("engine"),
        "final_chars": len(payload.get("finalText") or ""),
        "reviewRequired": payload.get("reviewRequired"),
        "insertion_inserted": insertion.get("inserted"),
        "insertion_strategy": insertion.get("strategy"),
        "release_to_insert_ms": release,
        "stages": stages,
    })
(out / "runs.json").write_text(json.dumps(rows, indent=2) + "\n")
print(out / "runs.json")
PY
