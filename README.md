# Parrot

On-device dictation for macOS, powered by [MLX](https://github.com/ml-explore/mlx-swift).

Parrot lives in your menu bar, records speech via a global hotkey, transcribes it locally using Apple Silicon, optionally polishes the text with an LLM, and types the result into whatever app is focused. No cloud, no server — everything runs on your Mac.

## Features

- **100% on-device** — no network required, no data leaves your machine
- **Real-time streaming** — see transcription appear as you speak
- **LLM polish** — automatically fix punctuation, remove filler words, and clean up dictation artifacts
- **Multiple ASR models** — choose from Qwen3-ASR, Parakeet-TDT, or Voxtral-Mini
- **Multilingual** — supports English, Chinese, and auto-detection
- **Menu bar app** — lightweight, stays out of your way
- **Auto-updates** — checks GitHub releases and notifies you of new versions
- **Configurable hotkey** — hold or toggle mode, supports modifier keys and media keys
- **Idle offload** — automatically unloads models after inactivity to reclaim RAM

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon Mac (M1 or later)

## Installation

### Download

Grab the latest DMG from [GitHub Releases](https://github.com/banyudu/parrot/releases/latest), open it, and drag **Parrot** to your Applications folder.

### Build from Source

```bash
git clone https://github.com/banyudu/parrot.git
cd parrot
make build SIGN_IDENTITY=-   # ad-hoc signing
make install                  # copies to /Applications
```

> **Note:** Building from source requires Xcode 26.3+ with Swift 6.2.

## Usage

1. Launch Parrot — it appears as a waveform icon in the menu bar.
2. On first launch, grant **Microphone** and **Accessibility** permissions when prompted.
3. Hold the **Right Command** key (default hotkey) and speak.
4. Release the key — your transcribed text is typed into the active app.

### Menu Bar Options

| Option | Description |
|--------|-------------|
| **Polish** | Toggle LLM text cleanup on/off |
| **Streaming** | Toggle real-time transcription |
| **Language** | Auto, English, or Chinese |
| **Model** | Switch between ASR models |
| **Mode** | Hold (record while held) or Toggle (press to start/stop) |
| **Check for Updates** | Manually check for a newer version |

### Configuration

Settings are stored at `~/.config/parrot/config.json` and can be edited directly or changed via the menu bar.

| Setting | Default | Description |
|---------|---------|-------------|
| `model` | `Qwen3-ASR-0.6B-8bit` | ASR model to use |
| `hotkeyKeyCode` | `0x36` (Right Cmd) | Hotkey key code |
| `hotkeyMode` | `hold` | `hold` or `toggle` |
| `polishEnabled` | `true` | Enable LLM text polishing |
| `polishModel` | `Qwen3-4B-4bit` | LLM model for polishing |
| `streamingEnabled` | `true` | Enable real-time streaming |
| `idleOffloadMinutes` | `5` | Minutes before offloading models (0 = never) |
| `language` | `""` (auto) | Force language: `en`, `zh`, or `""` |
| `copyToClipboard` | `false` | Copy result to clipboard instead of typing |

## Available Models

### ASR (Speech-to-Text)

| Model | Size | Languages | Streaming |
|-------|------|-----------|-----------|
| Qwen3-ASR-0.6B | 4bit/8bit/bf16 | Multilingual | Yes |
| Qwen3-ASR-1.7B | 4bit/8bit/bf16 | Multilingual | Yes |
| Parakeet-TDT-0.6B-v3 | bf16 | English | No |
| Parakeet-TDT-1.1B | bf16 | English | No |
| Voxtral-Mini-4B | 4bit | Multilingual | Yes |

### Polish (LLM)

The default polish model is `Qwen3-4B-4bit`. It corrects punctuation, removes filler words, and cleans up dictation artifacts while preserving the original meaning and language.

## How It Works

1. **Record** — `AVAudioEngine` captures audio from your microphone at 16kHz mono.
2. **Transcribe** — MLX Audio runs the ASR model on-device. In streaming mode, partial results appear in real time.
3. **Polish** (optional) — MLX LM runs a small language model to clean up the raw transcription.
4. **Output** — The result is typed into the focused app via simulated keyboard events, or pasted via clipboard.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## License

[MIT](LICENSE)
