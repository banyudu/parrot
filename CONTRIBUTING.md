# Contributing to Parrot

Thanks for your interest in contributing to Parrot! Here's how to get started.

## Development Setup

**Requirements:**
- macOS 14 (Sonoma) or later
- Apple Silicon Mac (M1 or later) — required for MLX
- Xcode 26.3+ with Swift 6.2
- `make` (included with Xcode Command Line Tools)

**Build and run:**

```bash
git clone https://github.com/banyudu/parrot.git
cd parrot
make dev    # debug build + run
```

For a release build with code signing (ad-hoc):

```bash
make build SIGN_IDENTITY=-
```

## Project Structure

```
Sources/Parrot/
├── main.swift          # Entry point
├── AppDelegate.swift   # Central coordinator
├── Config.swift        # User configuration (~/.config/parrot/config.json)
├── StatusBar.swift     # Menu bar UI
├── HotkeyManager.swift # Global hotkey registration
├── AudioRecorder.swift # Microphone capture (AVAudioEngine)
├── ASRBridge.swift     # Speech-to-text (MLX Audio)
├── TextPolisher.swift  # LLM text cleanup (MLX LM)
├── AutoUpdater.swift   # GitHub-based auto-update checker
├── OverlayPanel.swift  # Floating HUD overlay
└── PasteService.swift  # Text output via paste/type
```

## Submitting Changes

1. Fork the repository and create a branch from `main`.
2. Make your changes. Keep commits focused and use conventional prefixes (`feat:`, `fix:`, `chore:`, etc.).
3. Test locally with `make dev`.
4. Open a pull request against `main`.

## Reporting Issues

Use [GitHub Issues](https://github.com/banyudu/parrot/issues) with the provided templates. Include your macOS version, Mac model, and the ASR model you're using.

## Code Style

- Swift, using Swift 5 language mode.
- No SwiftLint or formatter enforced — just follow the existing style.
- Keep files focused: one type per file.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
