#!/bin/bash
# Run with: bash Scripts/rebuild-omnivoice.sh (Apple Silicon Mac + Xcode + CMake).
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$(mktemp -d /private/tmp/voiceclone-native.XXXXXX)"
runtime_sha="53e6c2066150802ad3cd4b655b31c696e78e0019"
git init "$build_root/runtime"
git -C "$build_root/runtime" remote add origin https://github.com/ServeurpersoCom/omnivoice.cpp.git
git -C "$build_root/runtime" fetch --depth 1 origin "$runtime_sha"
git -C "$build_root/runtime" checkout --detach FETCH_HEAD
git -C "$build_root/runtime" submodule update --init --recursive --depth 1
mkdir -p "$build_root/headers"
cp "$build_root/runtime/src/omnivoice.h" "$build_root/headers/"
cp "$project_root/Scripts/module.modulemap" "$build_root/headers/"
for target in iphoneos iphonesimulator; do
    build="$build_root/$target"
    cmake -S "$build_root/runtime" -B "$build" \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$target" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.2 \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF \
        -DGGML_OPENMP=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_METAL_TARGET_OS=ios -DGGML_BLAS=ON
    cmake --build "$build" --target omnivoice-core -j 6
    libtool -static -o "$build/libOmniVoiceNative.a" \
        "$build/libomnivoice-core.a" "$build/ggml/src/libggml.a" \
        "$build/ggml/src/libggml-base.a" "$build/ggml/src/libggml-cpu.a" \
        "$build/ggml/src/ggml-blas/libggml-blas.a" \
        "$build/ggml/src/ggml-metal/libggml-metal.a"
done
xcodebuild -create-xcframework \
    -library "$build_root/iphoneos/libOmniVoiceNative.a" -headers "$build_root/headers" \
    -library "$build_root/iphonesimulator/libOmniVoiceNative.a" -headers "$build_root/headers" \
    -output "$build_root/OmniVoiceNative.xcframework"
mkdir -p "$project_root/Vendor"
cp -R "$build_root/OmniVoiceNative.xcframework" "$project_root/Vendor/"
echo "Built OmniVoice at $runtime_sha. Build inputs retained at $build_root."
