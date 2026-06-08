# Agent context — Audio Transcriber (Zig)

This document captures project context established during macOS development. Use it when continuing work on another machine (especially a **Windows** port) or when onboarding a new Cursor agent session.

**Quick start for a Windows agent:**

```
Read this file, README.md, build.zig, and src/*.zig.
Goal: native Windows build (audio-transcriber.exe). Build llama.cpp on Windows via CMake; do not assume macOS paths or Metal.
```

---

## Project summary

Desktop GUI app that transcribes audio (wav, mp3, flac) to text using:

- **llama.cpp** `libmtmd` — multimodal audio encoder + ASR
- **Qwen3-ASR** (default: `ggml-org/Qwen3-ASR-1.7B-GGUF`) — requires both a `.gguf` model and matching `mmproj-*.gguf`
- **zgui + zglfw + zopengl** — Dear ImGui UI with GLFW/OpenGL backend

Zig **0.16+** is required throughout.

---

## Repository layout

| Path | Purpose |
|------|---------|
| `src/main.zig` | Entry point |
| `src/gui.zig` | GLFW window, zgui loop, HiDPI scaling |
| `src/app.zig` | App state, background transcription thread |
| `src/transcribe.zig` | llama.cpp + mtmd C API, generation loop |
| `src/models.zig` | GGUF/mmproj discovery and pairing |
| `src/config.zig` | Persists model choice to config JSON |
| `src/dialog.zig` | File picker API (C externs) |
| `src/dialog_macos.m` | macOS NSOpenPanel / NSSavePanel |
| `src/io_util.zig` | Zig 0.16 `std.Io` file helpers |
| `build.zig` | CMake llama build, deps, macOS package/codesign |
| `build.zig.zon` | zgui, zglfw, zopengl dependencies |
| `packaging/Info.plist` | macOS app bundle metadata |
| `deps/llama.cpp.zig/` | Vendored wrapper; **llama.cpp submodule on current master** (ASR/mtmd) |

CMake output (not committed): `.zig-cache/llama-cpp/`

---

## What works on macOS (verified)

- GUI launches with correct Retina scaling and mouse alignment
- Model discovery under `~/.lmstudio`, `~/.ollama`, `~/.cache/huggingface`
- Audio file picker supports **wav, mp3, flac**
- Transcription produces real text (Qwen3-ASR tested on a long mp3)
- `zig build package -Doptimize=ReleaseFast` → `zig-out/Audio Transcriber.app`
- Optional codesign: `-Dcodesign-identity=-` (ad-hoc) or Developer ID

---

## Critical implementation details (do not regress)

### 1. OpenGL loader (GUI startup crash fix)

zgui's `glfw_opengl3` backend uses `IMGUI_IMPL_OPENGL_LOADER_CUSTOM`. **Must** call before `zgui.backend.init()`:

```zig
try zopengl.loadCoreProfile(zglfw.getProcAddress, 3, 3);
```

Use **zopengl** from git `29908b1ba2d91baf91e348f6cd192630488d77b6` or newer (Zig 0.16 compatible).

Shutdown order:

```zig
defer zgui.backend.deinit();  // before zgui.deinit()
defer zgui.deinit();
```

### 2. HiDPI / Retina (GUI scaling)

zgui's OpenGL backend overwrites GLFW's display scale. After `zgui.backend.newFrame()`, restore:

- `DisplaySize` = logical window size (`window.getSize()`)
- `DisplayFramebufferScale` = `framebuffer_size / window_size` (not `1.0`)

Do **not** combine `scaleAllSizes()` with framebuffer scale (causes black screen / off-screen UI).

### 3. Transcription generation loop

After `mtmd_helper_eval_chunks`, each sampled token **must** be fed back via `llama_decode`. Without this, output repeats one token forever (e.g. `languagelanguage...`).

Prompt format (matches llama.cpp `common_chat_get_asr_prompt`):

- User text: `<__media__>Transcribe audio to text` (marker **before** text)
- Apply model chat template via `llama_chat_apply_template`
- Sampler: `llama_sampler_init_dist(0)` (greedy / temp 0)
- Post-process: strip Qwen3-ASR prefix up to `<asr_text>` in `cleanAsrOutput()`

Reference: upstream `tools/mtmd/mtmd-cli.cpp` and `common/chat.cpp` (`asr_preset.user = "Transcribe audio to text"`).

### 4. Audio file dialog filters

macOS `allowedFileTypes` must list multiple extensions: `wav,mp3,flac` (comma-separated in `dialog_macos.m`).

---

## Build system (macOS, current)

### Dependencies (build.zig.zon)

- **zgui** — `glfw_opengl3` backend
- **zglfw** — GLFW 3.4
- **zopengl** — OpenGL loader (required for zgui on macOS)

### llama.cpp via CMake

- Source: `deps/llama.cpp.zig/llama.cpp`
- Build dir: `.zig-cache/llama-cpp/`
- Flags: `-DGGML_METAL=ON`, static libs, targets `llama` + `mtmd`
- **macOS-only today:** cmake path hardcoded to `/opt/homebrew/bin/cmake`
- Linked static libs (macOS `.a`):
  - `libmtmd.a`, `libllama.a`, `libggml.a`, `libggml-cpu.a`, `libggml-base.a`, `libggml-metal.a`, `libggml-blas.a`

### macOS frameworks linked

Foundation, AppKit, Metal, MetalKit, Accelerate, OpenGL

### Package step (macOS only)

```bash
zig build package -Doptimize=ReleaseFast
zig build package -Doptimize=ReleaseFast -Dcodesign-identity=-
```

---

## macOS-only code (must be split or replaced for Windows)

| Item | Location | Windows replacement |
|------|----------|---------------------|
| AppKit file dialogs | `src/dialog_macos.m` | `dialog_windows.cpp` (IFileOpenDialog or `GetOpenFileNameW`) |
| Metal GPU backend | `build.zig` CMake `-DGGML_METAL=ON` | `-DGGML_METAL=OFF`; CPU and/or `-DGGML_CUDA=ON` / `-DGGML_VULKAN=ON` |
| Static `.a` libraries | `addLlamaLibs()` | CMake `.lib` paths under MSVC build tree |
| macOS frameworks | `build.zig` | `opengl32`, `gdi32`, `user32`, `comdlg32`, etc. |
| `HOME` env var | `models.zig`, `config.zig` | `USERPROFILE` (or cross-platform home helper) |
| `.app` packaging | `addPackageStep()` | Ship `zig-out/bin/audio-transcriber.exe` (zip/installer) |

---

## Windows port checklist

Build **natively on Windows** (not cross-compile llama.cpp from Mac).

### Prerequisites

- Zig 0.16+
- CMake on PATH
- Visual Studio Build Tools (Desktop development with C++) or full Visual Studio
- Git (submodules: `git submodule update --init --recursive`)

### Suggested `build.zig` changes

1. Resolve `cmake` from PATH instead of `/opt/homebrew/bin/cmake`
2. Branch on `target.result.os.tag`:
   - **macOS:** current Metal + frameworks + `dialog_macos.m`
   - **Windows:** `GGML_METAL=OFF`, link Windows OpenGL (`opengl32`), add `dialog_windows.cpp`
3. `addLlamaLibs()` — platform-specific lib names and paths (MSVC generator produces `.lib` under `.zig-cache/llama-cpp/`)
4. Keep separate CMake build dirs per OS/arch if needed (e.g. `.zig-cache/llama-cpp-win/` vs `llama-cpp/`) to avoid mixing artifacts

### Suggested source changes

1. **`src/paths.zig`** (new) — `homeDir(allocator)` using `HOME` or `USERPROFILE`
2. **`models.zig`** — use `homeDir`; Windows search roots:
   - `.lmstudio\models`
   - `.ollama\models`
   - `.cache\huggingface\hub`
3. **`config.zig`** — config at `%USERPROFILE%\.config\audio-transcriber\config.json` (or `%APPDATA%\audio-transcriber\config.json`)
4. **`dialog.zig`** — compile-time or `build.zig` selects macOS vs Windows C implementation
5. **`gui.zig`** — should work on Windows with same zopengl + display-scale logic; test DPI scaling

### Windows build commands (target state)

```powershell
zig build -Doptimize=ReleaseFast
zig build run
# Output: zig-out\bin\audio-transcriber.exe
```

### GPU on Windows (later)

- CUDA: `-DGGML_CUDA=ON` if NVIDIA toolkit present
- Vulkan: `-DGGML_VULKAN=ON`
- Start with **CPU-only** to validate the port

---

## Default model paths

### macOS

```
~/.lmstudio/models/ggml-org/Qwen3-ASR-1.7B-GGUF/
  Qwen3-ASR-1.7B-Q8_0.gguf
  mmproj-Qwen3-ASR-1.7B-bf16.gguf
```

Note: mmproj quant suffix may differ from model; `models.zig` uses fuzzy stem matching.

### Windows (expected)

```
%USERPROFILE%\.lmstudio\models\ggml-org\Qwen3-ASR-1.7B-GGUF\
```

---

## Submodule setup

```bash
git submodule update --init --recursive
```

The llama.cpp submodule inside `deps/llama.cpp.zig/` must be **current master** (includes mtmd ASR). Upstream llama.cpp.zig alone is too old for ASR.

---

## Known limitations

- llama.cpp ASR is **experimental** upstream
- Ollama model dir is scanned but blob format is not parsed (GGUF paths only)
- `zig build package` and codesign are **macOS only**
- Models are **not** bundled in the app (~2.8 GB for Qwen3-ASR-1.7B Q8_0 + mmproj)

---

## Bootstrap prompt (copy into Windows Cursor agent)

```markdown
Implement a native Windows build for audio-transcriber-zig.

Read docs/AGENT_CONTEXT.md, README.md, and build.zig first.

Constraints:
- Zig 0.16+, CMake, MSVC build tools
- Native Windows build (not cross-compile from Mac)
- CPU-only llama.cpp first (GGML_METAL=OFF)
- Port file dialogs and USERPROFILE paths
- Keep macOS build working

Success criteria:
- zig build -Doptimize=ReleaseFast produces zig-out/bin/audio-transcriber.exe
- App opens, picks model/audio/output, transcribes a short mp3

Reference macOS fixes in AGENT_CONTEXT.md (zopengl loader, llama_decode loop, HiDPI, prompt format).
```

---

## History (macOS development session)

Issues encountered and fixed:

1. **Bus error at ImGui init** — missing `zopengl.loadCoreProfile`
2. **Tiny UI + wrong mouse** — Retina display scale overwritten by zgui backend
3. **Black screen after scale fix** — double-scaling (`scaleAllSizes` + framebuffer scale)
4. **mp3 grayed out in picker** — filter only allowed `wav`
5. **Garbage output (`language` repeated)** — missing `llama_decode` in generation loop; wrong prompt marker order
6. **Packaging** — `zig build package` + optional `-Dcodesign-identity`

---

*Last updated for macOS-working state. Update this file when the Windows port lands.*
