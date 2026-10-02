import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class VoiceCloneViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate, AVAudioRecorderDelegate {
    @Published var text = "Hello! This voice was generated entirely on my iPhone."
    @Published var steps = 32
    @Published var language = "English"
    @Published var referenceTranscript = UserDefaults.standard.string(forKey: "referenceTranscript") ?? "" {
        didSet { UserDefaults.standard.set(referenceTranscript, forKey: "referenceTranscript") }
    }
    @Published private(set) var modelReady = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Loading OmniVoice BF16…"
    @Published private(set) var referenceName: String?
    @Published private(set) var referenceDuration = 0.0
    @Published private(set) var recording = false
    @Published private(set) var recordingSeconds = 0.0
    @Published private(set) var generating = false
    @Published private(set) var progress: Float = 0
    @Published private(set) var outputURL: URL?
    @Published private(set) var playing = false
    @Published private(set) var metrics: String?
    @Published var errorMessage: String?

    private let engine = OmniVoiceEngine()
    private let audioReader = PocketEngine()
    private var reference: VoiceReference?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var generationControl: GenerationControl?
    private var recordingURL: URL?
    private var storage: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceClone", isDirectory: true)
    }
    var needsReferenceTranscript: Bool {
        reference != nil && referenceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var generationBlockReason: String? {
        if !modelReady { return "Wait for the voice model to finish loading." }
        if recording { return "Stop recording before generating speech." }
        if busy { return "Wait for reference preparation to finish." }
        if reference == nil { return "Record or import a reference voice first." }
        if needsReferenceTranscript {
            return "Enter the words spoken in your reference recording to enable Generate speech."
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the text you want your voice to say."
        }
        if text.count > 1000 { return "Shorten the text to 1,000 characters or fewer." }
        return nil
    }
    var canGenerate: Bool { generationBlockReason == nil }

    func prepare() async {
        guard !busy, !modelReady else { return }
        busy = true
        defer { busy = false }
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try await engine.load()
            modelReady = true
            status = "Ready · Works offline"
            if let name = UserDefaults.standard.string(forKey: "referenceFile") {
                let url = storage.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    reference = try await audioReader.readReference(from: url)
                    referenceDuration = reference?.duration ?? 0
                    referenceName = UserDefaults.standard.string(forKey: "referenceName") ?? "Saved voice"
                }
            }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--voiceclone-smoke-test") {
                busy = false
                await useSampleVoice()
                text = "Hello from my iPhone."
                await generate()
                print("VOICECLONE_SMOKE_TEST: \(outputURL?.path ?? errorMessage ?? "No output")")
            }
#endif
        } catch { show(error) }
    }

    func useSampleVoice() async {
        let url = Bundle.main.url(forResource: "reference", withExtension: "wav")
        guard let url else { errorMessage = "The sample voice is missing from the app bundle."; return }
        await acceptReference(url: url, name: "OmniVoice · synthetic sample", copy: true)
        referenceTranscript = "Hello, this is a sample voice for testing. I am speaking clearly, at a relaxed pace, with a warm and natural tone."
    }

    func startRecording() async {
        guard !busy, !recording else { return }
        busy = true
        defer { busy = false }
        stopPlayback()
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone access is disabled. Enable it in Settings → VoiceClone."
            return
        }
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = storage.appendingPathComponent("recording-\(UUID().uuidString).wav")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            recorder.delegate = self
            guard recorder.record(forDuration: 15) else {
                throw VoiceCloneError.message("Could not start the microphone.")
            }
            self.recorder = recorder
            recordingURL = url
            recording = true
            recordingSeconds = 0
            status = "Recording your reference voice…"
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.recording else { return }
                    self.recordingSeconds = self.recorder?.currentTime ?? 0
                }
            }
        } catch { show(error) }
    }

    func stopRecording() { recorder?.stop() }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recording else { return }
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            self.recording = false
            self.recorder = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            guard flag, let url = self.recordingURL else {
                self.errorMessage = "Recording was interrupted. Please record again."
                self.status = "Ready · Works offline"
                return
            }
            await self.acceptReference(url: url, name: "My recorded voice", copy: false)
        }
    }

    func importReference(_ url: URL) async {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        await acceptReference(url: url, name: url.deletingPathExtension().lastPathComponent, copy: true)
    }

    private func acceptReference(url: URL, name: String, copy: Bool) async {
        guard !busy, !recording else { return }
        busy = true
        defer { busy = false }
        stopPlayback()
        status = "Preparing reference voice…"
        do {
            let decoded = try await audioReader.readReference(from: url)
            let destination: URL
            if copy {
                destination = storage.appendingPathComponent("reference-\(UUID().uuidString).\(url.pathExtension)")
                try FileManager.default.copyItem(at: url, to: destination)
            } else { destination = url }
            let oldName = UserDefaults.standard.string(forKey: "referenceFile")
            reference = decoded
            referenceName = name
            referenceDuration = decoded.duration
            referenceTranscript = ""
            UserDefaults.standard.set(destination.lastPathComponent, forKey: "referenceFile")
            UserDefaults.standard.set(name, forKey: "referenceName")
            if let oldName, oldName != destination.lastPathComponent {
                try? FileManager.default.removeItem(at: storage.appendingPathComponent(oldName))
            }
            status = "Reference audio ready · Works offline"
        } catch {
            // A failed recording is app-owned; imported originals are never removed.
            if !copy { try? FileManager.default.removeItem(at: url) }
            show(error)
        }
    }

    func generate() async {
        guard canGenerate, let reference else { return }
        stopPlayback()
        busy = true
        generating = true
        progress = 0
        metrics = nil
        status = "Generating speech…"
        let control = GenerationControl { [weak self] value in
            Task { @MainActor [weak self] in
                guard self?.generating == true else { return }
                self?.progress = value
            }
        }
        generationControl = control
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            busy = false
            generating = false
            generationControl = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        do {
            let url = storage.appendingPathComponent("speech-\(UUID().uuidString).wav")
            let result = try await engine.generate(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), reference: reference,
                transcript: referenceTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                language: language, steps: steps, outputURL: url, control: control)
            if let previous = outputURL { try? FileManager.default.removeItem(at: previous) }
            outputURL = result.url
            metrics = String(format: "%.1fs audio · %.1fs to generate · %.2f× real time",
                             result.duration, result.elapsed, result.duration / max(0.001, result.elapsed))
            status = "Speech ready"
            play()
        } catch is CancellationError { status = "Generation cancelled" }
        catch { show(error) }
    }

    func cancelGeneration() {
        generationControl?.cancel()
        status = "Stopping generation…"
    }
    func play() {
        guard let outputURL else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            player = try AVAudioPlayer(contentsOf: outputURL)
            player?.delegate = self
            guard player?.play() == true else { throw VoiceCloneError.message("Could not play the audio.") }
            playing = true
        } catch { show(error) }
    }
    func stopPlayback() {
        player?.stop()
        player = nil
        playing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stopPlayback() }
    }
    func handleBackground() {
        if recording { stopRecording() }
        if generating { cancelGeneration() }
        stopPlayback()
    }
    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        status = modelReady ? "Ready · Works offline" : "Model could not load"
    }
}
