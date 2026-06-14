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
    private var isStreaming = false

    private var displayedText = ""
    private var confirmedRaw = ""
    private var polishedPrefix = ""
    private var lastPolishBoundary = 0
    private var isPolishing = false

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
        if recorder.isRecording { recorder.stop() }
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
            if asr.supportsStreaming {
                let lang = config.language.isEmpty ? nil : config.language
                resetTypingState()

                asr.startStream(language: lang) { [weak self] confirmed, provisional in
                    self?.handleStreamUpdate(confirmed: confirmed, provisional: provisional)
                }
                recorder.onSamples = { [weak self] samples in
                    self?.asr.feedSamples(samples)
                }
                isStreaming = true
            } else {
                recorder.onSamples = nil
                isStreaming = false
            }

            try recorder.start()
            overlay.showRecording()
            statusBar.setRecording(true)
            startLevelFeed()
        } catch {
            overlay.showError()
            NSLog("[Rec] %@", error.localizedDescription)
        }
    }

    // MARK: - Streaming text

    private func handleStreamUpdate(confirmed: String, provisional: String) {
        confirmedRaw = confirmed
        let desired = buildDisplayText(provisional: provisional)
        if desired != displayedText {
            PasteService.replaceText(from: displayedText, to: desired)
            displayedText = desired
        }
        trySentencePolish()
    }

    private func buildDisplayText(provisional: String) -> String {
        let unpolished = String(confirmedRaw.dropFirst(lastPolishBoundary))
        return polishedPrefix + unpolished + provisional
    }

    private static let sentenceEnders: CharacterSet = {
        var cs = CharacterSet()
        for s in [".", "!", "?", "。", "！", "？", "\n"] {
            cs.insert(s.unicodeScalars.first!)
        }
        return cs
    }()

    private func trySentencePolish() {
        guard config.polishEnabled, polisher.state == .ready, !isPolishing else { return }

        let unpolished = String(confirmedRaw.dropFirst(lastPolishBoundary))
        guard let lastEnd = unpolished.rangeOfCharacter(from: Self.sentenceEnders, options: .backwards) else { return }
        let sentenceEnd = unpolished.distance(from: unpolished.startIndex, to: lastEnd.upperBound)
        guard sentenceEnd > 0 else { return }

        let toPolish = String(unpolished.prefix(sentenceEnd))
        let boundary = lastPolishBoundary + sentenceEnd
        isPolishing = true

        polisher.polish(toPolish) { [weak self] polished in
            guard let self else { return }
            self.isPolishing = false

            let oldDisplay = self.displayedText
            self.polishedPrefix += polished
            self.lastPolishBoundary = boundary

            let remaining = String(self.confirmedRaw.dropFirst(self.lastPolishBoundary))
            let newDisplay = self.polishedPrefix + remaining
            if newDisplay != oldDisplay {
                PasteService.replaceText(from: oldDisplay, to: newDisplay)
                self.displayedText = newDisplay
            }

            self.trySentencePolish()
        }
    }

    // MARK: - Stop & finish

    private func stopAndTranscribe() {
        stopLevelFeed()
        recorder.stop()
        statusBar.setRecording(false)

        if isStreaming {
            overlay.showProcessing()
            asr.stopStream { [weak self] finalText in
                guard let self else { return }
                self.confirmedRaw = finalText
                self.finishWithText(finalText)
            }
        } else {
            overlay.hide()
        }
    }

    private func finishWithText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            if !displayedText.isEmpty {
                PasteService.deleteBackward(count: displayedText.count)
            }
            resetTypingState()
            overlay.hide()
            return
        }

        if config.polishEnabled && polisher.state == .ready && !trimmed.isEmpty {
            polisher.polish(trimmed) { [weak self] polished in
                guard let self else { return }
                let oldDisplay = self.displayedText
                PasteService.replaceText(from: oldDisplay, to: polished)
                self.displayedText = polished
                self.resetTypingState()
                self.overlay.showDone()
            }
        } else {
            resetTypingState()
            overlay.showDone()
        }
    }

    private func resetTypingState() {
        displayedText = ""
        confirmedRaw = ""
        polishedPrefix = ""
        lastPolishBoundary = 0
        isPolishing = false
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
