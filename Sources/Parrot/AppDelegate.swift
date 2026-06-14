import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = AppConfig.load()
    private let recorder = AudioRecorder()
    private let overlay = OverlayPanel()
    private let asr = ASRBridge()
    private let hotkey = HotkeyManager()
    private let polisher = TextPolisher()
    private var statusBar: StatusBarController!

    private var levelTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(delegate: self)

        asr.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle:
                self.statusBar.setStatus("Idle")
                self.statusBar.setLoading(false)
            case .downloading(let pct):
                self.statusBar.setStatus("Downloading ASR... \(Int(pct))%")
                self.statusBar.setLoading(true)
            case .loading:
                self.statusBar.setStatus("Loading ASR model...")
                self.statusBar.setLoading(true)
            case .ready:
                self.updateStatusText()
            case .error(let msg):
                self.statusBar.setStatus("ASR error: \(msg)")
                self.statusBar.setLoading(false)
            }
        }

        polisher.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .loading:
                self.statusBar.setStatus("Loading polish model...")
            case .ready:
                self.updateStatusText()
            case .error(let msg):
                NSLog("[Polish] Model error: %@", msg)
                self.updateStatusText()
            case .idle:
                break
            }
        }

        PasteService.ensureAccessibility()
        bindHotkey()

        asr.start(model: config.model, useHFMirror: config.useHFMirror)
        if config.polishEnabled {
            polisher.loadModel(config.polishModel, useHFMirror: config.useHFMirror)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        asr.waitForIdle {
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if recorder.isRecording { _ = recorder.stop() }
        hotkey.unregister()
        asr.stop()
        polisher.unload()
    }

    // MARK: - Recording

    func toggleRecording() {
        if recorder.isRecording {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard asr.state == .ready else {
            overlay.showError()
            return
        }
        do {
            try recorder.start()
            overlay.showRecording()
            statusBar.setRecording(true)
            startLevelFeed()
        } catch {
            overlay.showError()
            NSLog("[Rec] %@", error.localizedDescription)
        }
    }

    private func stopAndTranscribe() {
        stopLevelFeed()

        guard let url = recorder.stop() else {
            overlay.hide()
            statusBar.setRecording(false)
            return
        }
        statusBar.setRecording(false)
        overlay.showProcessing()

        let lang = config.language.isEmpty ? nil : config.language

        asr.transcribe(audioPath: url.path, language: lang) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.overlay.hide()
                } else if self.config.polishEnabled && self.polisher.state == .ready {
                    self.polisher.polish(trimmed) { polished in
                        self.overlay.showDone()
                        PasteService.paste(polished, copyToClipboard: self.config.copyToClipboard)
                    }
                } else {
                    self.overlay.showDone()
                    PasteService.paste(trimmed, copyToClipboard: self.config.copyToClipboard)
                }
            case .failure:
                self.overlay.showError()
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Audio level feed

    private func startLevelFeed() {
        stopLevelFeed()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.overlay.audioLevel = self.recorder.level
        }
    }

    private func stopLevelFeed() {
        levelTimer?.invalidate()
        levelTimer = nil
        overlay.audioLevel = 0
    }

    // MARK: - Model

    func selectModel(_ modelID: String) {
        guard modelID != config.model else { return }
        config.model = modelID
        if let family = AppConfig.modelFamilies.first(where: { $0.hasVariant(modelID) }),
           let variant = family.variant(of: modelID) {
            config.modelVariants[family.name] = variant
        }
        config.save()
        asr.reload(model: modelID, useHFMirror: config.useHFMirror)
        statusBar.rebuildMenu()
    }

    // MARK: - Polish

    func togglePolish() {
        config.polishEnabled.toggle()
        config.save()
        if config.polishEnabled && polisher.state == .idle {
            polisher.loadModel(config.polishModel, useHFMirror: config.useHFMirror)
        } else if !config.polishEnabled {
            polisher.unload()
        }
        statusBar.rebuildMenu()
        updateStatusText()
    }

    private func updateStatusText() {
        guard asr.state == .ready else { return }
        let polishTag: String
        if config.polishEnabled {
            polishTag = polisher.state == .ready ? " + polish" : " (polish loading...)"
        } else {
            polishTag = ""
        }
        statusBar.setStatus("Ready — \(config.modelLabel)\(polishTag)")
        statusBar.setLoading(false)
    }

    // MARK: - Hotkey

    private func bindHotkey() {
        let isHold = config.hotkeyMode == "hold"

        let onPressed: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if isHold {
                    if !self.recorder.isRecording { self.toggleRecording() }
                } else {
                    self.toggleRecording()
                }
            }
        }

        let onReleased: (() -> Void)? = isHold ? { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.recorder.isRecording { self.toggleRecording() }
            }
        } : nil

        if config.hotkeyIsMediaKey {
            hotkey.registerMediaKey(
                nxKeyType: config.hotkeyKeyCode,
                onPressed: onPressed,
                onReleased: onReleased
            )
        } else {
            hotkey.register(
                keyCode: UInt32(config.hotkeyKeyCode),
                modifiers: UInt32(config.hotkeyModifiers),
                onPressed: onPressed,
                onReleased: onReleased
            )
        }
    }

    // MARK: - Hotkey mode

    func toggleHotkeyMode() {
        config.hotkeyMode = config.hotkeyMode == "hold" ? "toggle" : "hold"
        config.save()
        hotkey.unregister()
        bindHotkey()
        statusBar.rebuildMenu()
    }

    // MARK: - Accessors

    var currentConfig: AppConfig { config }
}
