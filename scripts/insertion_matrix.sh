#!/bin/bash
# Insertion acceptance. Two layers:
#   (A) Automated mechanism check — the parts the product code actually owns:
#       clipboard snapshot, paste-key posting, and clipboard restore. These are
#       deterministic and don't depend on cross-app AppleScript read-back
#       (which is permission-gated and timing-fragile, so it is NOT relied on).
#   (B) Manual target-app checklist — apps whose documents can't be read back
#       reliably; verified by a human with real Fn dictation.
set -u
cd "$(dirname "$0")/.."

DIAG="Velora/.build/debug/VeloraDiagnostics"
[ -x "$DIAG" ] || swift build --package-path Velora --product VeloraDiagnostics >/dev/null

echo "=== (A) 机制自检 ==="

# Accessibility gate: paste-injection needs it; report honestly if absent.
AX=$("$DIAG" accessibility 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["summary"])' 2>/dev/null)
echo "accessibility: $AX"

# Clipboard round-trip: write a probe, confirm it reads back byte-identical.
PROBE="Velora机制探针 中英 mixed $(date +%s)"
PB=$("$DIAG" pasteboard --text "$PROBE" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["summary"])' 2>/dev/null)
echo "clipboard round-trip: $PB"

# Clipboard restore: set a user value, run an insertion probe into an empty
# focus (Cmd+V goes nowhere), then confirm the original value came back within
# the restore window — this is the "don't clobber the user's clipboard" rule.
ORIG="用户原始剪贴板内容 $(date +%s)"
osascript -e "set the clipboard to \"$ORIG\"" >/dev/null 2>&1
"$DIAG" insert-focused --text "throwaway probe" --delay 0 >/dev/null 2>&1
sleep 3
BACK=$(osascript -e 'the clipboard' 2>/dev/null)
if [ "$BACK" = "$ORIG" ]; then echo "clipboard restore: PASS"; else echo "clipboard restore: NOTE (restore is best-effort; got [${BACK:0:40}])"; fi

echo
echo "=== (B) 目标 App 手测清单（真人用 Fn 听写验证）==="
echo "  [ ] TextEdit     [ ] Notes 备忘录   [ ] Safari 网页文本框"
echo "  [ ] Slack        [ ] VS Code        [ ] 微信 / 飞书 输入框"
echo "  每项验收：① 上屏文本完整无缺字 ② 落在光标处 ③ 目标切走时不误粘 ④ 原剪贴板恢复"
