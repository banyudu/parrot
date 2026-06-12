import Foundation
import MLX
import MLXLLM
import MLXLMCommon

final class TextPolisher {
    enum State: Equatable { case idle, loading, ready, error(String) }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    private var container: ModelContainer?

    func loadModel(_ modelId: String, useHFMirror: Bool = false) {
        setState(.loading)

        if useHFMirror {
            setenv("HF_ENDPOINT", "https://hf-mirror.com", 1)
        } else {
            unsetenv("HF_ENDPOINT")
        }

        let configuration = ModelConfiguration(id: modelId)

        Task.detached { [weak self] in
            do {
                let loaded = try await LLMModelFactory.shared.loadContainer(
                    configuration: configuration
                ) { progress in
                    NSLog("[Polish] Downloading: %.0f%%", progress.fractionCompleted * 100)
                }
                DispatchQueue.main.async {
                    self?.container = loaded
                    self?.setState(.ready)
                }
            } catch {
                NSLog("[Polish] Failed to load model: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self?.setState(.error(error.localizedDescription))
                }
            }
        }
    }

    func unload() {
        container = nil
        setState(.idle)
    }

    func polish(_ text: String, completion: @escaping (String) -> Void) {
        guard let container else {
            completion(text)
            return
        }

        Task.detached {
            let result = await Self.generate(container: container, text: text)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func generate(container: ModelContainer, text: String) async -> String {
        do {
            let output: String = try await container.perform { context in
                let messages: [Chat.Message] = [
                    .system(systemPrompt),
                    .user(text),
                ]
                let input = UserInput(prompt: .chat(messages))
                let lmInput = try await context.processor.prepare(input: input)

                let params = GenerateParameters(maxTokens: 2048, temperature: 0.3, topP: 0.9)
                let stream = try MLXLMCommon.generate(input: lmInput, parameters: params, context: context)

                var result = ""
                for await generation in stream {
                    switch generation {
                    case .chunk(let chunk):
                        result += chunk
                    default:
                        break
                    }
                }
                return result
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? text : trimmed
        } catch {
            NSLog("[Polish] Generation error: %@", error.localizedDescription)
            return text
        }
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }

    private static let systemPrompt = """
        You are a dictation text polisher. Clean up speech-to-text output:
        - Remove stutters, repetitions, and false starts
        - Remove filler words (um, uh, like, you know, 那个, 嗯, 然后, 就是说)
        - Fix obvious speech recognition errors
        - Add proper punctuation and capitalization
        - Preserve the original language — do not translate
        - Preserve the original meaning exactly
        Output ONLY the cleaned text, nothing else.
        """
}
