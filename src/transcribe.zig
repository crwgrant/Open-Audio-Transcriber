const std = @import("std");
const log = @import("log.zig");
const runtime_mod = @import("runtime.zig");

const c = @cImport({
    @cDefine("UINTPTR_MAX", "0xFFFFFFFFFFFFFFFF");
    @cInclude("llama_c.h");
});

pub const Options = struct {
    model_path: [:0]const u8,
    mmproj_path: [:0]const u8,
    audio_path: [:0]const u8,
    n_gpu_layers: c_int = -1,
    n_threads: ?c_int = null,
    max_tokens: c_int = 4096,
    log_buffer: ?*log.Buffer = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    runtime: runtime_mod.Id = .cpu,
};

pub const Error = error{
    BackendInitFailed,
    ModelLoadFailed,
    ContextCreateFailed,
    ContextTooLarge,
    MtmdInitFailed,
    AudioLoadFailed,
    PromptFormatFailed,
    TokenizeFailed,
    EvalFailed,
    GenerationFailed,
    UnsupportedAudio,
    Cancelled,
} || std.mem.Allocator.Error;

fn isCancelled(cancel_flag: ?*std.atomic.Value(bool)) bool {
    if (cancel_flag) |flag| return flag.load(.acquire);
    return false;
}

fn checkCancelled(cancel_flag: ?*std.atomic.Value(bool)) Error!void {
    if (isCancelled(cancel_flag)) return error.Cancelled;
}

fn checkEvalResult(res: c_int, cancel_flag: ?*std.atomic.Value(bool), log_buffer: ?*log.Buffer) Error!void {
    if (res == 0) return;
    try checkCancelled(cancel_flag);
    if (res == 2) return error.Cancelled;
    if (log_buffer) |buf| {
        buf.appendFmt("Inference eval failed (code {d})", .{res});
        switch (res) {
            1 => buf.append(" — KV cache could not fit this batch (context may be too small for this audio)"),
            -2 => buf.append(" — GPU memory allocation failed"),
            -3 => buf.append(" — GPU compute failed"),
            else => {},
        }
    }
    return error.EvalFailed;
}

fn checkGenerationResult(res: c_int, cancel_flag: ?*std.atomic.Value(bool), log_buffer: ?*log.Buffer) Error!void {
    if (res == 0) return;
    try checkCancelled(cancel_flag);
    if (res == 2) return error.Cancelled;
    if (log_buffer) |buf| buf.appendFmt("Token generation failed (code {d})", .{res});
    return error.GenerationFailed;
}

threadlocal var active_log_buffer: ?*log.Buffer = null;

export fn llamaLogCallback(level: c_uint, text: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (level < 3) return; // WARN and ERROR only
    if (active_log_buffer) |buf| buf.append(std.mem.span(text));
}

fn threadCount(opts: Options) c_int {
    if (opts.n_threads) |n| return n;
    return @intCast(std.Thread.getCpuCount() catch 4);
}

fn requiredContextSize(model: *c.llama_model, chunks: *c.mtmd_input_chunks, max_gen: c_int) Error!u32 {
    const n_pos = c.mtmd_helper_get_n_pos(chunks);
    const model_max = c.llama_model_n_ctx_train(model);
    const required = @as(i64, n_pos) + max_gen + 256;
    if (required > model_max) return error.ContextTooLarge;
    const min_ctx: u32 = 8192;
    const sized = @as(u32, @intCast(required));
    return @max(sized, min_ctx);
}

pub fn transcribe(allocator: std.mem.Allocator, opts: Options) Error![]u8 {
    try checkCancelled(opts.cancel_flag);

    active_log_buffer = opts.log_buffer;
    defer active_log_buffer = null;
    if (opts.log_buffer != null) c.llama_log_set(llamaLogCallback, null);

    c.llama_backend_init();
    defer c.llama_backend_free();
    _ = c.ggml_backend_load_all();
    try checkCancelled(opts.cancel_flag);

    var mparams = c.llama_model_default_params();
    mparams.n_gpu_layers = if (opts.runtime.useGpu()) opts.n_gpu_layers else 0;
    if (opts.cancel_flag) |flag| {
        mparams.progress_callback = llamaProgressCallback;
        mparams.progress_callback_user_data = @ptrCast(flag);
    }
    if (opts.log_buffer) |buf| buf.appendFmt("Loading model: {s}", .{opts.model_path});
    const model = c.llama_model_load_from_file(opts.model_path.ptr, mparams) orelse {
        try checkCancelled(opts.cancel_flag);
        return error.ModelLoadFailed;
    };
    defer c.llama_model_free(model);
    try checkCancelled(opts.cancel_flag);

    const n_threads = threadCount(opts);
    const decode_batch: u32 = switch (opts.runtime) {
        .vulkan => 256,
        else => 512,
    };

    var mtmd_params = c.mtmd_context_params_default();
    mtmd_params.use_gpu = opts.runtime.useGpuForMmproj();
    mtmd_params.n_threads = n_threads;
    mtmd_params.print_timings = false;
    if (opts.runtime == .vulkan) {
        mtmd_params.flash_attn_type = c.LLAMA_FLASH_ATTN_TYPE_DISABLED;
    }
    if (opts.cancel_flag) |flag| {
        mtmd_params.cb_eval = mtmdEvalCallback;
        mtmd_params.cb_eval_user_data = @ptrCast(flag);
    }
    const mtmd_ctx = c.mtmd_init_from_file(opts.mmproj_path.ptr, model, mtmd_params) orelse return error.MtmdInitFailed;
    defer c.mtmd_free(mtmd_ctx);

    if (!c.mtmd_support_audio(mtmd_ctx)) return error.UnsupportedAudio;

    if (opts.log_buffer) |buf| buf.appendFmt("Processing audio: {s}", .{opts.audio_path});

    const audio_wrapper = c.mtmd_helper_bitmap_init_from_file(mtmd_ctx, opts.audio_path.ptr, false);
    const audio_bitmap = audio_wrapper.bitmap;
    if (audio_bitmap == null) return error.AudioLoadFailed;
    defer c.mtmd_bitmap_free(audio_bitmap);
    try checkCancelled(opts.cancel_flag);

    const marker = c.mtmd_default_marker();
    const user_prompt = try std.fmt.allocPrint(allocator, "{s}Transcribe audio to text", .{std.mem.span(marker)});
    defer allocator.free(user_prompt);

    const formatted = try formatChatPrompt(allocator, model, user_prompt);
    defer allocator.free(formatted);

    const prompt_z = try allocator.dupeZ(u8, formatted);
    defer allocator.free(prompt_z);

    var text = c.mtmd_input_text{
        .text = prompt_z.ptr,
        .add_special = true,
        .parse_special = true,
    };

    const chunks = c.mtmd_input_chunks_init() orelse return error.TokenizeFailed;
    defer c.mtmd_input_chunks_free(chunks);

    var bitmaps: [1]?*const c.mtmd_bitmap = .{audio_bitmap};
    const tok_res = c.mtmd_tokenize(mtmd_ctx, chunks, &text, &bitmaps, 1);
    if (tok_res != 0) return error.TokenizeFailed;

    const n_ctx = try requiredContextSize(model, chunks, opts.max_tokens);
    if (opts.log_buffer) |buf| {
        buf.appendFmt(
            "Prompt+audio positions: {d}, context size: {d} tokens",
            .{ c.mtmd_helper_get_n_pos(chunks), n_ctx },
        );
    }

    var cparams = c.llama_context_default_params();
    cparams.n_ctx = n_ctx;
    cparams.n_batch = decode_batch;
    cparams.n_ubatch = decode_batch;
    cparams.no_perf = false;
    cparams.n_threads = n_threads;
    cparams.n_threads_batch = n_threads;

    const ctx = c.llama_init_from_model(model, cparams) orelse return error.ContextCreateFailed;
    defer c.llama_free(ctx);
    if (opts.cancel_flag) |flag| {
        c.llama_set_abort_callback(ctx, llamaAbortCallback, @ptrCast(flag));
    }
    if (opts.log_buffer) |buf| buf.append("Model and context ready");
    try checkCancelled(opts.cancel_flag);

    var n_past: c.llama_pos = 0;
    const n_chunks = c.mtmd_input_chunks_size(chunks);
    const n_batch: c_int = @intCast(decode_batch);
    var i_chunk: usize = 0;
    while (i_chunk < n_chunks) : (i_chunk += 1) {
        try checkCancelled(opts.cancel_flag);
        const chunk_logits_last = (i_chunk == n_chunks - 1);
        const chunk = c.mtmd_input_chunks_get(chunks, i_chunk);
        const eval_res = c.mtmd_helper_eval_chunk_single(
            mtmd_ctx,
            ctx,
            chunk,
            n_past,
            0,
            n_batch,
            chunk_logits_last,
            &n_past,
        );
        try checkEvalResult(eval_res, opts.cancel_flag, opts.log_buffer);
    }
    try checkCancelled(opts.cancel_flag);

    const vocab = c.llama_model_get_vocab(model);
    const sampler = c.llama_sampler_chain_init(c.llama_sampler_chain_default_params());
    defer c.llama_sampler_free(sampler);
    c.llama_sampler_chain_add(sampler, c.llama_sampler_init_dist(0));

    var batch = c.llama_batch_init(1, 0, 1);
    defer c.llama_batch_free(batch);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var i: c_int = 0;
    while (i < opts.max_tokens) : (i += 1) {
        try checkCancelled(opts.cancel_flag);

        const token = c.llama_sampler_sample(sampler, ctx, -1);
        if (c.llama_vocab_is_eog(vocab, token)) break;
        c.llama_sampler_accept(sampler, token);

        var piece_buf: [256]u8 = undefined;
        const n_piece = c.llama_token_to_piece(vocab, token, &piece_buf, piece_buf.len, 0, true);
        if (n_piece > 0) {
            try output.appendSlice(allocator, piece_buf[0..@intCast(n_piece)]);
        }

        batch.n_tokens = 1;
        batch.token[0] = token;
        batch.pos[0] = n_past;
        batch.n_seq_id[0] = 1;
        batch.seq_id[0][0] = 0;
        batch.logits[0] = 1;
        n_past += 1;

        try checkGenerationResult(c.llama_decode(ctx, batch), opts.cancel_flag, opts.log_buffer);
    }

    if (opts.log_buffer) |buf| appendPerfStats(buf, ctx);

    while (output.items.len > 0 and std.ascii.isWhitespace(output.items[output.items.len - 1])) {
        _ = output.pop();
    }

    const raw = try output.toOwnedSlice(allocator);
    return cleanAsrOutput(allocator, raw);
}

fn appendPerfStats(buf: *log.Buffer, ctx: *c.llama_context) void {
    const data = c.llama_perf_context(ctx);

    if (data.n_p_eval > 0) {
        const n = @as(f64, @floatFromInt(data.n_p_eval));
        const ms_per_token = data.t_p_eval_ms / n;
        const tokens_per_sec = 1e3 / data.t_p_eval_ms * n;
        buf.appendFmt(
            "prompt eval time = {d: >10.2} ms / {d: >5} tokens ({d: >8.2} ms per token, {d: >8.2} tokens per second)",
            .{ data.t_p_eval_ms, data.n_p_eval, ms_per_token, tokens_per_sec },
        );
    }

    if (data.n_eval > 0) {
        const n = @as(f64, @floatFromInt(data.n_eval));
        const ms_per_token = data.t_eval_ms / n;
        const tokens_per_sec = 1e3 / data.t_eval_ms * n;
        buf.appendFmt(
            "       eval time = {d: >10.2} ms / {d: >5} tokens ({d: >8.2} ms per token, {d: >8.2} tokens per second)",
            .{ data.t_eval_ms, data.n_eval, ms_per_token, tokens_per_sec },
        );
    }

    const total_tokens = data.n_p_eval + data.n_eval;
    if (total_tokens > 0) {
        const total_ms = data.t_p_eval_ms + data.t_eval_ms;
        buf.appendFmt("      total time = {d: >10.2} ms / {d: >5} tokens", .{ total_ms, total_tokens });
    }

    buf.appendFmt("   graphs reused = {d: >10}", .{data.n_reused});
}

fn cleanAsrOutput(allocator: std.mem.Allocator, raw: []u8) Error![]u8 {
    defer allocator.free(raw);

    const marker = "<asr_text>";
    if (std.mem.indexOf(u8, raw, marker)) |idx| {
        const start = idx + marker.len;
        return try allocator.dupe(u8, std.mem.trim(u8, raw[start..], &std.ascii.whitespace));
    }

    return try allocator.dupe(u8, std.mem.trim(u8, raw, &std.ascii.whitespace));
}

fn formatChatPrompt(allocator: std.mem.Allocator, model: *c.llama_model, user_content: []const u8) Error![]u8 {
    const tmpl = c.llama_model_chat_template(model, null);
    if (tmpl == null) {
        return try allocator.dupe(u8, user_content);
    }

    const user_z = try allocator.dupeZ(u8, user_content);
    defer allocator.free(user_z);

    var msg = c.llama_chat_message{
        .role = "user",
        .content = user_z.ptr,
    };

    var buf: [16384]u8 = undefined;
    const written = c.llama_chat_apply_template(tmpl, &msg, 1, true, &buf, @intCast(buf.len));
    if (written < 0) return error.PromptFormatFailed;
    return try allocator.dupe(u8, buf[0..@intCast(written)]);
}

export fn llamaAbortCallback(data: ?*anyopaque) callconv(.c) bool {
    const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(data));
    return flag.load(.acquire);
}

export fn llamaProgressCallback(progress: f32, data: ?*anyopaque) callconv(.c) bool {
    _ = progress;
    const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(data));
    return !flag.load(.acquire);
}

export fn mtmdEvalCallback(t: ?*c.struct_ggml_tensor, ask: bool, data: ?*anyopaque) callconv(.c) bool {
    _ = t;
    const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(data));
    if (flag.load(.acquire)) {
        if (ask) return true;
        return false;
    }
    if (ask) return false;
    return true;
}
