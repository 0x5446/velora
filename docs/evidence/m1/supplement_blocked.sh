#!/bin/zsh
# RSS snapshot wrapper. Does not pull, delete, paste, or sample power.
# collector exit 1 means a failure sample was written. A clean exit is not an M1 pass.
# zsh keeps `status` read-only, so the collector result uses another name.
set -euo pipefail

ROOT="${VELORA_ROOT:-/Users/alpha/workspace/velora}"
OUT="${VELORA_M1_OUT:-/Users/alpha/specdict/evidence/m1-rss-supplement}"

printf 'M1 stays blocked. This script does not declare a pass.\n'
printf 'llama-server RSS (not the ollama daemon):\n'
ps -ax -o rss=,comm= | awk '/llama-server/ {print}' || true
printf 'developer_mode='
defaults read app.velora.mac velora.developer_mode 2>/dev/null || printf 'unset\n'

if [[ "${VELORA_M1_RSS_SUPPLEMENT:-0}" != "1" ]]; then
  printf 'RSS supplement not requested. Set VELORA_M1_RSS_SUPPLEMENT=1 and pass one short clip then one long clip.\n'
  exit 0
fi
if [[ "$#" -ne 2 ]]; then
  printf 'usage: VELORA_M1_RSS_SUPPLEMENT=1 %s short.caf long.caf\n' "$0" >&2
  exit 2
fi

export VELORA_ROOT="$ROOT"
export VELORA_M1_OUT="$OUT"
export VELORA_M1_MODEL=qwen3:8b
export VELORA_M1_REPEATS=1
export VELORA_OLLAMA_MODEL=qwen3:8b
collector="${VELORA_M1_COLLECTOR:-$ROOT/docs/evidence/m1/collect_baseline.sh}"
collector_status=0
"$collector" "$1" "$2" || collector_status=$?
printf 'collector_exit=%s\n' "$collector_status"
printf 'paste_ms and physical T4 stay null. powermetrics was not sampled. RSS lines are snapshots, not peaks.\n'
if [[ "$collector_status" -gt 1 ]]; then
  exit "$collector_status"
fi
