# VoiceClone — OmniVoice BF16 trial

VoiceClone now uses OmniVoice through a native GGML/Metal engine. The backbone
and audio codec are both BF16 GGUF variants (about 1.6 GB total). Models are
bundled, so inference is offline after installation. The earlier Pocket TTS
files remain in the project but that model is not loaded for generation.

## Run

After cloning this repository, download and verify the two BF16 model files:

```sh
bash Scripts/download-models.sh
```

Allow about 1.6 GB for the models plus additional space for Xcode build copies.
The weights are excluded from Git; the script downloads the exact variants
verified for this app and checks their SHA-256 hashes. The native XCFramework
and synthetic sample voice are included. The legacy Pocket ONNX weights are
not needed for the active BF16 engine and are not included in this repository.

Open VoiceClone.xcodeproj, select your connected iPhone, and press Run. The
project retains its existing signing team and iOS 26.2 deployment target.
For your own device, select your Apple development team in Signing & Capabilities
and change the bundle identifier if needed.
Use a Release build for representative performance. First loading can take
longer because Metal compiles embedded shaders and loads the model weights.

Record 10–15 seconds or import an audio file. Enter the EXACT words spoken in
that reference clip. Only the first 15 seconds of imported audio are used;
the transcript must match that passage. The recording and transcript persist
across launches. Select the desired output language, enter text to synthesize,
and Generate speech. Full quality defaults to 32 steps; Fast uses 16.

Try sample voice uses a synthetic recording with its known transcript, allowing
an immediate pipeline check. To assess accent and style fidelity, compare output
against your own clean recording. Successful generation alone is not a voice
similarity evaluation.

All decoding and inference run outside the UI actor. References are downmixed
and resampled to 24 kHz. Generated output is a shareable 24 kHz mono PCM WAV.
Long output is synthesized in roughly 5-second chunks to limit scratch memory,
then played once the full result is ready. Cancellation is cooperative between
chunks; a single native model call cannot be interrupted immediately.

## Build and test

The included Vendor/OmniVoiceNative.xcframework has arm64 iPhone and arm64
simulator libraries. Its public C API is wrapped by OmniVoiceEngine.swift.
Simulator builds use Accelerate/CPU inference because emulated Metal does not support
BF16 and traps during codec buffer allocation. Physical devices use native
Metal. A simulator smoke test can therefore be substantially slower.
Rebuild using `bash Scripts/rebuild-omnivoice.sh` on an Apple Silicon Mac with
Xcode and CMake. The script pins the runtime and its GGML submodule.

The Debug launch argument `--voiceclone-smoke-test` loads the synthetic sample
voice and generates a short sentence through the full app pipeline. The WAV
path is printed with VOICECLONE_SMOKE_TEST. This verifies loading, reference
decoding, native cloning, saving, and playback setup. It does not measure phone
speed when run in a simulator.

## Provenance

Weights: https://huggingface.co/Serveurperso/OmniVoice-GGUF
Original: https://huggingface.co/k2-fsa/OmniVoice
Native engine: https://github.com/ServeurpersoCom/omnivoice.cpp
Model hashes and synthetic sample provenance are in
VoiceClone/OmniVoiceBF16/PROVENANCE.md. Runtime licenses are in Vendor/.
The OmniVoice pretrained weights are CC BY-NC 4.0, for non-commercial use.

The previous Pocket model archive includes its original README and LICENSE;
those files contain conflicting commercial-use descriptions. That discrepancy
does not change OmniVoice's separate non-commercial model terms.
