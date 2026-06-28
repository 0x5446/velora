#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT/Velora"
OUT_DIR="${VELORA_DEBUG_OUT:-$ROOT/pocs/out/module-debug/$(date +%Y%m%d-%H%M%S)}"
DIAG="$PACKAGE_DIR/.build/debug/VeloraDiagnostics"
MAC_APP_SCHEME="Velora"

mkdir -p "$OUT_DIR"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
  cat <<'EOF'
Usage:
  scripts/module_debug.sh all
  scripts/module_debug.sh build
  scripts/module_debug.sh environment
  scripts/module_debug.sh text
  scripts/module_debug.sh asr
  scripts/module_debug.sh ollama
  scripts/module_debug.sh pasteboard
  scripts/module_debug.sh accessibility
  scripts/module_debug.sh audio
  scripts/module_debug.sh ios-build
  scripts/module_debug.sh insert-focused

Environment:
  VELORA_TEST_AUDIO=/path/to/test.wav
  VELORA_ASR_MODES="fast fallback accurate"
  VELORA_DEBUG_OUT=/tmp/velora-debug
EOF
}

log() {
  printf '%s\n' "$*"
}

record_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log "PASS $1"
}

record_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log "FAIL $1"
}

record_skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  log "SKIP $1"
}

run_logged() {
  local name="$1"
  shift
  local log_file="$OUT_DIR/$name.log"
  log "==> $name"
  log "    $*" >"$log_file"
  if "$@" >>"$log_file" 2>&1; then
    record_pass "$name"
    return 0
  else
    local status=$?
    record_fail "$name (exit=$status, log=$log_file)"
    tail -n 30 "$log_file" || true
    return "$status"
  fi
}

build_diagnostics() {
  run_logged swift-build-diagnostics \
    swift build --package-path "$PACKAGE_DIR" --product VeloraDiagnostics
}

build_package_tests() {
  run_logged swift-test \
    swift test --package-path "$PACKAGE_DIR"
}

build_mac_app() {
  run_logged xcodebuild-mac \
    xcodebuild -project "$ROOT/Velora.xcodeproj" -scheme "$MAC_APP_SCHEME" -destination "platform=macOS" build
}

build_ios_app() {
  run_logged xcodebuild-ios-simulator \
    xcodebuild -project "$ROOT/Velora.xcodeproj" -scheme "VeloraiOS" -destination "generic/platform=iOS Simulator" build
}

ensure_diag() {
  if [[ -x "$DIAG" ]]; then
    return 0
  fi
  build_diagnostics
}

run_json_probe() {
  local name="$1"
  shift
  local log_file="$OUT_DIR/$name.json"
  log "==> $name"
  if "$DIAG" "$@" >"$log_file" 2>&1; then
    record_pass "$name"
    return 0
  else
    local status=$?
    record_fail "$name (exit=$status, log=$log_file)"
    cat "$log_file" || true
    return "$status"
  fi
}

module_build() {
  build_diagnostics
  build_package_tests
  build_mac_app
}

module_environment() {
  ensure_diag || return 1
  run_json_probe environment environment
}

module_text() {
  ensure_diag || return 1
  run_json_probe text-translate text \
    --mode translate \
    --text "明天上午十点我和 Alex 开会，帮我确认一下 agenda" \
    --source zh \
    --target en \
    --insert-policy bilingual
  run_json_probe text-polish text \
    --mode polish \
    --text "  please   confirm the agenda  " \
    --source en
  run_json_probe text-hotword text \
    --mode translate \
    --text "The biggest risk is prom injection in velora when we keep long term context" \
    --source en \
    --target zh \
    --insert-policy bilingual
}

find_test_audio() {
  if [[ -n "${VELORA_TEST_AUDIO:-}" && -f "$VELORA_TEST_AUDIO" ]]; then
    printf '%s\n' "$VELORA_TEST_AUDIO"
    return 0
  fi

  local candidates=(
    "/opt/homebrew/Cellar/whisper-cpp/1.9.1/share/whisper-cpp/jfk.wav"
    "/opt/homebrew/share/whisper-cpp/jfk.wav"
    "/usr/local/share/whisper-cpp/jfk.wav"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  local generated="$OUT_DIR/generated-asr-sample.aiff"
  if command -v say >/dev/null 2>&1; then
    say -v Alex -o "$generated" "Ask not what your country can do for you. Ask what you can do for your country." >/dev/null 2>&1
    if [[ -s "$generated" ]]; then
      printf '%s\n' "$generated"
      return 0
    fi
  fi

  return 1
}

module_asr() {
  ensure_diag || return 1
  local audio
  if ! audio="$(find_test_audio)"; then
    record_skip "asr (no test audio found; set VELORA_TEST_AUDIO=/path/to.wav)"
    return 0
  fi

  local modes="${VELORA_ASR_MODES:-fast fallback accurate}"
  local mode
  for mode in $modes; do
    run_json_probe "asr-$mode" asr --audio "$audio" --source en --asr-mode "$mode"
  done
}

module_ollama() {
  ensure_diag || return 1
  run_json_probe ollama-prewarm ollama --task prewarm
  run_json_probe ollama-polish ollama \
    --task polish \
    --text "明天上午十点我和 Alex 开会 帮我确认一下 agenda"
  run_json_probe ollama-translate ollama \
    --task translate \
    --text "明天上午十点我和 Alex 开会，帮我确认一下 agenda。" \
    --source zh \
    --target en
}

module_pasteboard() {
  ensure_diag || return 1
  run_json_probe pasteboard pasteboard --text "Velora pasteboard module $(date +%s)"
}

module_accessibility() {
  ensure_diag || return 1
  run_json_probe accessibility accessibility
}

module_audio() {
  ensure_diag || return 1
  run_json_probe audio-record audio-record --seconds "${VELORA_AUDIO_SECONDS:-2}"
}

module_ios_build() {
  build_ios_app
}

module_insert_focused() {
  ensure_diag || return 1
  log "请先把光标放进一个可编辑文本框。3 秒后脚本会尝试粘贴探针文本。"
  run_json_probe insert-focused insert-focused --delay 3 --text "Velora focused insert module $(date +%s)"
}

summary() {
  log ""
  log "Logs: $OUT_DIR"
  log "Summary: pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"
}

main() {
  local command="${1:-all}"
  case "$command" in
    all)
      module_build || true
      module_environment || true
      module_text || true
      module_asr || true
      module_ollama || true
      module_pasteboard || true
      module_accessibility || true
      ;;
    build) module_build ;;
    environment) module_environment ;;
    text) module_text ;;
    asr) module_asr ;;
    ollama) module_ollama ;;
    pasteboard) module_pasteboard ;;
    accessibility) module_accessibility ;;
    audio) module_audio ;;
    ios-build) module_ios_build ;;
    insert-focused) module_insert_focused ;;
    help|--help|-h) usage; exit 0 ;;
    *)
      usage
      exit 2
      ;;
  esac

  summary
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
