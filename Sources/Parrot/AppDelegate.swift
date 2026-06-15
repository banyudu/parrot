import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = AppConfig.load()
    private let recorder = AudioRecorder()
    private let overlay = OverlayPanel()
    private let asr = ASRBridge()
    private let hotkey = HotkeyManager()
    private let polisher = TextPolisher()
    private var statusBar: StatusBarController!

    private let focusTracker = FocusTracker()
    private var levelTimer: Timer?
    private var isStreaming = false

    private var displayedText = ""
    private var confirmedRaw = ""
    private var polishedPrefix = ""
    private var lastPolishBoundary = 0
    private var isPolishing = false
    private var sessionGeneration = 0

    // Idle offload
    private var idleTimer: Timer?
    private var pendingRecordingStart = false
    private var preloadAudioBuffer: [[Float]] = []
    private let bufferLock = NSLock()
    private var pendingTranscription: URL?

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
                if self.pendingRecordingStart && self.recorder.isRecording {
                    self.pendingRecordingStart = false
                    self.activateLiveASR()
                } else if let audioURL = self.pendingTranscription {
                    self.pendingTranscription = nil
                    self.transcribePendingAudio(audioURL)
                }
            case .error(let msg):
                self.statusBar.setStatus("ASR error: \(msg)")
                self.statusBar.setLoading(false)
                if self.pendingRecordingStart {
                    self.pendingRecordingStart = false
                    self.drainBufferAndCleanup()
                } else if let audioURL = self.pendingTranscription {
                    self.pendingTranscription = nil
                    try? FileManager.default.removeItem(at: audioURL)
                    self.overlay.showError()
                }
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
        AutoUpdater.shared.checkOnLaunch()

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
        idleTimer?.invalidate()
        if recorder.isRecording {
            if let url = recorder.stop() { try? FileManager.default.removeItem(at: url) }
        }
        hotkey.unregister()
        asr.stop()
        polisher.unload()
    }

    // MARK: - Idle offload

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        let minutes = config.idleOffloadMinutes
        guard minutes > 0 else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.offloadModels()
        }
    }

    private func cancelIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func offloadModels() {
        guard !recorder.isRecording else { return }
        NSLog("[Idle] Offloading models after %d min idle", config.idleOffloadMinutes)
        asr.stop()
        polisher.unload()
        statusBar.setStatus("Standby — models offloaded")
        statusBar.setLoading(false)
    }

    private func activateLiveASR() {
        if asr.supportsStreaming && config.streamingEnabled {
            let lang = config.language.isEmpty ? nil : config.language
            resetTypingState()

            asr.startStream(language: lang) { [weak self] confirmed, provisional in
                self?.handleStreamUpdate(confirmed: confirmed, provisional: provisional)
            }

            bufferLock.lock()
            let buffered = preloadAudioBuffer
            preloadAudioBuffer.removeAll()
            bufferLock.unlock()

            recorder.onSamples = { [weak self] samples in
                self?.asr.feedSamples(samples)
            }

            for chunk in buffered {
                asr.feedSamples(chunk)
            }

            isStreaming = true
        } else {
            recorder.onSamples = nil
            isStreaming = false
            drainBufferAndCleanup()
        }
    }

    private func transcribePendingAudio(_ audioURL: URL) {
        overlay.showProcessing()
        let lang = config.language.isEmpty ? nil : config.language
        let gen = sessionGeneration
        asr.transcribe(audioPath: audioURL.path, language: lang) { [weak self] result in
            guard let self, self.sessionGeneration == gen else { return }
            switch result {
            case .success(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.overlay.hide()
                } else if self.config.polishEnabled && self.polisher.state == .ready {
                    let lang = self.config.language.isEmpty ? nil : self.config.language
                    self.polisher.polish(trimmed, language: lang) { polished in
                        guard self.sessionGeneration == gen else { return }
                        self.focusTracker.restore()
                        self.overlay.showDone()
                        PasteService.paste(polished, copyToClipboard: self.config.copyToClipboard)
                    }
                } else {
                    self.focusTracker.restore()
                    self.overlay.showDone()
                    PasteService.paste(trimmed, copyToClipboard: self.config.copyToClipboard)
                }
            case .failure:
                self.overlay.showError()
            }
            try? FileManager.default.removeItem(at: audioURL)
            self.resetIdleTimer()
        }
    }

    private func drainBufferAndCleanup() {
        bufferLock.lock()
        preloadAudioBuffer.removeAll()
        bufferLock.unlock()
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
        cancelIdleTimer()
        focusTracker.capture()
        overlay.setAnchor(focusTracker.cursorRect())

        let modelReady = asr.state == .ready

        if !modelReady {
            switch asr.state {
            case .idle, .error:
                asr.start(model: config.model, useHFMirror: config.useHFMirror)
            case .loading, .downloading:
                break
            default:
                break
            }
            if config.polishEnabled && polisher.state == .idle {
                polisher.loadModel(config.polishModel, useHFMirror: config.useHFMirror)
            }
        }

        do {
            if !modelReady {
                pendingRecordingStart = true
                bufferLock.lock()
                preloadAudioBuffer.removeAll()
                bufferLock.unlock()
                recorder.onSamples = { [weak self] samples in
                    guard let self else { return }
                    self.bufferLock.lock()
                    self.preloadAudioBuffer.append(samples)
                    self.bufferLock.unlock()
                }
                isStreaming = false
            } else if asr.supportsStreaming && config.streamingEnabled {
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
            pendingRecordingStart = false
            NSLog("[Rec] %@", error.localizedDescription)
        }
    }

    // MARK: - Streaming text

    private func handleStreamUpdate(confirmed: String, provisional: String) {
        confirmedRaw = confirmed
        let desired = buildDisplayText(provisional: provisional)
        if desired != displayedText {
            focusTracker.restore()
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
        let gen = sessionGeneration

        let lang = config.language.isEmpty ? nil : config.language
        polisher.polish(toPolish, language: lang) { [weak self] polished in
            guard let self else { return }
            self.isPolishing = false
            guard self.sessionGeneration == gen else { return }

            let oldDisplay = self.displayedText
            self.polishedPrefix += polished
            self.lastPolishBoundary = boundary

            let remaining = String(self.confirmedRaw.dropFirst(self.lastPolishBoundary))
            let newDisplay = self.polishedPrefix + remaining
            if newDisplay != oldDisplay {
                self.focusTracker.restore()
                PasteService.replaceText(from: oldDisplay, to: newDisplay)
                self.displayedText = newDisplay
            }

            self.trySentencePolish()
        }
    }

    // MARK: - Stop & finish

    private func stopAndTranscribe() {
        stopLevelFeed()
        let audioURL = recorder.stop()
        statusBar.setRecording(false)

        let wasBuffering = pendingRecordingStart
        pendingRecordingStart = false
        drainBufferAndCleanup()

        if isStreaming {
            overlay.showProcessing()
            sessionGeneration += 1
            asr.cancelStream()

            guard let audioURL else {
                resetTypingState()
                overlay.hide()
                resetIdleTimer()
                return
            }

            let lang = config.language.isEmpty ? nil : config.language
            let gen = sessionGeneration
            asr.transcribe(audioPath: audioURL.path, language: lang) { [weak self] result in
                guard let self, self.sessionGeneration == gen else { return }
                switch result {
                case .success(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.confirmedRaw = trimmed
                    self.focusTracker.restore()
                    self.finishWithText(trimmed)
                case .failure:
                    if !self.displayedText.isEmpty {
                        self.focusTracker.restore()
                        PasteService.deleteBackward(count: self.displayedText.count)
                    }
                    self.resetTypingState()
                    self.overlay.showError()
                }
                try? FileManager.default.removeItem(at: audioURL)
                self.resetIdleTimer()
            }
        } else if wasBuffering || asr.state != .ready {
            if let audioURL {
                overlay.showProcessing()
                pendingTranscription = audioURL
            } else {
                overlay.hide()
                resetIdleTimer()
            }
        } else if let audioURL {
            overlay.showProcessing()
            let lang = config.language.isEmpty ? nil : config.language
            let gen = sessionGeneration
            asr.transcribe(audioPath: audioURL.path, language: lang) { [weak self] result in
                guard let self, self.sessionGeneration == gen else { return }
                switch result {
                case .success(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        self.overlay.hide()
                    } else if self.config.polishEnabled && self.polisher.state == .ready {
                        let lang = self.config.language.isEmpty ? nil : self.config.language
                        self.polisher.polish(trimmed, language: lang) { polished in
                            guard self.sessionGeneration == gen else { return }
                            self.focusTracker.restore()
                            self.overlay.showDone()
                            PasteService.paste(polished, copyToClipboard: self.config.copyToClipboard)
                        }
                    } else {
                        self.focusTracker.restore()
                        self.overlay.showDone()
                        PasteService.paste(trimmed, copyToClipboard: self.config.copyToClipboard)
                    }
                case .failure:
                    self.overlay.showError()
                }
                try? FileManager.default.removeItem(at: audioURL)
                self.resetIdleTimer()
            }
        } else {
            overlay.hide()
            resetIdleTimer()
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

        let gen = sessionGeneration

        let lang = config.language.isEmpty ? nil : config.language

        if displayedText.isEmpty {
            if config.polishEnabled && polisher.state == .ready {
                polisher.polish(trimmed, language: lang) { [weak self] polished in
                    guard let self, self.sessionGeneration == gen else { return }
                    self.focusTracker.restore()
                    self.overlay.showDone()
                    PasteService.paste(polished, copyToClipboard: self.config.copyToClipboard)
                    self.resetTypingState()
                }
            } else {
                focusTracker.restore()
                overlay.showDone()
                PasteService.paste(trimmed, copyToClipboard: self.config.copyToClipboard)
                resetTypingState()
            }
            return
        }

        PasteService.replaceText(from: displayedText, to: trimmed)
        displayedText = trimmed

        if config.polishEnabled && polisher.state == .ready {
            polisher.polish(trimmed, language: lang) { [weak self] polished in
                guard let self, self.sessionGeneration == gen else { return }
                self.focusTracker.restore()
                PasteService.replaceText(from: self.displayedText, to: polished)
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
        sessionGeneration += 1
        displayedText = ""
        confirmedRaw = ""
        polishedPrefix = ""
        lastPolishBoundary = 0
        isPolishing = false
        focusTracker.clear()
        overlay.setAnchor(nil)
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

    // MARK: - Language

    func selectLanguage(_ lang: String) {
        guard lang != config.language else { return }
        config.language = lang
        config.save()
        statusBar.rebuildMenu()
    }

    // MARK: - Streaming

    func toggleStreaming() {
        config.streamingEnabled.toggle()
        config.save()
        statusBar.rebuildMenu()
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
