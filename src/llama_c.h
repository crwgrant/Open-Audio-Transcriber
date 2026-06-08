#ifndef AUDIO_TRANSCRIBER_LLAMA_C_H
#define AUDIO_TRANSCRIBER_LLAMA_C_H

#include <stdint.h>
#include <stddef.h>

/* zig @cImport cannot parse ui64/u integer suffixes in #if (ggml.h:235). */
#undef UINTPTR_MAX
#define UINTPTR_MAX 0xFFFFFFFFFFFFFFFF

#include "llama.h"
#include "ggml-backend.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#endif
