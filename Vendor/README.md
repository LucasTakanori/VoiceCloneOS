# OmniVoiceNative

Static XCFramework with arm64 device and arm64 simulator slices, built from
ServeurpersoCom/omnivoice.cpp commit 53e6c2066150802ad3cd4b655b31c696e78e0019.
GGML is its pinned fork at 40e16e4a814f7fe851a0c486fb9e8c722e957830.
Metal shader source is embedded in the static library. Foundation, Metal,
MetalKit, Accelerate and libc++ are linked through the module map.

Rebuild using `bash Scripts/rebuild-omnivoice.sh`. No Python runtime is embedded.
The runtime and GGML licenses are preserved alongside this document.
