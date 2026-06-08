const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");

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
};

pub const Error = error{
    BackendInitFailed,
    ModelLoadFailed,
    ContextCreateFailed,
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

fn checkEvalResult(res: c_int, cancel_flag: ?*std.atomic.Value(bool)) Error!void {
    if (res == 0) return;
    try checkCancelled(cancel_flag);
    if (res == 2) return error.Cancelled;
    return error.EvalFailed;
}

fn checkGenerationResult(res: c_int, cancel_flag: ?*std.atomic.Value(bool)) Error!void {
    if (res == 0) return;
    try checkCancelled(cancel_flag);
    if (res == 2) return error.Cancelled;
    return error.GenerationFailed;
}

pub fn transcribe(allocator: std.mem.Allocator, opts: Options) Error![]u8 {
    try checkCancelled(opts.cancel_flag);
    if (opts.log_buffer) |buf| {
        c.llama_log_set(&log.llamaCallback, @ptrCast(buf));
        buf.appendFmt("Initializing llama.cpp backend...", .{});
    }

    c.llama_backend_init();
    defer c.llama_backend_free();
    _ = c.ggml_backend_load_all();
    try checkCancelled(opts.cancel_flag);

    var mparams = c.llama_model_default_params();
    mparams.n_gpu_layers = if (cpuOnly()) 0 else opts.n_gpu_layers;
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

    var cparams = c.llama_context_default_params();
    cparams.n_ctx = 8192;
    cparams.n_batch = 512;
    if (opts.n_threads) |n| {
        cparams.n_threads = n;
        cparams.n_threads_batch = n;
    } else {
        const cpu = std.Thread.getCpuCount() catch 4;
        cparams.n_threads = @intCast(cpu);
        cparams.n_threads_batch = @intCast(cpu);
    }

    const ctx = c.llama_init_from_model(model, cparams) orelse return error.ContextCreateFailed;
    defer c.llama_free(ctx);
    if (opts.cancel_flag) |flag| {
        c.llama_set_abort_callback(ctx, llamaAbortCallback, @ptrCast(flag));
    }
    if (opts.log_buffer) |buf| buf.appendFmt("Model loaded. Processing audio: {s}", .{opts.audio_path});
    try checkCancelled(opts.cancel_flag);

    var mtmd_params = c.mtmd_context_params_default();
    mtmd_params.use_gpu = !cpuOnly();
    mtmd_params.n_threads = cparams.n_threads;
    if (opts.cancel_flag) |flag| {
        mtmd_params.cb_eval = mtmdEvalCallback;
        mtmd_params.cb_eval_user_data = @ptrCast(flag);
    }
    const mtmd_ctx = c.mtmd_init_from_file(opts.mmproj_path.ptr, model, mtmd_params) orelse return error.MtmdInitFailed;
    defer c.mtmd_free(mtmd_ctx);

    if (!c.mtmd_support_audio(mtmd_ctx)) return error.UnsupportedAudio;

    const audio_bitmap = c.mtmd_helper_bitmap_init_from_file(mtmd_ctx, opts.audio_path.ptr, false) orelse return error.AudioLoadFailed;
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

    var n_past: c.llama_pos = 0;
    const n_chunks = c.mtmd_input_chunks_size(chunks);
    const n_batch: c_int = @intCast(cparams.n_batch);
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
        try checkEvalResult(eval_res, opts.cancel_flag);
    }
    if (opts.log_buffer) |buf| buf.appendFmt("Generating transcription...", .{});
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

        try checkGenerationResult(c.llama_decode(ctx, batch), opts.cancel_flag);
    }

    while (output.items.len > 0 and std.ascii.isWhitespace(output.items[output.items.len - 1])) {
        _ = output.pop();
    }

    const raw = try output.toOwnedSlice(allocator);
    return cleanAsrOutput(allocator, raw);
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

fn cpuOnly() bool {
    return builtin.os.tag == .windows;
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
