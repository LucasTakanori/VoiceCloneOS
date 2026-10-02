# BF16 trial — 2026-10-01

On this Apple M4 Pro Mac, native Metal inference using BF16 backbone and BF16
codec completed both synthetic reference generation and voice cloning.

Reference generation: 6.88-second WAV, 4.43 seconds MaskGIT + decode. First
process run took 24.5 seconds including Metal compilation and model loading.

Cloning: 4.83-second WAV in bf16-clone.wav, 5.83 seconds MaskGIT + decode;
whole command took 7.21 seconds including load and reference processing.
Peak resident set reported by /usr/bin/time: 2,534,801,408 bytes. This is a
Mac measurement, not an iPhone memory budget or benchmark.

Output is 24 kHz mono PCM16, 115,920 samples, RMS about 0.0651 (not silent).
Target text: “Hello! We are now testing voice cloning with the BF16 OmniVoice model.”

Reference is the synthetic evaluation recording bundled in OmniVoiceBF16,
with its exact transcript, using 32 steps and seed 42. This validates native
voice cloning but does not establish how well it reproduces the user's accent.
