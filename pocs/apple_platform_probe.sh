#!/usr/bin/env bash
set -u

# POC: probe which Apple SDK/framework surfaces can compile on this machine.
# The result guides whether the first implementation can rely on these APIs
# directly, or should define an adapter with fallback backends.

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/out"
mkdir -p "$OUT"
REPORT="$OUT/apple_platform_probe.md"
TMP="$OUT/apple_probe_tmp"
rm -rf "$TMP"
mkdir -p "$TMP"

{
  echo "# Apple Platform Probe"
  echo
  echo "- generated_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "- uname: $(uname -a)"
  echo "- swift: $(xcrun swift --version 2>&1 | head -1 || true)"
  echo "- xcodebuild: $(xcodebuild -version 2>/dev/null | tr '\n' ' ' || true)"
  echo
  echo "## SDK Paths"
  echo
  for sdk in macosx iphoneos iphonesimulator; do
    path="$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null || true)"
    if [[ -n "$path" ]]; then
      echo "- $sdk: $path"
    else
      echo "- $sdk: unavailable"
    fi
  done
  echo
  echo "## Swift Import Checks"
  echo
} > "$REPORT"

check_import() {
  local name="$1"
  local code="$TMP/$name.swift"
  cat > "$code" <<SWIFT
import Foundation
import $name
print("$name import ok")
SWIFT

  if xcrun swiftc "$code" -o "$TMP/$name" >/tmp/velora_probe.log 2>&1; then
    echo "- $name: ok" >> "$REPORT"
  else
    echo "- $name: failed" >> "$REPORT"
    sed 's/^/  /' /tmp/velora_probe.log | head -20 >> "$REPORT"
  fi
}

for framework in Speech NaturalLanguage AppKit InputMethodKit AVFoundation Accessibility FoundationModels Translation; do
  check_import "$framework"
done

{
  echo
  echo "## Interpretation"
  echo
  echo "- ok means the framework is available to the installed macOS SDK/compiler."
  echo "- failed does not necessarily mean the final product cannot use the API; it may require a newer Xcode, a specific deployment target, an entitlement, or iOS-only compilation."
  echo "- Any failed framework must sit behind an adapter in the architecture document."
} >> "$REPORT"

echo "Wrote $REPORT"
