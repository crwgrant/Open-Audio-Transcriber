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
| `src/transcribe.zig` | llama.cpp + mtmd C API, one-shot `transcribe()` (loads model every run) |
| `src/log.zig` | Thread-safe process log buffer + llama log callback |
| `src/paths.zig` | Cross-platform home dir (`HOME` / `USERPROFILE`) |
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

## Future: persistent inference engine

**Status:** Not implemented (deferred). Documented here so a future agent session can implement it without re-discovering architecture.

### Problem

Today each click of **Transcribe** runs `transcribe.transcribe()` in a worker thread (`src/app.zig` → `workerMain`). That function is fully **stateless** and repeats the expensive setup every time:

1. `llama_backend_init()` / `ggml_backend_load_all()`
2. `llama_model_load_from_file()` — reads multi-GB GGUF from disk (~seconds)
3. `llama_init_from_model()` — allocates KV cache / context RAM
4. `mtmd_init_from_file()` — loads mmproj, builds CLIP/ASR encoder graphs
5. Only then: load audio → tokenize → eval chunks → generate text

For back-to-back transcriptions of different audio files with the **same model**, steps 1–4 are wasted work. Cancel during step 2 is also inherently slow because the whole load must unwind.

**Goal:** Keep steps 1–4 resident in memory for the lifetime of the app (or until the user picks a different model pair). Each transcription job should only run step 5 (per-audio path) plus a cheap context reset.

### Current code map (read these first)

| File | Role today |
|------|----------------|
| `src/app.zig` | Owns `App` state; spawns one worker thread per transcription; passes paths into `transcribe.transcribe()`; holds `cancel_requested` atomic |
| `src/transcribe.zig` | Single public entry: `pub fn transcribe(allocator, opts: Options) Error![]u8` — loads everything, runs job, frees everything via `defer` |
| `src/gui.zig` | **Transcribe** / **Cancel** buttons; model picker calls `selectDiscovered` / custom model paths |
| `src/log.zig` | `log.Buffer` appended from worker; `log.llamaCallback` registered via `llama_log_set` |

Worker flow (`app.zig`):

```
startTranscription() → spawn workerMain
workerMain → transcribe.transcribe(allocator, { model_path, mmproj_path, audio_path, log_buffer, cancel_flag })
           → write output file → post WorkerResult to main thread
```

`transcribe.zig` lifecycle inside one call (all torn down by `defer` at end):

```
llama_backend_init / ggml_backend_load_all
llama_model_load_from_file          ← cache target
llama_init_from_model               ← cache target
llama_set_abort_callback(ctx, ...)  ← per-job cancel; must re-register each job if ctx reused
mtmd_init_from_file                 ← cache target
mtmd_helper_bitmap_init_from_file   ← per job
mtmd_tokenize + mtmd_helper_eval_chunk_single loop  ← per job
generation loop (llama_decode)      ← per job
```

Cancellation hooks already implemented in `transcribe.zig` (preserve when refactoring):

- `llamaProgressCallback` — abort model load (`mparams.progress_callback`; return `false` to stop)
- `llamaAbortCallback` — abort `llama_decode` (return `true`; decode returns `2`)
- `mtmdEvalCallback` — abort CLIP/ASR graph via `mtmd_params.cb_eval`
- `checkEvalResult` / `checkGenerationResult` — map return code `2` → `error.Cancelled`
- `app.zig` maps `Cancelled` → `WorkerResult.cancelled` → status `"Transcription cancelled"`

Reference upstream: `deps/llama.cpp.zig/llama.cpp/tools/mtmd/mtmd-cli.cpp` keeps model loaded across multiple inputs in its REPL loop.

### Recommended design: `Engine` struct

Add **`src/engine.zig`** (or split `transcribe.zig` into `engine.zig` + thin `transcribe.zig` wrapper). Own all long-lived C pointers in one place.

```zig
pub const Engine = struct {
    allocator: std.mem.Allocator,
    backend_inited: bool = false,

    // Cache key — reload when either path changes (use normalized absolute paths for comparison)
    loaded_model_path: []const u8 = "",
    loaded_mmproj_path: []const u8 = "",

    model: ?*c.llama_model = null,
    ctx: ?*c.llama_context = null,
    mtmd_ctx: ?*c.mtmd_context = null,
    n_batch: c_int = 512,
    n_threads: c_int = 4,

    pub fn deinit(self: *Engine) void;
    pub fn ensureLoaded(self: *Engine, model_path: [:0]const u8, mmproj_path: [:0]const u8, opts: LoadOptions) Error!void;
    pub fn transcribeAudio(self: *Engine, allocator: std.mem.Allocator, job: JobOptions) Error![]u8;
    pub fn unload(self: *Engine) void;  // free model+ctx+mtmd, keep backend_inited
    fn resetContext(self: *Engine) void; // clear KV between jobs
};
```

**`LoadOptions`:** `log_buffer`, `cancel_flag`, `n_gpu_layers`, `n_threads` — same as today.

**`JobOptions`:** `audio_path`, `log_buffer`, `cancel_flag`, `max_tokens`.

#### What lives in the engine vs per job

| Resource | Lifetime | Notes |
|----------|----------|-------|
| `llama_backend_init` / `ggml_backend_load_all` | Process / app | Call **once**; do **not** `llama_backend_free` between jobs |
| `llama_model` | Until model path changes or `unload` | ~2+ GB RAM |
| `llama_context` + KV memory | Same as model | Created with `n_ctx = 8192`, `n_batch = 512` (match current) |
| `mtmd_context` | Same as model | Tied to model pointer; recreate when model reloads |
| Abort/eval callbacks on ctx/mtmd | Set at load; cancel flag pointer can stay `&App.cancel_requested` | Re-call `llama_set_abort_callback` at start of each job if safer |
| `mtmd_bitmap`, `mtmd_input_chunks`, sampler, batch | Per job | Allocate/free each transcription |
| Generation output buffer | Per job | |

#### Cache key / reload policy

```zig
fn needsReload(engine: *Engine, model: []const u8, mmproj: []const u8) bool {
    return engine.model == null
        or !std.mem.eql(u8, engine.loaded_model_path, model)
        or !std.mem.eql(u8, engine.loaded_mmproj_path, mmproj);
}
```

On reload: `unload()` old handles, then load new pair (reuse existing load sequence from `transcribe.zig`).

**When to reload:**

- First transcription after app start
- User selects a different discovered model or custom model path in GUI (`selectDiscovered`, `setCustomModel`) — lazy reload on next transcribe is simplest; optional eager unload when idle
- Transcription error that may have left context corrupt (optional conservative unload on fatal llama error)

**When NOT to reload:**

- Same model + mmproj, new audio file → skip to `transcribeAudio` only

### KV cache reset between jobs (critical)

After each job (success, cancel, or failure), clear decoder state before the next run. Otherwise leftover KV slots from a cancelled or completed run corrupt the next transcription.

Current code always creates a fresh context, so this is implicit. With a persistent context you must do it explicitly:

```c
llama_memory_clear(llama_get_memory(ctx), true);  // true = clear data buffers too
```

Call from `resetContext()` at the **start** of each `transcribeAudio` (and after cancel before returning). API in `deps/llama.cpp.zig/llama.cpp/include/llama.h`: `llama_get_memory`, `llama_memory_clear`.

Also reset `n_past` to `0` locally each job (already a local variable today).

If cancel aborts mid-`llama_decode`, llama.cpp docs note processed ubatches may remain in memory — another reason `llama_memory_clear` is required before reuse.

### Threading rules

llama.cpp + mtmd are **not thread-safe**. Today the app already serializes inference:

- `startTranscription` calls `waitForWorker()` before spawning
- Only one worker runs at a time
- Main thread never touches llama pointers

**Keep this model.** Store `Engine` on `App` but only mutate it from the worker thread:

```zig
// app.zig
engine: Engine = .{},  // deinit in App.deinit after waitForWorker
```

Worker becomes:

```zig
fn workerMain(ctx: *WorkerContext) void {
    try ctx.app.engine.ensureLoaded(ctx.model_path, ctx.mmproj_path, .{ ... });
    const text = try ctx.app.engine.transcribeAudio(allocator, .{ .audio_path = ctx.audio_path, ... });
    // write file ...
}
```

Do **not** load/unload the engine from the GUI thread without the same synchronization.

**Optional upgrade (not required for v1):** Replace per-job thread spawn with one long-lived worker thread + command queue (`Load`, `Transcribe`, `Shutdown`). Same thread-ownership rule, slightly less thread churn.

### `app.zig` changes

1. Add `engine: Engine` field; `Engine.deinit()` in `App.deinit()` after `waitForWorker()`.
2. `workerMain` calls `engine.ensureLoaded` + `engine.transcribeAudio` instead of `transcribe.transcribe`.
3. Status messages:
   - First load: `"Loading model..."` (log: `"Loading model: …"`)
   - Cache hit: `"Transcribing audio..."` only (log: `"Using loaded model"` or skip load lines)
4. Model picker while idle: no change required if reload is lazy; optionally log `"Model changed; will reload on next run"`.

Consider reusing existing `Status.loading_models` for first engine load if preloading at startup (below).

### Refactor steps (concrete checklist)

1. **Extract load logic** from `transcribe.zig` into `Engine.ensureLoaded`:
   - Move `llama_backend_init`, model load, context create, mtmd init, callback registration
   - Guard backend init with `if (!self.backend_inited)`
   - Store duplicated path strings in `loaded_model_path` / `loaded_mmproj_path`
2. **Extract job logic** into `Engine.transcribeAudio`:
   - `resetContext()` first
   - Re-register `llama_set_abort_callback` with current `cancel_flag`
   - Audio bitmap → tokenize → eval chunk loop → generation → `cleanAsrOutput`
   - Move `export fn llamaAbortCallback` etc. to `engine.zig` (or keep in one file)
3. **Keep `transcribe.transcribe`** as a thin wrapper calling stack-local `Engine` for tests, or remove and update call sites to use `App.engine` only.
4. **`App.deinit`**: `engine.deinit()` frees model/ctx/mtmd; call `llama_backend_free()` once if backend was inited.
5. **Verify cancel path**: cancel during generation, then transcribe again without restarting app — must produce clean output.
6. **Verify model switch**: pick model A, transcribe, pick model B, transcribe — must reload (watch log / timing).
7. **Memory**: expect ~2.8 GB RSS to stay allocated while app is open with Qwen3-ASR-1.7B Q8_0 loaded — acceptable tradeoff; mention in README if documenting.

### Optional UX enhancements (after core works)

- **Preload on startup:** After `bootstrap()`, if `selectedModel()` exists, spawn background worker to `ensureLoaded` so first Transcribe is fast. Use `Status.loading_models` + disable Transcribe until done.
- **Preload on model select:** When user changes dropdown, warm-load in background (cancel previous warm load if selection changes again).
- **Unload button / menu:** Call `engine.unload()` to free RAM when user is done transcribing.
- **Show cache state in UI:** e.g. status `"Model loaded (ready)"` vs `"Ready"`.

### Testing plan

| Case | Expected |
|------|----------|
| Transcribe file A, then file B, same model | Second run skips `"Loading model"` in log; much faster start |
| Cancel during generation, transcribe again | Second run succeeds; no garbage output |
| Cancel during first model load, transcribe again | Load restarts cleanly; no crash |
| Switch model in UI between runs | New load; correct output for new model |
| Quit app with model loaded | No leak sanitizer errors; all handles freed in `deinit` |
| macOS Metal + Windows CPU | Both platforms; abort callbacks on CPU path only per llama docs |

### Pitfalls (do not regress)

- Calling `llama_backend_free()` between jobs while keeping model — breaks backend; init once only.
- Forgetting `llama_memory_clear` — subtle cross-run corruption or repeated tokens.
- Freeing `mtmd_ctx` without freeing `llama_model` first — follow reverse init order: mtmd → ctx → model.
- Comparing model paths as raw strings — `"C:\foo"` vs `"c:\foo"` may spuriously reload; normalize with `std.fs.path.resolve` or compare carefully.
- Touching `Engine` from main thread while worker runs — race; keep worker-only mutation.
- `llama_log_set` — safe to call per job; keep pointing at `App.process_log`.

### Files to touch (summary)

| File | Change |
|------|--------|
| `src/engine.zig` | **New** — persistent handles, `ensureLoaded`, `transcribeAudio`, `unload`, `deinit` |
| `src/transcribe.zig` | Refactor into engine or thin wrapper |
| `src/app.zig` | Own `Engine`; worker uses engine API |
| `src/gui.zig` | Optional status text / preload disable |
| `docs/AGENT_CONTEXT.md` | Mark section implemented when done |
| `README.md` | Note RAM stays allocated while app is open (optional) |

### Success criteria

- Second and subsequent transcriptions with the same model avoid GGUF reload (confirm via log timestamps and user-visible latency).
- Cancel remains responsive (generation/audio eval still use abort callbacks on the **same** reused `llama_context`).
- Model switch and app shutdown remain correct on Windows and macOS builds.

---

## Known limitations

- llama.cpp ASR is **experimental** upstream
- Ollama model dir is scanned but blob format is not parsed (GGUF paths only)
- `zig build package` and codesign are **macOS only**
- Models are **not** bundled in the app (~2.8 GB for Qwen3-ASR-1.7B Q8_0 + mmproj)
- **Model is reloaded from disk on every transcription** — see [Future: persistent inference engine](#future-persistent-inference-engine)

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

*Last updated: Windows port verified; persistent inference engine documented as future work.*
