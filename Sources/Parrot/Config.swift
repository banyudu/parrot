import AppKit
import Foundation

struct AppConfig: Codable {
    var model: String = "mlx-community/Qwen3-ASR-0.6B-8bit"
    var hotkeyKeyCode: Int = 0x36        // Right Command
    var hotkeyModifiers: Int = 0
    var hotkeyMode: String = "hold"      // "toggle" or "hold"
    var hotkeyIsMediaKey: Bool = false
    var language: String = ""            // empty = auto-detect
    var copyToClipboard: Bool = false
    var useHFMirror: Bool = AppConfig.defaultUseHFMirror
    var modelVariants: [String: String] = [:]

    // Polish settings
    var polishEnabled: Bool = true
    var polishModel: String = "mlx-community/Qwen3-4B-4bit"

    static let defaultUseHFMirror: Bool = {
        let region = Locale.current.region?.identifier ?? ""
        return ["CN"].contains(region)
    }()

    // MARK: - Persistence

    private static let configDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/parrot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let configFile: URL = configDir.appendingPathComponent("config.json")

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configFile),
              var config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }

        if !modelFamilies.contains(where: { $0.hasVariant(config.model) }) {
            config.model = AppConfig().model
            config.save()
        }

        return config
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.configFile, options: .atomic)
    }

    // MARK: - Model families

    struct ModelFamily {
        let name: String
        let description: String
        let kind: Kind
        let variants: [Variant]
        let defaultVariant: String

        struct Variant: Hashable {
            let name: String
            let repoId: String
        }

        enum Kind {
            case qwen3ASR
            case parakeet
            case voxtralRealtime
            case glmASR
            case graniteSpeech
            case cohereTranscribe
        }

        var supportsLanguage: Bool {
            switch kind {
            case .qwen3ASR, .cohereTranscribe: return true
            default: return false
            }
        }

        func modelId(_ variantName: String) -> String {
            variants.first { $0.name == variantName }?.repoId
                ?? variants.first { $0.name == defaultVariant }?.repoId
                ?? variants[0].repoId
        }

        func hasVariant(_ modelId: String) -> Bool {
            variants.contains { $0.repoId == modelId }
        }

        func variant(of modelId: String) -> String? {
            variants.first { $0.repoId == modelId }?.name
        }
    }

    static let modelFamilies: [ModelFamily] = [
        ModelFamily(
            name: "Qwen3-ASR-0.6B",
            description: "Multilingual, fast",
            kind: .qwen3ASR,
            variants: [
                .init(name: "4bit", repoId: "mlx-community/Qwen3-ASR-0.6B-4bit"),
                .init(name: "8bit", repoId: "mlx-community/Qwen3-ASR-0.6B-8bit"),
                .init(name: "bf16", repoId: "mlx-community/Qwen3-ASR-0.6B-bf16"),
            ],
            defaultVariant: "8bit"
        ),
        ModelFamily(
            name: "Qwen3-ASR-1.7B",
            description: "Multilingual, accurate",
            kind: .qwen3ASR,
            variants: [
                .init(name: "4bit", repoId: "mlx-community/Qwen3-ASR-1.7B-4bit"),
                .init(name: "8bit", repoId: "mlx-community/Qwen3-ASR-1.7B-8bit"),
                .init(name: "bf16", repoId: "mlx-community/Qwen3-ASR-1.7B-bf16"),
            ],
            defaultVariant: "8bit"
        ),
        ModelFamily(
            name: "Parakeet-TDT-0.6B",
            description: "English, very fast",
            kind: .parakeet,
            variants: [
                .init(name: "v3", repoId: "mlx-community/parakeet-tdt-0.6b-v3"),
            ],
            defaultVariant: "v3"
        ),
        ModelFamily(
            name: "Parakeet-TDT-1.1B",
            description: "English, accurate",
            kind: .parakeet,
            variants: [
                .init(name: "tdt", repoId: "mlx-community/parakeet-tdt-1.1b"),
            ],
            defaultVariant: "tdt"
        ),
        ModelFamily(
            name: "Voxtral-Mini-4B",
            description: "Multilingual streaming",
            kind: .voxtralRealtime,
            variants: [
                .init(name: "4bit", repoId: "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"),
            ],
            defaultVariant: "4bit"
        ),
    ]

    var modelFamily: ModelFamily? {
        Self.modelFamilies.first { $0.hasVariant(model) }
    }

    var modelVariant: String {
        modelFamily?.variant(of: model) ?? "8bit"
    }

    var modelLabel: String {
        guard let family = modelFamily else { return model }
        return "\(family.name) (\(modelVariant))"
    }

    func variant(for family: ModelFamily) -> String {
        modelVariants[family.name] ?? family.defaultVariant
    }

    var hotkeyDisplayString: String {
        if hotkeyIsMediaKey {
            return nxKeyTypeToString(hotkeyKeyCode)
        }
        var parts: [String] = []
        if hotkeyModifiers & 0x0100 != 0 { parts.append("⌘") }
        if hotkeyModifiers & 0x0200 != 0 { parts.append("⇧") }
        if hotkeyModifiers & 0x0800 != 0 { parts.append("⌥") }
        if hotkeyModifiers & 0x1000 != 0 { parts.append("⌃") }
        parts.append(keyCodeToString(UInt16(hotkeyKeyCode)))
        return parts.joined()
    }
}

// MARK: - Key code helpers

let kModifierKeyCodes: Set<UInt16> = [
    0x36, 0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
]

func keyCodeToString(_ keyCode: UInt16) -> String {
    let map: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H",
        0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
        0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
        0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3",
        0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9",
        0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
        0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M",
        0x2F: ".", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x24: "↩",
        0x35: "⎋",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x36: "Right ⌘", 0x37: "Left ⌘",
        0x38: "Left ⇧", 0x3C: "Right ⇧",
        0x3A: "Left ⌥", 0x3D: "Right ⌥",
        0x3B: "Left ⌃", 0x3E: "Right ⌃",
        0x3F: "Fn",
    ]
    return map[keyCode] ?? String(format: "0x%02X", keyCode)
}

func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
    switch keyCode {
    case 0x36, 0x37: return .command
    case 0x38, 0x3C: return .shift
    case 0x3A, 0x3D: return .option
    case 0x3B, 0x3E: return .control
    case 0x3F:       return .function
    default:         return nil
    }
}

func nxKeyTypeToString(_ nxKey: Int) -> String {
    switch nxKey {
    case 7:  return "Mute"
    case 16: return "Play/Pause"
    case 23: return "Spotlight"
    case 30: return "Dictation"
    default: return "Special Key \(nxKey)"
    }
}

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
    var mods = 0
    if flags.contains(.command) { mods |= 0x0100 }
    if flags.contains(.shift)   { mods |= 0x0200 }
    if flags.contains(.option)  { mods |= 0x0800 }
    if flags.contains(.control) { mods |= 0x1000 }
    return mods
}
