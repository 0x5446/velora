#!/bin/bash
# Fully automated E2E for the edit-capture learning loop. No microphone, no
# speakers, no synthetic key events, no TCC grants for this script:
#
#   Cartesia TTS wav ──debug bridge──▶ Velora pipeline (ASR → polish)
#        ──Cmd+V (Velora's own AX)──▶ target window (scripts/e2e/EditCaptureTarget)
#        ──target edits its own text──▶ AXObserver diff → corrections.jsonl
#        ──next injection ingests──▶ memory.sqlite candidate pool → promotion
#
# Rounds:
#   1. sentence with 商品 → target fixes 商品→上屏 (asr_fix, session 1)
#   2. same again (session 2 — the promotion gate needs >=2 sessions)
#   3. receive-only round; its inject ingests round 2's pair
# Then asserts: journal has the insertion/post_insert_edit pairs AND the
# term 商品→上屏 is promoted in memory.sqlite.
#
# Prereqs: CARTESIA_API_KEY exported; Velora running a build with the debug
# bridge; `defaults write app.velora.mac velora.developer_mode -bool true`
# BEFORE Velora starts (the store reads it once at launch).
set -euo pipefail

: "${CARTESIA_API_KEY:?export CARTESIA_API_KEY first}"

DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /tmp/velora-e2e.XXXX)"
JOURNAL="$HOME/Library/Application Support/Velora/corrections.jsonl"
MEMORY="$HOME/Library/Application Support/Velora/memory.sqlite"
VOICE_ID="db6b0ed5-d5d3-463d-ae85-518a07d3c2b4"   # Skylar (multilingual sonic-2)

log() { printf '[e2e] %s\n' "$*"; }

tts() {
  local out="$1" text="$2"
  curl -sf -X POST "https://api.cartesia.ai/tts/bytes" \
    -H "X-API-Key: $CARTESIA_API_KEY" \
    -H "Cartesia-Version: 2025-04-16" \
    -H "Content-Type: application/json" \
    -d "{
      \"model_id\": \"sonic-2\",
      \"transcript\": \"$text\",
      \"voice\": {\"mode\":\"id\",\"id\":\"$VOICE_ID\"},
      \"output_format\": {\"container\":\"wav\",\"encoding\":\"pcm_s16le\",\"sample_rate\":16000},
      \"language\": \"zh\"
    }" -o "$out"
}

post_dictate() {
  swift - "$1" <<'EOF'
import Foundation
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("app.velora.debug.dictate"),
    object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)
EOF
}

wait_for_line() { # file marker timeout_s
  local file="$1" marker="$2" deadline=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -q "$marker" "$file" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

journal_count() { # kind since-iso
  python3 - "$JOURNAL" "$1" "$2" <<'EOF'
import json, sys
path, kind, since = sys.argv[1:4]
n = 0
try:
    for line in open(path):
        line = line.strip()
        if not line: continue
        e = json.loads(line)
        if e.get("kind") == kind and e.get("at", "") >= since:
            n += 1
except FileNotFoundError:
    pass
print(n)
EOF
}

# --- build target once ---
swiftc -O "$DIR/EditCaptureTarget.swift" -o "$WORK/target" 2>/dev/null
log "target compiled"

# --- synthesize speech ---
tts "$WORK/a.wav" "这个商品的功能设计需要再讨论一下。"
tts "$WORK/b.wav" "今天的会议就到这里。"
log "tts ready: $(afinfo "$WORK/a.wav" 2>/dev/null | grep -o 'duration.*' | head -1)"

SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Idempotence: synthetic residue from a previous run must not skew this one —
# including correction_examples, or round 1 would already auto-correct.
sqlite3 "$MEMORY" "DELETE FROM terms WHERE term='商品' AND replacement='上屏';" 2>/dev/null || true
sqlite3 "$MEMORY" "DELETE FROM correction_examples WHERE before_span='商品';" 2>/dev/null || true

round() { # wav rules idle label
  local wav="$1" rules="$2" idle="$3" label="$4"
  local out="$WORK/$label.log"
  "$WORK/target" "$rules" "$idle" > "$out" 2>&1 &
  local pid=$!
  wait_for_line "$out" "READY" 10 || { log "$label: target not ready"; kill $pid 2>/dev/null; return 1; }
  local target_pid
  target_pid=$(sed -n 's/.*PID:\([0-9]*\).*/\1/p' "$out" | head -1)
  sleep 1.5   # window + first-responder settle
  # Pin the paste to the harness pid — Velora activates it with its own AX
  # trust; a background-launched window may be denied self-activation and
  # "frontmost" would be the user's app.
  post_dictate "$wav|$target_pid"
  wait_for_line "$out" "DONE" 90 || { log "$label: no DONE (pipeline slow or paste missed)"; kill $pid 2>/dev/null; return 1; }
  wait $pid 2>/dev/null || true
  # NOTE: character-safe truncation — `cut -c` is byte-based here and
  # shreds CJK into mojibake.
  local preview
  preview=$(sed -n 's/^PASTED://p' "$out" | head -1 | python3 -c "import sys; print(sys.stdin.read().strip()[:24])")
  log "$label: $(grep -c PASTED "$out" || true) paste, $(grep -c EDITED "$out" || true) edit | $preview"
}

# Three a.wav rounds tolerate an occasional junk transcription and give the
# taught example at least one later round to prove history application
# (ingest happens at the NEXT round's inject). b.wav closes the last ingest.
round "$WORK/a.wav" "商品=上屏" 12 "round1"
round "$WORK/a.wav" "商品=上屏" 12 "round2"
round "$WORK/a.wav" "商品=上屏" 12 "round3"
round "$WORK/b.wav" ""          6  "round4"

# --- assertions (learning-aware) ---
# Round 1 teaches 商品→上屏; its ingest at round 2's inject feeds
# correction_history, so round 2's polish is EXPECTED to auto-correct before
# pasting — the deepest possible loop assertion (capture → journal → ingest →
# retrieval → prompt → model applies).
sleep 2
INSERTIONS=$(journal_count insertion "$SINCE")
EDITS=$(journal_count post_insert_edit "$SINCE")
CANDIDATE=$(sqlite3 "$MEMORY" "SELECT COUNT(*) FROM terms WHERE term='商品' AND replacement='上屏';" 2>/dev/null || echo 0)
APPLIED=$(python3 - "$JOURNAL" "$SINCE" <<'PYEOF'
import json, sys
path, since = sys.argv[1:3]
n = 0
for line in open(path):
    line = line.strip()
    if not line: continue
    e = json.loads(line)
    if e.get("kind") == "insertion" and e.get("at", "") >= since        and e.get("app_bundle") == "" and "上屏" in e.get("final_text", ""):
        n += 1
print(n)
PYEOF
)

log "insertions=$INSERTIONS post_insert_edits=$EDITS candidate=$CANDIDATE history_applied=$APPLIED"
FAIL=0
[ "$INSERTIONS" -ge 4 ] || { log "FAIL: expected >=4 insertions"; FAIL=1; }
[ "$EDITS" -ge 1 ]      || { log "FAIL: expected >=1 post_insert_edit (round 1 teach)"; FAIL=1; }
[ "$CANDIDATE" -ge 1 ]  || { log "FAIL: 商品→上屏 not in candidate pool"; FAIL=1; }
[ "$APPLIED" -ge 1 ]    || { log "FAIL: correction_history not applied by polish in later rounds"; FAIL=1; }

# Never leave synthetic learning in the user's live store — the term would
# rank into sound_alike and the example would keep auto-correcting 商品.
sqlite3 "$MEMORY" "DELETE FROM terms WHERE term='商品' AND replacement='上屏';" 2>/dev/null || true
sqlite3 "$MEMORY" "DELETE FROM correction_examples WHERE before_span='商品';" 2>/dev/null || true

if [ "$FAIL" -eq 0 ]; then
  rm -rf "$WORK"
  log "PASS: full learning loop verified end-to-end"
else
  log "logs kept at $WORK"
  exit 1
fi
