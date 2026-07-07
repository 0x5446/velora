#!/bin/bash
# 重新生成 demo GIF 的两幕配音（见 docs/DEMO_GIF_RUNBOOK.md）
# 需要环境变量 CARTESIA_API_KEY
set -euo pipefail

: "${CARTESIA_API_KEY:?请先 export CARTESIA_API_KEY}"

OUT_DIR="${1:-/tmp/velora-demo}"
mkdir -p "$OUT_DIR"

# Skylar（美式女声），彩排选定；换音色时用 GET /voices/ 重挑
VOICE_ID="db6b0ed5-d5d3-463d-ae85-518a07d3c2b4"

gen() {
  local out="$1" lang="$2" text="$3"
  curl -sf -X POST "https://api.cartesia.ai/tts/bytes" \
    -H "X-API-Key: $CARTESIA_API_KEY" \
    -H "Cartesia-Version: 2025-04-16" \
    -H "Content-Type: application/json" \
    -d "{
      \"model_id\": \"sonic-2\",
      \"transcript\": \"$text\",
      \"voice\": {\"mode\":\"id\",\"id\":\"$VOICE_ID\"},
      \"output_format\": {\"container\":\"wav\",\"encoding\":\"pcm_s16le\",\"sample_rate\":44100},
      \"language\": \"$lang\"
    }" -o "$out"
  afinfo "$out" | grep -E "duration|data format" || true
}

# 第一幕：听写，英文带语气词（验证 um/uh 剥除 + five p m → 5 PM）
gen "$OUT_DIR/beat1en.wav" en "Um, so, remind me to, uh, send the weekly report to the team before five p m."

# 第二幕：翻译，标准中文（验证逐字转写 + 英文译文上屏）
gen "$OUT_DIR/beat2.wav" zh "所有的语音识别和翻译都在这台电脑上完成，完全不需要联网。"

echo "done -> $OUT_DIR"
