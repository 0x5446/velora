<div align="center">

<img src="Apps/VeloraMac/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Velora icon" />

# Velora

**Press `Fn`. Speak. Your words land at the cursor — polished, and translated if you want.**

100% on-device voice dictation for macOS. No cloud, no accounts, no audio ever leaving your Mac.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange)](Velora/Package.swift)
[![Local-first](https://img.shields.io/badge/inference-100%25%20local-brightgreen)](#privacy)
[![License](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

[English](README.md) · [简体中文](README.zh-CN.md)

</div>

---

<p align="center">
  <img src="docs/assets/review-panel.png" width="640" alt="Translation review card" /><br/>
  <em>Translate mode: speak Chinese, review the bilingual card, press ⌘⏎ — English lands at your cursor.</em>
</p>

<p align="center">
  <img src="docs/assets/hud-listening.png" width="420" alt="Recording HUD" /><br/>
  <em>The quiet bottom-center HUD while listening — never steals focus, never steals clicks.</em>
</p>

## Why Velora

Most dictation tools make you choose between quality and privacy. Velora refuses the trade:

- **Truly local.** ASR, text polishing, and translation all run on your machine. Unplug the network and everything still works.
- **System-wide.** A menu-bar utility that types into *any* app — your editor, browser, chat — right at the cursor.
- **One key.** Tap `Fn` to start, tap again to finish. Velora owns the key end-to-end via a CGEventTap, so the macOS input-source switcher never fights you.
- **Polished output, not raw transcripts.** Every utterance passes through a tiered compose layer: deterministic cleanup, context-constrained correction, app-category formatting, then local-LLM polish when it beats the deadline. Preservation guards reject rewrites that lose numbers, URLs, code identifiers, learned terms, or the source language.

## How it works

Two user-facing modes, one pipeline:

```
Dictate  (Fn):    ASR + constrained correction → app-aware compose { polished }         → guards → insert
Translate (Fn⇧):  ASR + constrained correction → app-aware compose { polished, target } → guards → review → insert
```

| Stage | Engine | Notes |
|---|---|---|
| Speech-to-text | [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) via a resident `sherpa-onnx` sidecar | Model loaded once, stays warm — ~18× faster than spawning per utterance. `whisper.cpp` and Apple Speech available as alternates. |
| Polish / translate | Local LLM via [Ollama](https://ollama.com) (default `qwen3:8b`) | Single compose call; translation is an extra output field, not an extra hop. Formatting is routed by app category (developer, chat, email, document, other). Falls back to rule cleanup on timeout, invalid JSON, language mismatch, or preservation-guard failure. |
| Local learning | SQLite memory + correction journal | Source-side review edits and edits made shortly after direct insertion become local feedback. Pinyin-gated correction examples and promoted terms can affect the next matching utterance. |

Latency is treated as a product feature: recording-time preparation, resident models, and a hard compose deadline keep tap-to-text fast. See [`docs/PRODUCT_TECH_DESIGN.md`](docs/PRODUCT_TECH_DESIGN.md) for the full architecture.

### Adaptive, but bounded

Velora currently evolves through a conservative local feedback loop, not online model training:

- it observes only the span Velora just inserted, for a bounded window, and never learns from secure fields or blocked apps;
- correction examples are retrieved only when their pronunciation occurs in the new utterance; automatically learned term pairs need evidence from two separate sessions before promotion;
- punctuation, whitespace, and line-break edits are retained as style signals, but per-app statistical style learning and automatic LoRA are intentionally not active yet;
- the fine-tuning exporter uses the exact shipped system prompt, app-format input field, and `{"polished": ...}` JSON contract so future offline training cannot silently drift from production.

The competitor/academic review behind this design is in [`docs/VOICE_DICTATION_BEST_PRACTICES.md`](docs/VOICE_DICTATION_BEST_PRACTICES.md); the implemented feedback loop is documented in [`docs/LEARNING_PIPELINE.md`](docs/LEARNING_PIPELINE.md).

## Getting started

### Requirements

- macOS 14+ (Apple Silicon recommended), Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [Ollama](https://ollama.com) with a chat model: `ollama pull qwen3:8b` (override with `VELORA_OLLAMA_MODEL`)
- Python 3 with a small venv for the ASR sidecar

### 1. Clone & fetch the ASR model

```bash
git clone https://github.com/0x5446/velora.git
cd velora

# SenseVoice int8 ONNX bundle (model.int8.onnx + tokens.txt) from sherpa-onnx releases:
mkdir -p Models/sensevoice && cd Models/sensevoice
curl -LO https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2
tar xjf sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2 --strip-components=1
python3 -m venv .venv && .venv/bin/pip install sherpa-onnx soundfile numpy
cd ../..
```

The app looks for `Models/sensevoice/` under the repo root (also `~/workspace/velora/` or `~/Library/Application Support/Velora/`).

### 2. Generate & build

```bash
xcodegen generate
xcodebuild -project Velora.xcodeproj -scheme Velora -configuration Debug build
```

> **Signing note:** `project.yml` pins a development team for stable TCC grants. Use the normal signed command above for any runnable local build. Do **not** run `CODE_SIGNING_ALLOWED=NO` against the same DerivedData path as the installed/running debug app: it overwrites the signed bundle with an ad-hoc build and macOS will stop recognizing its Accessibility grant. If CI needs a no-sign compile check, isolate it with a separate `-derivedDataPath`.

### 3. First-run setup

1. Launch Velora — it lives in the menu bar (waveform icon), no Dock presence.
2. Grant **Microphone** (prompted) and **Accessibility** (System Settings → Privacy & Security → Accessibility) — required for the `Fn` event tap and cursor insertion.
3. Recommended: set System Settings → Keyboard → *"Press 🌐 key to"* → **Do Nothing**, so the system input-source switcher stays out of the way. Equivalent:
   ```bash
   defaults write com.apple.HIToolbox AppleFnUsageType -int 0
   ```

### Daily driving

| Action | Key |
|---|---|
| Start / finish dictation | `Fn` |
| Start / finish translate-mode dictation | `Fn ⇧` |
| Cancel recording | `Esc` |
| Review card: confirm preferred side | `⌘⏎` (or `Fn`) |
| Review card: re-translate after editing source | `⌘R` |
| Review card: dismiss | `Esc` |

Hotkeys are remappable in Settings (⌥Space fallback available). Translation target language, insert side, and developer diagnostics live there too.

## Privacy

- Audio is captured only while you're actively dictating, processed in memory, and never uploaded — there is no server.
- The mic-in-use indicator in the menu bar is macOS's own; Velora never records outside an explicit `Fn` session.
- The only network dependency is `localhost` (Ollama).
- Learning feedback stays under `~/Library/Application Support/Velora/`. Audio retention for future experiments is a separate opt-in setting, off by default, with a 2 GB local ring-buffer quota.

## Project layout

```
Apps/VeloraMac/        macOS menu-bar app (HUD, review card, settings, Fn event tap)
Apps/VeloraiOS/        iOS prototype harness
Apps/VeloraKeyboard/   iOS custom keyboard extension (bridge insertion)
Velora/                Swift package: pipeline, engines, design system, storage
docs/                  product/tech design, model strategy, tuning reports
scripts/               SenseVoice sidecar, icon generator, eval harnesses
pocs/                  early proof-of-concept spikes
```

UI follows a small warm "tech-retro" design system (cream paper, ink text, clay accent, serif headings) defined in [`Velora/Sources/Velora/DesignSystem/`](Velora/Sources/Velora/DesignSystem/) — one token file drives Mac, iOS, and the keyboard extension.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Fn` also opens the macOS input-source switcher | Set *"Press 🌐 key to"* → Do Nothing (see setup step 3) |
| `Fn` does nothing at all | Accessibility not granted (or the app was rebuilt ad-hoc) — rebuild with the configured Apple Development identity, re-toggle Velora in System Settings if needed, then relaunch |
| Output is rough / translation missing | Ollama not running or model missing — Velora degrades to rule-based cleanup; run `ollama serve` & `ollama pull qwen3:8b` |
| "需要无障碍权限" in the menu | Same as above — grant Accessibility, relaunch |

## Roadmap

- [ ] Notarized release builds (hardened runtime re-enabled)
- [ ] iOS keyboard: dictation directly inside the extension
- [ ] Pluggable ASR/LLM engine matrix (MLX, llama.cpp server)
- [ ] Per-app statistical style learning and explicit user overrides
- [ ] Offline LoRA evaluation and opt-in rollout (no automatic online training)

## Contributing

Issues and PRs welcome. Start with [`docs/PRODUCT_TECH_DESIGN.md`](docs/PRODUCT_TECH_DESIGN.md) for the architecture contract, and keep the two-mode pipeline language (`compose { polished, target }`) — see the docs for why. Run `xcodegen generate` after touching `project.yml`; the generated `.xcodeproj` is committed.

## License

[MIT](LICENSE)
