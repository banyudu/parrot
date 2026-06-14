import Foundation
import MLXAudioSTT
import MLXAudioCore
import MLX

final class ASRBridge {
    enum State: Equatable { case idle, downloading(Double), loading, ready, error(String) }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    private var model: (any STTGenerationModel)?
    private var qwen3Model: Qwen3ASRModel?
    private let queue = DispatchQueue(label: "com.parrot.asr", qos: .userInitiated)

    private var streamSession: StreamingInferenceSession?
    private var streamTask: Task<Void, Never>?

    func start(model modelId: String, useHFMirror: Bool = false) {
        stop()
        setState(.loading)

        if useHFMirror {
            setenv("HF_ENDPOINT", "https://hf-mirror.com", 1)
        } else {
            unsetenv("HF_ENDPOINT")
        }

        guard let family = AppConfig.modelFamilies.first(where: { $0.hasVariant(modelId) }) else {
            setState(.error("Unknown model: \(modelId)"))
            return
        }
        let kind = family.kind

        Task.detached { [weak self] in
            do {
                let loaded: any STTGenerationModel = try await Self.load(kind: kind, modelId: modelId)
                let qwen3 = loaded as? Qwen3ASRModel
                DispatchQueue.main.async {
                    self?.model = loaded
                    self?.qwen3Model = qwen3
                    self?.setState(.ready)
                }
            } catch {
                let msg = error.localizedDescription
                NSLog("[ASR] Failed to load model: %@", msg)
                DispatchQueue.main.async {
                    self?.setState(.error(msg))
                }
            }
        }
    }

    private static func load(
        kind: AppConfig.ModelFamily.Kind,
        modelId: String
    ) async throws -> any STTGenerationModel {
        switch kind {
        case .qwen3ASR:         return try await Qwen3ASRModel.fromPretrained(modelId)
        case .parakeet:         return try await ParakeetModel.fromPretrained(modelId)
        case .voxtralRealtime:  return try await VoxtralRealtimeModel.fromPretrained(modelId)
        case .glmASR:           return try await GLMASRModel.fromPretrained(modelId)
        case .graniteSpeech:    return try await GraniteSpeechModel.fromPretrained(modelId)
        case .cohereTranscribe: return try await CohereTranscribeModel.fromPretrained(modelId)
        }
    }

    func stop() {
        cancelStream()
        model = nil
        qwen3Model = nil
        setState(.idle)
    }

    // MARK: - Streaming

    var supportsStreaming: Bool { qwen3Model != nil }

    func startStream(language: String?, onUpdate: @escaping (String, String) -> Void) {
        guard let qwen3 = qwen3Model else { return }

        cancelStream()

        let lang = (language ?? "").isEmpty ? "auto" : language!
        let config = StreamingConfig(
            decodeIntervalSeconds: 0.8,
            delayPreset: .realtime,
            language: lang
        )
        let session = StreamingInferenceSession(model: qwen3, config: config)
        streamSession = session

        streamTask = Task { [weak self] in
            for await event in session.events {
                switch event {
                case .displayUpdate(let confirmed, let provisional):
                    DispatchQueue.main.async { onUpdate(confirmed, provisional) }
                case .ended(let fullText):
                    DispatchQueue.main.async { onUpdate(fullText, "") }
                default:
                    break
                }
            }
            DispatchQueue.main.async { self?.streamSession = nil }
        }
    }

    func feedSamples(_ samples: [Float]) {
        streamSession?.feedAudio(samples: samples)
    }

    func stopStream(completion: @escaping (String) -> Void) {
        guard let session = streamSession else {
            completion("")
            return
        }

        let task = Task { [weak self] in
            session.stop()
            var finalText = ""
            for await event in session.events {
                if case .ended(let text) = event {
                    finalText = text
                }
            }
            DispatchQueue.main.async {
                self?.streamSession = nil
                self?.streamTask = nil
                completion(finalText)
            }
        }
        _ = task
    }

    func cancelStream() {
        streamSession?.cancel()
        streamTask?.cancel()
        streamSession = nil
        streamTask = nil
    }

    // MARK: - Batch (fallback for non-Qwen3 models)

    func transcribe(audioPath: String, language: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let model = self.model else {
            completion(.failure(NSError(domain: "ASR", code: -2, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])))
            return
        }

        queue.async {
            do {
                let url = URL(fileURLWithPath: audioPath)
                let (_, audioArray) = try loadAudioArray(from: url, sampleRate: 16000)

                let output: STTOutput
                if let lang = language, !lang.isEmpty {
                    let d = model.defaultGenerationParameters
                    let params = STTGenerateParameters(
                        maxTokens: d.maxTokens,
                        temperature: d.temperature,
                        topP: d.topP,
                        topK: d.topK,
                        verbose: d.verbose,
                        language: lang,
                        chunkDuration: d.chunkDuration,
                        minChunkDuration: d.minChunkDuration
                    )
                    output = model.generate(audio: audioArray, generationParameters: params)
                } else {
                    output = model.generate(audio: audioArray)
                }

                DispatchQueue.main.async {
                    completion(.success(output.text))
                }
            } catch {
                NSLog("[ASR] Transcription error: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func reload(model modelId: String, useHFMirror: Bool = false) {
        start(model: modelId, useHFMirror: useHFMirror)
    }

    func waitForIdle(_ done: @escaping () -> Void) {
        queue.async { done() }
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }

    deinit { stop() }
}
