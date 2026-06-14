import AVFoundation
import Foundation

final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var isRecording = false
    private(set) var level: Float = 0

    var onSamples: (([Float]) -> Void)?

    func start() throws {
        guard !isRecording else { return }

        let eng = AVAudioEngine()
        let node = eng.inputNode
        let hwFormat = node.outputFormat(forBus: 0)

        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let conv = AVAudioConverter(from: hwFormat, to: monoFormat)!
        converter = conv

        node.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) {
            [weak self] buffer, _ in
            guard let self else { return }

            if let samples = buffer.floatChannelData?[0] {
                var sum: Float = 0
                let count = Int(buffer.frameLength)
                for i in 0..<count { sum += abs(samples[i]) }
                self.level = sum / max(Float(count), 1)
            }

            let ratio = 16000.0 / hwFormat.sampleRate
            let outCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: outCapacity) else { return }

            var error: NSError?
            conv.convert(to: outBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if error != nil { return }

            let count = Int(outBuffer.frameLength)
            guard count > 0, let ptr = outBuffer.floatChannelData?[0] else { return }
            let samples16k = Array(UnsafeBufferPointer(start: ptr, count: count))
            self.onSamples?(samples16k)
        }

        try eng.start()
        engine = eng
        isRecording = true
    }

    func stop() {
        guard let eng = engine else { return }
        eng.stop()
        eng.inputNode.removeTap(onBus: 0)
        engine = nil
        converter = nil
        isRecording = false
    }
}
