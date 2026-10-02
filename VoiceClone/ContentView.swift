import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = VoiceCloneViewModel()
    @State private var importing = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(model.status, systemImage: model.modelReady ? "iphone" : "cpu")
                    if model.busy && !model.generating { ProgressView() }
                    if !model.modelReady && !model.busy {
                        Button("Retry model loading") { Task { await model.prepare() } }
                    }
                } footer: {
                    Text("OmniVoice BF16 · All voice processing stays on this device. Initial loading can take a while.")
                }
                Section {
                    if let name = model.referenceName {
                        Label(name, systemImage: "waveform")
                        Text(String(format: "%.1f seconds of reference audio", model.referenceDuration))
                            .foregroundStyle(.secondary)
                    }
                    Text("Reference transcript (required)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $model.referenceTranscript)
                        .frame(minHeight: 80)
                        .overlay(alignment: .topLeading) {
                            if model.referenceTranscript.isEmpty {
                                Text("Type exactly what is said in the reference audio…")
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .disabled(model.busy || model.recording)
                        .accessibilityLabel("Reference recording transcript")
                    if model.needsReferenceTranscript {
                        Label("Audio loaded. Add its transcript here to enable generation.", systemImage: "exclamationmark.bubble")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if model.recording {
                        ProgressView(value: model.recordingSeconds, total: 15)
                        Text(String(format: "Recording %.1f / 15 seconds", model.recordingSeconds))
                            .monospacedDigit()
                        Button("Stop recording", role: .destructive) { model.stopRecording() }
                    } else {
                        Button { Task { await model.startRecording() } } label: {
                            Label("Record my voice", systemImage: "mic.fill")
                        }.disabled(model.busy || !model.modelReady)
                        Button { importing = true } label: {
                            Label("Import audio", systemImage: "doc.badge.plus")
                        }.disabled(model.busy || !model.modelReady)
                        Button { Task { await model.useSampleVoice() } } label: {
                            Label("Try sample voice", systemImage: "play.circle")
                        }.disabled(model.busy || !model.modelReady)
                    }
                } header: {
                    Text("Reference voice")
                } footer: {
                    Text("Record 10–15 seconds of clear speech, then enter exactly what you said above. Imported audio uses the first 15 seconds; the transcript must match that passage.")
                }
                Section("What should your voice say?") {
                    TextEditor(text: $model.text)
                        .frame(minHeight: 140)
                        .disabled(model.busy || model.recording)
                        .accessibilityLabel("Text to speak")
                    Text("\(model.text.count) / 1000 characters")
                        .font(.caption)
                        .foregroundStyle(model.text.count > 1000 ? .red : .secondary)
                    Picker("Generation quality", selection: $model.steps) {
                        Text("Fast · 16 steps").tag(16)
                        Text("Full · 32 steps").tag(32)
                    }.disabled(model.busy || model.recording)
                    Picker("Speech language", selection: $model.language) {
                        ForEach(["English", "Spanish", "French", "German", "Portuguese", "Italian", "Russian", "Chinese", "Japanese"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }.disabled(model.busy || model.recording)
                    if model.generating {
                        ProgressView("Generating with OmniVoice…")
                        Button("Cancel generation", role: .destructive) { model.cancelGeneration() }
                    } else {
                        Button { Task { await model.generate() } } label: {
                            Label("Generate speech", systemImage: "waveform.badge.mic")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canGenerate)
                        if let reason = model.generationBlockReason {
                            Text(reason)
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("generationBlockReason")
                        }
                    }
                }
                if let url = model.outputURL {
                    Section("Generated speech") {
                        if let metrics = model.metrics {
                            Text(metrics).font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            if model.playing { model.stopPlayback() } else { model.play() }
                        } label: {
                            Label(model.playing ? "Stop playback" : "Play speech",
                                  systemImage: model.playing ? "stop.fill" : "play.fill")
                        }.disabled(model.busy || model.recording)
                        ShareLink(item: url) { Label("Share WAV", systemImage: "square.and.arrow.up") }
                            .disabled(model.busy || model.recording)
                    }
                }
            }
            .navigationTitle("VoiceClone")
            .task { await model.prepare() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url): Task { await model.importReference(url) }
                case .failure(let error): model.errorMessage = error.localizedDescription
                }
            }
            .alert("VoiceClone", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.handleBackground() }
            }
        }
    }
}

#Preview {
    ContentView()
}
