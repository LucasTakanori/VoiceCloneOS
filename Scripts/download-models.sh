#!/bin/bash
# Run from any directory: bash Scripts/download-models.sh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
model_dir="$project_root/VoiceClone/OmniVoiceBF16"
model_base="https://huggingface.co/Serveurperso/OmniVoice-GGUF/resolve/main"
mkdir -p "$model_dir"

download_model() {
    local name="$1" expected="$2" destination="$model_dir/$1"
    if [ -f "$destination" ] && [ "$(shasum -a 256 "$destination" | awk '{print $1}')" = "$expected" ]; then
        echo "Verified $name"
        return
    fi
    # Keep downloads separate until verification succeeds. Resume interrupted transfers.
    curl --fail --location --retry 3 --continue-at - "$model_base/$name" -o "$destination.download"
    local actual
    actual="$(shasum -a 256 "$destination.download" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "Checksum mismatch for $name. Download retained at $destination.download." >&2
        exit 1
    fi
    mv "$destination.download" "$destination"
    echo "Verified $name"
}

download_model omnivoice-base-BF16.gguf c4d2e4e6506a88f9c9900621606470bca6a523c72819bf4a5e5dac80961075bf
download_model omnivoice-tokenizer-BF16.gguf c2179e4cf528b19fea22a5be94c34c083877bb5fc28ac0245d2b4299a262dcec
echo "BF16 models ready. Weights are CC BY-NC 4.0 (non-commercial use)."
