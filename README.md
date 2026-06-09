# Audio Transcriber (Zig)

Desktop app for transcribing audio files to text using [llama.cpp](https://github.com/ggml-org/llama.cpp) and [Qwen3-ASR](https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF).

Built with:

- [llama.cpp.zig](https://github.com/Deins/llama.cpp.zig) — vendored under `deps/llama.cpp.zig` (llama.cpp submodule updated to current master for ASR/mtmd support)
- [zgui](https://github.com/zig-gamedev/zgui) + [zglfw](https://github.com/zig-gamedev/zglfw) — Dear ImGui desktop UI
- llama.cpp `libmtmd` — multimodal audio encoder (wav/mp3/flac via miniaudio)

## Default model

The default model is **ggml-org/Qwen3-ASR-1.7B**, expected at:

```
~/.lmstudio/models/ggml-org/Qwen3-ASR-1.7B-GGUF/
  Qwen3-ASR-1.7B-Q8_0.gguf
  mmproj-Qwen3-ASR-1.7B-bf16.gguf
```

Both the main GGUF and matching `mmproj` file are required.

## Model discovery

On startup the app scans:

- `~/.lmstudio/models`
- `~/.ollama/models`
- `~/.cache/huggingface/hub`

It pairs each `*.gguf` model with a sibling `mmproj-<same-stem>.gguf` when present.

Use the model dropdown or **Browse model pair...** / right-click context menu to pick a different model. Your choice is saved to `~/.config/audio-transcriber/config.json`.

## Requirements

- Zig 0.16+
- CMake (e.g. `brew install cmake`)
- macOS with Xcode command-line tools (Metal backend)
- A Qwen3-ASR GGUF + mmproj pair (see above)

## Build & run

```bash
zig build
zig build run
```

The first build compiles llama.cpp via CMake into `.zig-cache/llama-cpp/` (may take a few minutes).

### Windows (Vulkan GPU)

Install the [LunarG Vulkan SDK](https://vulkan.lunarg.com/), then set `VULKAN_SDK` and build with the Vulkan backend enabled:

```powershell
$env:VULKAN_SDK = "C:/VulkanSDK/1.4.350.0"   # adjust to your install path
zig build -Dggml-vulkan=true -Doptimize=ReleaseFast
zig build run -Dggml-vulkan=true -Doptimize=ReleaseFast
```

`VULKAN_SDK` must be set whenever you build with `-Dggml-vulkan=true`. The first Vulkan build is slower (shader compilation). Use the **Runtime** dropdown in the app to pick CPU or Vulkan.

CPU-only on Windows (no Vulkan SDK):

```powershell
zig build -Doptimize=ReleaseFast
zig build run -Doptimize=ReleaseFast
```

### Copying the .exe to another PC

Release builds use `-march=native` for llama.cpp CPU code, so an `.exe` built on one PC may crash on another with **illegal instruction** (`0xc000001d`) at startup. Rebuild with a portable CPU baseline before copying:

```powershell
$env:VULKAN_SDK = "C:/VulkanSDK/1.4.350.0"   # if using Vulkan
zig build -Dcpu-baseline=true -Dggml-vulkan=true -Doptimize=ReleaseFast
```

Copy `zig-out\bin\audio-transcriber.exe` (and `audio-transcriber.pdb` if you want crash symbols). The target PC still needs up-to-date GPU drivers for Vulkan; CPU-only builds have no extra runtime dependencies.

## Package (standalone macOS app)

Build a release `.app` bundle you can copy to `/Applications`:

```bash
zig build package -Doptimize=ReleaseFast
```

Output:

```
zig-out/Audio Transcriber.app
```

Open it from Finder or run:

```bash
open "zig-out/Audio Transcriber.app"
```

The bundle contains only the app binary and `Info.plist`. ASR model files are still loaded from disk (default: `~/.lmstudio/models/...`) or chosen via **Browse model pair...** in the UI.

To refresh a local copy in the project folder:

```bash
rm -rf "Audio Transcriber"
cp -R "zig-out/Audio Transcriber.app" "Audio Transcriber"
```

### Code signing

Signing is optional. Pass `-Dcodesign-identity` to sign as part of `zig build package`.

Ad-hoc signing (fine for local use on your Mac):

```bash
zig build package -Doptimize=ReleaseFast -Dcodesign-identity=-
```

Developer ID signing (for distribution; requires a valid certificate in your keychain):

```bash
zig build package -Doptimize=ReleaseFast \
  -Dcodesign-identity="Developer ID Application: Your Name (TEAMID)"
```

List available signing identities:

```bash
security find-identity -v -p codesigning
```

Optional entitlements plist:

```bash
zig build package -Doptimize=ReleaseFast \
  -Dcodesign-identity="Developer ID Application: Your Name (TEAMID)" \
  -Dcodesign-entitlements=packaging/entitlements.plist
```

For distribution outside your Mac, notarize the signed `.app` with Apple after packaging.

## Usage

1. Confirm or select an ASR model (default: Qwen3-ASR-1.7B from LM Studio path).
2. Choose an audio file (wav, mp3, flac).
3. Choose an output `.txt` path (defaults to `<audio-stem>.txt`).
4. Click **Transcribe**.

## Agent / handoff context

For continuing development on another machine (e.g. Windows port), see **[docs/AGENT_CONTEXT.md](docs/AGENT_CONTEXT.md)** — architecture, macOS fixes, and Windows port checklist.

## Notes

- llama.cpp.zig upstream targets Zig 0.14 and an older llama.cpp without ASR. This project vendors llama.cpp.zig but uses a current llama.cpp submodule and links `libmtmd` built by CMake.
- GPU acceleration uses Metal on macOS (`-DGGML_METAL=ON`) or Vulkan on Windows (`-Dggml-vulkan=true`, requires Vulkan SDK).
- Audio transcription in llama.cpp is still marked experimental upstream.
