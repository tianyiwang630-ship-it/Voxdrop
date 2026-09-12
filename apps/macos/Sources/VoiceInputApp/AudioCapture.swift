import AVFoundation
import Foundation

final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var startedAt: Date?

    func start(to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard file == nil else { return }
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw NSError(domain: "VoiceInput.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 16 kHz 音频转换器"])
        }
        let output = try AVAudioFile(forWriting: url, settings: target.settings, commonFormat: .pcmFormatInt16, interleaved: false)
        self.file = output; self.converter = converter; startedAt = Date()
        input.installTap(onBus: 0, bufferSize: 4096, format: source) { [weak self] buffer, _ in self?.convert(buffer) }
        engine.prepare(); try engine.start()
    }

    func stop() -> Int {
        lock.lock(); defer { lock.unlock() }
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        file = nil; converter = nil
        let duration = startedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        startedAt = nil; return duration
    }

    func cancel() { _ = stop() }

    private func convert(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let converter, let file else { return }
        let ratio = 16_000 / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
        var consumed = false; var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if consumed { state.pointee = .noDataNow; return nil }
            consumed = true; state.pointee = .haveData; return input
        }
        if status != .error, output.frameLength > 0 { try? file.write(from: output) }
    }
}
