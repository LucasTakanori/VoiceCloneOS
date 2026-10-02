import AVFoundation
import Foundation
import SherpaOnnx

/// AVAudioConverter invokes this synchronously but declares its input block
/// Sendable. This object owns the immutable buffer and locks consumption state.
private final class AudioConversionInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var supplied = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}

enum VoiceCloneError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

/// C callbacks run outside Swift actors; cancellation is protected by a lock.
final class GenerationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var lastProgress: Float = -1
    let report: @Sendable (Float) -> Void
    init(report: @escaping @Sendable (Float) -> Void) { self.report = report }
    func cancel() { lock.withLock { stopped = true } }
    var isCancelled: Bool { lock.withLock { stopped } }
    func update(_ progress: Float) -> Int32 {
        let value = min(1, max(0, progress))
        let state = lock.withLock { () -> (Bool, Bool) in
            let changed = value - lastProgress >= 0.02 || value == 1
            if changed { lastProgress = value }
            return (stopped, changed)
        }
        if state.1 { report(value) }
        return state.0 ? 0 : 1
    }
}

struct VoiceReference: Sendable {
    let samples: [Float]
    let sampleRate: Int
    var duration: Double { Double(samples.count) / Double(sampleRate) }
}

struct GenerationResult: Sendable {
    let url: URL
    let duration: Double
    let elapsed: Double
}

/// Serializes ONNX access off MainActor and reuses the voice embedding cache.
actor PocketEngine {
    private var tts: SherpaOnnxOfflineTtsWrapper?
    static let modelFolder = "sherpa-onnx-pocket-tts-int8-2026-01-26"
    func load() throws {
        guard tts == nil else { return }
        func path(_ name: String) throws -> String {
            let url = Bundle.main.url(forResource: name, withExtension: nil,
                                      subdirectory: Self.modelFolder)
                ?? Bundle.main.url(forResource: name, withExtension: nil)
            guard let url else {
                throw VoiceCloneError.message("Missing model file: \(name). Check the model resources in Xcode.")
            }
            return url.path
        }
        let pocket = try sherpaOnnxOfflineTtsPocketModelConfig(
            lmFlow: path("lm_flow.int8.onnx"), lmMain: path("lm_main.int8.onnx"),
            encoder: path("encoder.onnx"), decoder: path("decoder.int8.onnx"),
            textConditioner: path("text_conditioner.onnx"),
            vocabJson: path("vocab.json"), tokenScoresJson: path("token_scores.json"),
            voiceEmbeddingCacheCapacity: 2)
        let model = sherpaOnnxOfflineTtsModelConfig(numThreads: 2, provider: "cpu", pocket: pocket)
        var config = sherpaOnnxOfflineTtsConfig(model: model, maxNumSentences: 1)
        let loaded = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard loaded.tts != nil else {
            throw VoiceCloneError.message("Pocket TTS could not load. Check model files and available memory.")
        }
        tts = loaded
    }

    func readReference(from url: URL) throws -> VoiceReference {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0, format.channelCount <= 8 else {
            throw VoiceCloneError.message("Unsupported reference audio format.")
        }
        let frames = AVAudioFrameCount(min(file.length, AVAudioFramePosition(format.sampleRate * 15)))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw VoiceCloneError.message("The reference recording is empty.")
        }
        try file.read(into: buffer, frameCount: frames)
        guard let channels = buffer.floatChannelData else {
            throw VoiceCloneError.message("Could not decode the reference recording.")
        }
        let count = Int(buffer.frameLength)
        guard Double(count) / format.sampleRate >= 3 else {
            throw VoiceCloneError.message("Record at least 3 seconds of clear speech; 10–15 seconds works best.")
        }
        var samples = [Float](repeating: 0, count: count)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<count { samples[frame] += channels[channel][frame] / Float(format.channelCount) }
        }
        guard samples.allSatisfy({ $0.isFinite }),
              sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(count)) > 0.001 else {
            throw VoiceCloneError.message("The recording is too quiet. Move closer to the microphone and try again.")
        }
        guard format.sampleRate != 24000 else {
            return VoiceReference(samples: samples, sampleRate: 24000)
        }
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 24000, channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count)),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat,
                  frameCapacity: AVAudioFrameCount(ceil(Double(count) * 24000 / format.sampleRate)) + 32) else {
            throw VoiceCloneError.message("Could not convert reference audio to 24 kHz.")
        }
        source.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
        let input = AudioConversionInput(source)
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            input.next(status)
        }
        if let conversionError { throw conversionError }
        guard output.frameLength > 0, let converted = output.floatChannelData?[0] else {
            throw VoiceCloneError.message("Audio conversion returned no samples.")
        }
        return VoiceReference(samples: Array(UnsafeBufferPointer(start: converted, count: Int(output.frameLength))),
                              sampleRate: 24000)
    }

    func generate(text: String, reference: VoiceReference, steps: Int,
                  outputURL: URL, control: GenerationControl) throws -> GenerationResult {
        try load()
        guard let tts else { throw VoiceCloneError.message("The model is not ready.") }
        if control.isCancelled { throw CancellationError() }
        let config = SherpaOnnxGenerationConfigSwift(
            referenceAudio: reference.samples, referenceSampleRate: reference.sampleRate,
            numSteps: steps, extra: ["max_reference_audio_len": 15.0])
        let started = Date()
        let callback: TtsProgressCallbackWithArg = { _, _, progress, argument in
            guard let argument else { return 0 }
            return Unmanaged<GenerationControl>.fromOpaque(argument).takeUnretainedValue().update(progress)
        }
        let audio = withExtendedLifetime(control) {
            tts.generateWithConfig(text: text, config: config, callback: callback,
                                   arg: Unmanaged.passUnretained(control).toOpaque())
        }
        if control.isCancelled { throw CancellationError() }
        guard audio.audio != nil, audio.n > 0, audio.sampleRate > 0 else {
            throw VoiceCloneError.message("No speech was generated. Try a shorter sentence or another recording.")
        }
        guard audio.save(filename: outputURL.path) == 1 else {
            throw VoiceCloneError.message("Could not save the generated audio.")
        }
        return GenerationResult(url: outputURL, duration: Double(audio.n) / Double(audio.sampleRate),
                                elapsed: Date().timeIntervalSince(started))
    }
}
