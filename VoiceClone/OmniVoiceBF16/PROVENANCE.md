# OmniVoice BF16 resources

Both GGUF files are the BF16 variants from:
https://huggingface.co/Serveurperso/OmniVoice-GGUF

Original model: https://huggingface.co/k2-fsa/OmniVoice
Weights license: CC BY-NC 4.0 (non-commercial).
Audio codec: Higgs Audio v2; see the distributor's model card for attribution.

SHA-256 checksums:

```
c4d2e4e6506a88f9c9900621606470bca6a523c72819bf4a5e5dac80961075bf  omnivoice-base-BF16.gguf
c2179e4cf528b19fea22a5be94c34c083877bb5fc28ac0245d2b4299a262dcec  omnivoice-tokenizer-BF16.gguf
```

`reference.wav` is a synthetic evaluation voice generated locally with these
BF16 models, 32 steps, seed 42, English. `reference.txt` is its transcript.
It is intended to verify the pipeline, not to evaluate a real speaker's accent.

Native runtime: https://github.com/ServeurpersoCom/omnivoice.cpp
Runtime commit: 53e6c2066150802ad3cd4b655b31c696e78e0019
GGML submodule: 40e16e4a814f7fe851a0c486fb9e8c722e957830
