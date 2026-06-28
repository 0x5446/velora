# Velora Module Debug Runbook

This runbook keeps Mac debugging modular. Do not start with full E2E when a module is red.

## Entry Point

```bash
cd /Users/alpha/Documents/workspace/velora
scripts/module_debug.sh all
```

Logs are written to:

```text
pocs/out/module-debug/<timestamp>/
```

Each module emits JSON with:

- `ok`: pass/fail
- `summary`: short machine-readable status
- `details`: dependency paths and actionable next steps
- `metrics`: wall-clock latency and useful sizes
- `output`: recognized or generated text when applicable

## Modules

### build

```bash
scripts/module_debug.sh build
```

Checks:

- Swift package builds
- Swift tests pass
- Mac app builds

### environment

```bash
scripts/module_debug.sh environment
```

Checks:

- `whisper-cli` exists
- fast / accurate / fallback Whisper models resolve
- current Accessibility trust state
- Ollama endpoint and model config are visible

### text

```bash
scripts/module_debug.sh text
```

Checks:

- dictation text pipeline can run without audio
- hotword correction runs before translation
- translation mode inserts both `原文` and `译文`
- polish mode returns non-empty text

This uses rule/stub engines by default to isolate product logic from LLM latency.

### asr

```bash
scripts/module_debug.sh asr
```

Checks:

- `WhisperCLIASREngine` can run the project ASR wrapper
- `fast`, `fallback`, and `accurate` model modes all produce non-empty text
- model choice and latency are logged

Optional:

```bash
VELORA_TEST_AUDIO=/path/to/test.wav scripts/module_debug.sh asr
VELORA_ASR_MODES="fast fallback" scripts/module_debug.sh asr
```

### ollama

```bash
scripts/module_debug.sh ollama
```

Checks:

- local Ollama model prewarms
- local polish produces non-empty text
- local translation produces non-empty target text

This is intentionally separate from ASR so LLM latency does not hide ASR failures.

### pasteboard

```bash
scripts/module_debug.sh pasteboard
```

Checks:

- process can write and read `NSPasteboard.general`

This does not require Accessibility.

### accessibility

```bash
scripts/module_debug.sh accessibility
```

Checks:

- current process is trusted for Accessibility events

If this fails, automatic system insertion cannot work. The result can still be copied to the pasteboard.

To trigger the macOS prompt:

```bash
Velora/.build/debug/VeloraDiagnostics accessibility --prompt
```

Then open:

```text
System Settings -> Privacy & Security -> Accessibility
```

Allow the current terminal for CLI probes, and allow `Velora` / `VeloraMacApp` for the app.

### audio

```bash
scripts/module_debug.sh audio
```

Checks:

- microphone permission
- `AVAudioEngine` starts
- a `.caf` file is written with a non-trivial byte size

### insert-focused

```bash
scripts/module_debug.sh insert-focused
```

Manual verification:

1. Put the cursor in any editable text field.
2. Run the command.
3. Wait 3 seconds.
4. Confirm the probe text appears at the cursor.

This checks the isolated system insertion module. It requires Accessibility.

### app-insert-probe

Manual verification:

1. Launch the Mac app.
2. Put the cursor in any editable text field outside the app.
3. Click the menu bar `Velora` item.
4. Choose `插入探针文本`.
5. Confirm the probe text appears at the cursor.

If the floating panel says `已复制，等待授权`, authorize `Velora` / `VeloraMacApp` in:

```text
System Settings -> Privacy & Security -> Accessibility
```

Then quit and relaunch the app before testing again.

### app-settings-sync

Manual verification:

1. Launch the Mac app.
2. In the main window, set:
   - mode: `translate`
   - source: `zh`
   - target: `en`
   - insert: `bilingual`
   - ASR: `fast / base`
3. Confirm the `热键` row shows:

```text
mode=translate zh->en insert=bilingual asr=fast
```

4. Open the menu bar `Velora` menu.
5. Confirm `翻译模式` and `ASR 快速模型` have checkmarks.
6. Switch `Velora -> 润色模式`.
7. Confirm the main window `模式` segmented control changes to `polish`.
8. Switch `Velora -> ASR 兜底模型`.
9. Confirm the main window `ASR` segmented control changes to `fallback / tiny`.

This verifies that the main window, menu bar, and global hotkey path share the same `UserDefaults` runtime settings.

### app-translate-hotkey

Manual verification:

1. Set the main window to `translate`, `zh -> en`, `bilingual`.
2. Put the cursor in any editable text field outside the app.
3. Press `Fn` (or the configured capture shortcut), speak Chinese, then press the same shortcut again.
4. Confirm a review panel appears with source and target text.
5. Click `上屏`, or press the configured capture shortcut once while the review panel is open.
6. Confirm the inserted text contains both labels:

```text
原文:
...
译文:
...
```

If text is copied but not inserted, run `检查无障碍权限` from the app window or `Velora` menu. Rebuilt debug apps may need Accessibility to be toggled off/on once in System Settings.

The `Velora` menu also exposes `确认并上屏` and `取消待确认文本` for this pending review state.
Confirmation should paste into the app that was frontmost when recording stopped, even if the `Velora` menu was used for confirmation.

### app-iterm-hotkey

Manual verification:

1. Launch the Mac app.
2. Put the cursor in iTerm.
3. Press `Fn` (or the configured capture shortcut), speak Chinese, then press the same shortcut again.
4. Confirm `VeloraMacApp` does not crash.
5. Confirm the review panel appears instead of immediate insertion.
6. Confirm it into iTerm.
7. Confirm the inserted text contains both labels in translate/bilingual mode:

```text
原文:
...
译文:
...
```

If iTerm is frontmost, its Accessibility value can include terminal control characters. These must be sanitized before being used as ASR prompt context or as a local model prompt. `LocalProcess` also rejects NUL-containing executable paths and arguments before launching `afconvert` or `whisper-cli`.

## Current Baseline

Last local run:

- build: pass
- environment: pass
- text: pass
- asr fast/base: pass
- asr fallback/tiny: pass
- asr accurate/large-v3-turbo-q5_0: pass
- ollama prewarm/polish/translate: pass
- pasteboard: pass
- audio-record: pass
- accessibility: fail until the relevant process is authorized
- app-insert-probe: manual; verifies the real app process
- app-settings-sync: manual; verifies shared runtime settings
- app-translate-hotkey: manual; verifies bilingual translation insertion
- app-iterm-hotkey: manual; verifies iTerm context sanitization and real insertion

If module probes pass but app insertion fails, first check Accessibility trust for the rebuilt app. If the app crashes only with iTerm frontmost, inspect the latest `~/Library/Logs/DiagnosticReports/VeloraMacApp-*.ips` for `Process.run`, `fileSystemRepresentation`, or `local_process_invalid_argument`.
