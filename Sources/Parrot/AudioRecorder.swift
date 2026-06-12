import AVFoundation
import Foundation

final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private(set) var isRecording = false
    private(set) var level: Float = 0

    func start() throws {
        guard !isRecording else { return }

        let eng = AVAudioEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot_\(UUID().uuidString).wav")

        let node = eng.inputNode
        let hwFormat = node.outputFormat(forBus: 0)
        audioFile = try AVAudioFile(forWriting: url, settings: hwFormat.settings)

        node.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            try? self.audioFile?.write(from: buffer)

            if let samples = buffer.floatChannelData?[0] {
                var sum: Float = 0
                let count = Int(buffer.frameLength)
                for i in 0..<count { sum += abs(samples[i]) }
                self.level = sum / max(Float(count), 1)
            }
        }

        try eng.start()
        engine = eng
        isRecording = true
    }

    func stop() -> URL? {
        guard let eng = engine else { return nil }
        eng.stop()
        eng.inputNode.removeTap(onBus: 0)
        engine = nil
        isRecording = false

        let url = audioFile?.url
        audioFile = nil
        return url
    }
}
