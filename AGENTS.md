# Parrot — Agent Instructions

Comprehensive guide for AI coding assistants working on this project.

## What This Is

macOS menu-bar dictation app (v0.1.2). Records speech via global hotkey, transcribes locally using MLX on Apple Silicon, optionally polishes text with an LLM, and types the result into the focused app. No cloud, no server. Bundle ID: `com.banyudu.parrot`.

## Build

```bash
make dev                       # debug build + run (no app bundle)
make build                     # release build + codesigned Parrot.app
make build SIGN_IDENTITY=-     # release build, ad-hoc signing (for contributors)
make dmg                       # release build → dist/Parrot.dmg
make install                   # build + copy to /Applications
make clean                     # remove all build artifacts
make release VERSION=0.2.0     # bump Info.plist, commit, tag
make grant-accessibility       # open System Settings to grant Accessibility
```

Requires macOS 14+, Apple Silicon, Xcode 26.3+, Swift 6.2. Uses Swift 5 language mode (`swiftLanguageModes: [.v5]`) to avoid strict concurrency enforcement.

Metal shaders from `mlx-swift` are compiled separately by the Makefile into `.build/mlx.metallib` and copied into `Contents/MacOS/`. The `metallib` target is incremental — only rebuilds when `.metal` sources are newer.

Signing identity defaults to `Developer ID Application: Yudu Ban (RYLS8UDY5D)`. Override with `SIGN_IDENTITY=-` for ad-hoc. Ad-hoc signing changes the code hash on every build, which resets macOS Accessibility permission.

## Architecture Overview

```
main.swift → AppDelegate (coordinator)
               ├── AudioRecorder      (AVAudioEngine → 16kHz mono Float32)
               ├── ASRBridge          (MLXAudioSTT → streaming or batch transcription)
               ├── TextPolisher       (MLXLLM → chat-based text cleanup)
               ├── PasteService       (CGEvent keystroke synthesis / clipboard paste)
               ├── HotkeyManager      (Carbon / NSEvent global hotkey)
               ├── OverlayPanel       (floating NSPanel HUD)
               ├── StatusBarController (NSStatusItem menu bar)
               └── AutoUpdater        (GitHub releases API check)
```

`AppDelegate` is the single coordinator — it owns all subsystem instances and manages all state transitions. There is no dependency injection; subsystems are created directly.

## Source Files

| File | Type | Responsibility |
|------|------|----------------|
| `main.swift` | Entry point | Sets `.accessory` policy, creates AppDelegate, runs app loop |
| `AppDelegate.swift` | `final class` | Central orchestration, recording state machine, streaming text assembly, idle offload |
| `Config.swift` | `struct AppConfig: Codable` | All user preferences, model catalogue, hotkey helpers. Persists to `~/.config/parrot/config.json` |
| `ASRBridge.swift` | `final class` | MLX Audio model lifecycle, streaming sessions (Qwen3 only), batch transcription |
| `AudioRecorder.swift` | `final class` | AVAudioEngine tap, hardware→16kHz resampling, WAV file export |
| `TextPolisher.swift` | `final class` | MLX LLM model lifecycle, chat-based polish with hardcoded system prompt |
| `PasteService.swift` | `enum` (namespace) | `paste()` via clipboard+Cmd+V, `typeText()` per-character, `replaceText()` differential, `deleteBackward()` |
| `HotkeyManager.swift` | `final class` | Three modes: Carbon `RegisterEventHotKey`, modifier-only via `.flagsChanged`, media keys via `.systemDefined` |
| `OverlayPanel.swift` | `final class` | Two floating NSPanels: indicator (waveform/dot) + text display |
| `StatusBar.swift` | `final class` | NSStatusItem with full menu (model/language/mode selectors, update check) |
| `AutoUpdater.swift` | `final class` (singleton) | Checks `api.github.com/repos/banyudu/parrot/releases/latest`, semver comparison, NSAlert |

## Key Concurrency Patterns

### sessionGeneration guard

`AppDelegate.sessionGeneration: Int` is the primary stale-callback guard. Incremented in `resetTypingState()` and in `stopAndTranscribe()` before batch re-transcription. Every async callback captures `let gen = sessionGeneration` at dispatch time and checks `self.sessionGeneration == gen` before applying results. **All reads and writes happen on the main thread** — no atomics needed.

### Threading model

- **Main thread**: all AppDelegate state, all UI, all completion callbacks
- **Audio tap thread**: `AudioRecorder`'s tap callback fires here. In streaming mode, calls `asr.feedSamples()` directly (crosses to MLX internals). In pre-buffer mode, acquires `bufferLock` and appends to `preloadAudioBuffer`
- **Serial DispatchQueue** (`ASRBridge.queue`, `.userInitiated`): batch transcription runs here
- **Task.detached**: model loading (ASRBridge, TextPolisher), polish inference, streaming event loop

### Locks

- `AudioRecorder.sampleLock: NSLock` — guards `accumulatedSamples` between tap thread and `stop()` (main)
- `AppDelegate.bufferLock: NSLock` — guards `preloadAudioBuffer` between audio tap thread and main

### Known threading caveat

`ASRBridge.streamSession` is written on main (`cancelStream`) and read on the audio tap thread (`feedSamples`). This is technically a data race under strict concurrency but safe in practice under `.v5` mode since the optional-chain read is pointer-width. Do not enable strict concurrency without addressing this.

## Recording State Machine

### Happy path (streaming, model ready)

```
Hotkey press → startRecording()
  → asr.startStream() creates StreamingInferenceSession
  → recorder.onSamples wired to asr.feedSamples()
  → recorder.start()
  → overlay.showRecording()

Audio tap fires → onSamples → feedSamples → session events
  → .displayUpdate(confirmed, provisional) → handleStreamUpdate()
  → PasteService.replaceText() updates active text field live
  → trySentencePolish() fires LLM on completed sentences

Hotkey release → stopAndTranscribe()
  → asr.cancelStream()
  → sessionGeneration++
  → batch asr.transcribe(full WAV) for final accuracy
  → finishWithText() → PasteService.replaceText() with batch result
  → optional final polish → replaceText() again
  → resetTypingState()
```

### Model-not-ready path (pre-roll buffer)

```
Hotkey press, asr.state != .ready
  → pendingRecordingStart = true
  → onSamples buffers to preloadAudioBuffer under bufferLock
  → asr.start() / polisher.loadModel() if needed

asr.onStateChange → .ready, pendingRecordingStart == true
  → activateLiveASR()
  → drains buffered samples into feedSamples
  → wires live onSamples callback
```

### Batch-only path (non-streaming model)

```
Hotkey press → recorder.onSamples = nil
Hotkey release → recorder.stop() returns WAV URL
  → asr.transcribe(audioPath) on serial queue
  → optional polish → PasteService.paste()
```

## Text Injection

`PasteService` has two strategies:

1. **Paste** (`paste()`): snapshot clipboard → write text → delay 50ms → synthesize Cmd+V → delay 150ms → restore clipboard (skipped if `copyToClipboard` or clipboard changed)
2. **Type** (`typeText()`, `replaceText()`, `deleteBackward()`): per-character `CGEvent` synthesis. `replaceText` computes common prefix, deletes only the divergent suffix via backspace events, then types the new suffix.

Both require Accessibility permission. `ensureAccessibility()` calls `AXIsProcessTrustedWithOptions` with prompt only if not already trusted.

## Config Fields

All fields in `AppConfig`, persisted to `~/.config/parrot/config.json`:

| Field | Type | Default | Effect |
|-------|------|---------|--------|
| `model` | String | `mlx-community/Qwen3-ASR-0.6B-8bit` | ASR model HuggingFace repo ID |
| `hotkeyKeyCode` | Int | `0x36` (Right ⌘) | Key code for hotkey |
| `hotkeyModifiers` | Int | `0` | Carbon modifier mask |
| `hotkeyMode` | String | `"hold"` | `"hold"` or `"toggle"` |
| `hotkeyIsMediaKey` | Bool | `false` | Use NX media key path |
| `polishEnabled` | Bool | `true` | Run LLM text cleanup |
| `polishModel` | String | `mlx-community/Qwen3-4B-4bit` | LLM repo ID |
| `streamingEnabled` | Bool | `true` | Live streaming transcription |
| `idleOffloadMinutes` | Int | `5` | Auto-offload models after N minutes (0=never) |
| `language` | String | `""` | Force language hint (empty=auto, `en`, `zh`) |
| `copyToClipboard` | Bool | `false` | Keep result on clipboard |
| `useHFMirror` | Bool | auto | Use hf-mirror.com (default true in CN region) |
| `modelVariants` | [String:String] | `[:]` | Per-family last-selected variant |

## Model Catalogue

### ASR models (in `AppConfig.modelFamilies`)

| Family | Kind | Variants | Streaming | Languages |
|--------|------|----------|-----------|-----------|
| Qwen3-ASR-0.6B | `.qwen3ASR` | 4bit, 8bit, bf16 | Yes | Multilingual |
| Qwen3-ASR-1.7B | `.qwen3ASR` | 4bit, 8bit, bf16 | Yes | Multilingual |
| Parakeet-TDT-0.6B-v3 | `.parakeet` | bf16 | No | English |
| Parakeet-TDT-1.1B | `.parakeet` | tdt | No | English |
| Voxtral-Mini-4B | `.voxtralRealtime` | 4bit | Yes | Multilingual |

**Partially prepared kinds** (cases in `ASRBridge` load switch but no `ModelFamily` entries): `.glmASR`, `.graniteSpeech`, `.cohereTranscribe`. These are unreachable via the UI.

### Polish model

Default `Qwen3-4B-4bit`. System prompt instructs: clean punctuation, remove fillers, preserve meaning and language, no translation. Uses `/no_think` to suppress thinking mode. Strips `<think>…</think>` from output.

## Dependencies

| Package | Pin | Products | Role |
|---------|-----|----------|------|
| `mlx-audio-swift` (Blaizzy) | commit `6f0d9ad` | `MLXAudioSTT`, `MLXAudioCore` | All ASR model types, streaming sessions, audio loading |
| `mlx-swift-lm` (ml-explore) | `>= 2.31.0` | `MLXLLM`, `MLXLMCommon` | LLM model factory, inference, chat generation |
| Carbon (system) | — | `RegisterEventHotKey` | Low-level hotkey API |
| AVFoundation (system) | — | `AVAudioEngine`, `AVAudioConverter` | Mic capture, format conversion |

## CI/CD

- **`ci.yml`**: runs on push/PR to `main`. Builds release + app bundle with ad-hoc signing on `macos-15`.
- **`release.yml`**: triggered by `v*` tags. Imports signing cert from secrets, builds DMG, notarizes (if `APPLE_ID` secret set), staples, creates GitHub release with DMG attached.
- **`pages.yml`**: deploys `docs/` to GitHub Pages on push to `main`.

Required secrets for release: `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PWD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`.

## Error Handling Patterns

- **ASR load failure**: state → `.error(msg)` → status bar shows error text; pending recording start drains buffer; pending transcription removes temp file and shows error overlay
- **Audio recorder**: `start()` throws → caught in `startRecording()`, logged via NSLog, overlay shows error
- **Batch transcription failure**: `.failure` → temp WAV deleted, overlay shows error (or backspace streamed text + error)
- **Polish failure**: always falls back to original text — never fails the caller
- **AutoUpdater**: network errors show alert only in non-silent mode; HTTP 404 treated as "up to date"
- **PasteService**: `CGEvent` creation failures silently skipped per character

## Conventions

- Swift 5 language mode (avoids strict concurrency enforcement)
- One type per file, `final class` for all classes
- No SwiftLint or formatter — follow existing style
- Conventional commit prefixes: `feat:`, `fix:`, `chore:`
- `sessionGeneration` guards all async callbacks — always capture `let gen = sessionGeneration` before async work and check on completion
- All UI and state mutations on main thread
- `NSLog` for error logging (no logging framework)
- Entitlements: hardened runtime, audio input, apple events, network client
