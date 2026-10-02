import AVFoundation
import Foundation
import OmniVoiceNative

/// Lifetime owner; all native access is confined to OmniVoiceEngine's actor.
private final class OwnedOmniContext: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { ov_free(pointer) }
}

/// BF16 OmniVoice and BF16 audio codec through the native GGML/Metal runtime.
actor OmniVoiceEngine {
    private var context: OwnedOmniContext?

    func load() throws {
        guard context == nil else { return }
#if targetEnvironment(simulator)
        // Simulator Metal lacks BF16 and traps on codec buffer allocation.
        // Accelerate handles matrix products; other ops fall back to CPU.
        // The A19 device uses native Metal.
        setenv("GGML_BACKEND", "BLAS", 1)
#endif
        func path(_ name: String) throws -> String {
            guard let url = Bundle.main.url(forResource: name, withExtension: "gguf") else {
                throw VoiceCloneError.message("Missing BF16 model: \(name).gguf")
            }
            return url.path
        }
        let model = try path("omnivoice-base-BF16")
        let codec = try path("omnivoice-tokenizer-BF16")
        var params = ov_init_params()
        ov_init_default_params(&params)
#if targetEnvironment(simulator)
        params.use_fa = false
#endif
        context = model.withCString { modelPath in
            codec.withCString { codecPath in
                params.model_path = modelPath
                params.codec_path = codecPath
                return ov_init(&params).map { OwnedOmniContext($0) }
            }
        }
        guard context != nil else { throw nativeError("Could not load OmniVoice BF16") }
    }

    func generate(text: String, reference: VoiceReference, transcript: String,
                  language: String, steps: Int, outputURL: URL,
                  control: GenerationControl) throws -> GenerationResult {
        try load()
        guard let context else { throw VoiceCloneError.message("OmniVoice is not loaded.") }
        guard reference.sampleRate == 24000 else {
            throw VoiceCloneError.message("Reference audio must be converted to 24 kHz.")
        }
        if control.isCancelled { throw CancellationError() }
        var params = ov_tts_params()
        ov_tts_default_params(&params)
        params.mg_num_step = Int32(steps)
        // Bound scratch memory by keeping generated chunks short on iPhone.
        params.chunk_duration_sec = 5
        params.chunk_threshold_sec = 8
        params.cancel_user_data = Unmanaged.passUnretained(control).toOpaque()
        params.cancel = { raw in
            guard let raw else { return true }
            return Unmanaged<GenerationControl>.fromOpaque(raw).takeUnretainedValue().isCancelled
        }
        var audio = ov_audio()
        defer { ov_audio_free(&audio) }
        let started = Date()
        let code = withExtendedLifetime(control) {
            text.withCString { textPointer in
                transcript.withCString { transcriptPointer in
                    language.withCString { languagePointer in
                        reference.samples.withUnsafeBufferPointer { buffer in
                            params.text = textPointer
                            params.lang = languagePointer
                            params.ref_text = transcriptPointer
                            params.ref_audio_24k = buffer.baseAddress
                            params.ref_n_samples = Int32(buffer.count)
                            return ov_synthesize(context.pointer, &params, &audio)
                        }
                    }
                }
            }
        }
        if control.isCancelled || code == OV_STATUS_CANCELLED { throw CancellationError() }
        guard code == OV_STATUS_OK else { throw nativeError("Speech generation failed") }
        guard let samples = audio.samples, audio.n_samples > 0, audio.sample_rate > 0 else {
            throw VoiceCloneError.message("OmniVoice returned no audio.")
        }
        let count = AVAudioFrameCount(audio.n_samples)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: Double(audio.sample_rate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let destination = buffer.floatChannelData?[0] else {
            throw VoiceCloneError.message("Could not allocate output audio.")
        }
        buffer.frameLength = count
        destination.update(from: samples, count: Int(count))
        let file = try AVAudioFile(forWriting: outputURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(audio.sample_rate),
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        try file.write(from: buffer)
        return GenerationResult(url: outputURL, duration: Double(count) / Double(audio.sample_rate),
                                elapsed: Date().timeIntervalSince(started))
    }

    private func nativeError(_ fallback: String) -> VoiceCloneError {
        let detail = ov_last_error().map { String(cString: $0) } ?? ""
        return .message(detail.isEmpty ? fallback : "\(fallback): \(detail)")
    }
}
