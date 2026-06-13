const std = @import("std");

const perf_profile = @import("perf_profile.zig");
const runtime_mod = @import("runtime.zig");
const audio_probe = @import("audio_probe.zig");

/// Matches transcribe.Options.max_tokens default.
pub const default_max_generation_tokens: u32 = 4096;

/// Qwen3-ASR models support up to this training context (1.7B / 0.6B).
pub const model_max_context_tokens: u32 = 65536;

/// ~750 embedding positions per 30 seconds of audio (llama.cpp mtmd-audio).
const audio_positions_per_second: f64 = 750.0 / 30.0;

/// Chat template + marker overhead (rough).
const est_prompt_positions: u32 = 200;

const context_margin: u32 = 256;
const min_context_tokens: u32 = 8192;

pub const Estimate = struct {
    duration_secs: ?f64,
    est_positions: ?u32,
    est_context_tokens: ?u32,
    /// Multi-line text for the UI (duration, token estimates, hints).
    text: []const u8,
    /// Use warning color (VRAM / long file guidance).
    warn: bool,
    /// Exceeds model context limit — transcription will fail without splitting.
    critical: bool,
    /// True while a background thread is probing the file.
    loading: bool = false,

    pub fn deinit(self: *Estimate, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = .{
            .duration_secs = null,
            .est_positions = null,
            .est_context_tokens = null,
            .text = "",
            .warn = false,
            .critical = false,
            .loading = false,
        };
    }
};

pub fn loadingPlaceholder(allocator: std.mem.Allocator) !Estimate {
    const text = try allocator.dupe(u8, "Analyzing audio file...");
    return .{
        .duration_secs = null,
        .est_positions = null,
        .est_context_tokens = null,
        .text = text,
        .warn = false,
        .critical = false,
        .loading = true,
    };
}

pub fn analyze(
    allocator: std.mem.Allocator,
    audio_path: []const u8,
    runtime: runtime_mod.Id,
    rtf_profile: perf_profile.Profile,
) !Estimate {
    const duration = probeDuration(allocator, audio_path);

    var est_positions: ?u32 = null;
    var est_context: ?u32 = null;
    if (duration) |secs| {
        const audio_pos = estimateAudioPositions(secs);
        const positions = audio_pos + est_prompt_positions;
        est_positions = positions;
        est_context = computeContextSize(positions, default_max_generation_tokens);
    }

    const critical = if (est_context) |ctx| ctx > model_max_context_tokens else false;
    const warn = critical or (if (est_context) |ctx| ctx > 16384 else false) or
        (runtime == .vulkan and if (est_context) |ctx| ctx > 10000 else false);

    const measured_rtf = rtf_profile.get(runtime);
    const text = try formatEstimate(
        allocator,
        duration,
        est_positions,
        est_context,
        runtime,
        critical,
        measured_rtf,
    );

    return .{
        .duration_secs = duration,
        .est_positions = est_positions,
        .est_context_tokens = est_context,
        .text = text,
        .warn = warn,
        .critical = critical,
    };
}

fn estimateAudioPositions(duration_secs: f64) u32 {
    const raw = duration_secs * audio_positions_per_second;
    return @intFromFloat(@ceil(raw));
}

fn computeContextSize(positions: u32, max_gen: u32) u32 {
    const required = positions + max_gen + context_margin;
    return @max(required, min_context_tokens);
}

fn probeDuration(allocator: std.mem.Allocator, path: []const u8) ?f64 {
    _ = allocator;
    return audio_probe.probeDurationSeconds(path);
}

fn formatDuration(buf: []u8, secs: f64) []const u8 {
    const total: u64 = @intFromFloat(@max(secs, 0.0));
    const hours = total / 3600;
    const minutes = (total % 3600) / 60;
    const seconds = total % 60;
    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}:{d:02}:{d:02}", .{ hours, minutes, seconds }) catch "0:00";
    }
    return std.fmt.bufPrint(buf, "{d}:{d:02}", .{ minutes, seconds }) catch "0:00";
}

fn appendTimeEstimate(
    lines: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    duration_secs: f64,
    runtime: runtime_mod.Id,
    measured_rtf: ?f64,
) !void {
    var low_buf: [32]u8 = undefined;
    var high_buf: [32]u8 = undefined;
    var single_buf: [32]u8 = undefined;

    if (measured_rtf) |rtf| {
        const est_secs = duration_secs * rtf;
        const est_text = formatDuration(&single_buf, est_secs);
        try lines.appendSlice(allocator, "Est. transcribe time: ~");
        try lines.appendSlice(allocator, est_text);
        var rtf_buf: [16]u8 = undefined;
        const rtf_str = try std.fmt.bufPrint(&rtf_buf, "{d:.1}x", .{rtf});
        try lines.appendSlice(allocator, " (based on last run, ");
        try lines.appendSlice(allocator, rtf_str);
        try lines.appendSlice(allocator, " realtime)\n");
        return;
    }

    const range = perf_profile.defaultRtfRange(runtime);
    const low_text = formatDuration(&low_buf, duration_secs * range.low);
    const high_text = formatDuration(&high_buf, duration_secs * range.high);
    try lines.appendSlice(allocator, "Est. transcribe time: ~");
    try lines.appendSlice(allocator, low_text);
    try lines.appendSlice(allocator, "–");
    try lines.appendSlice(allocator, high_text);
    try lines.appendSlice(allocator, " (varies by CPU/GPU; refines after first run)\n");
}

fn formatEstimate(
    allocator: std.mem.Allocator,
    duration: ?f64,
    est_positions: ?u32,
    est_context: ?u32,
    runtime: runtime_mod.Id,
    critical: bool,
    measured_rtf: ?f64,
) ![]u8 {
    var lines: std.ArrayList(u8) = .empty;
    errdefer lines.deinit(allocator);

    if (duration == null) {
        try lines.appendSlice(allocator, "Duration: unknown (unsupported or unreadable audio file)\n");
        try lines.appendSlice(allocator, "Context size is chosen automatically when you transcribe.");
        return lines.toOwnedSlice(allocator);
    }

    var dur_buf: [32]u8 = undefined;
    const dur_text = formatDuration(&dur_buf, duration.?);
    try lines.appendSlice(allocator, "Duration: ");
    try lines.appendSlice(allocator, dur_text);
    try lines.appendSlice(allocator, "\n");

    try appendTimeEstimate(&lines, allocator, duration.?, runtime, measured_rtf);

    if (est_positions) |pos| {
        var num_buf: [32]u8 = undefined;
        const pos_str = try std.fmt.bufPrint(&num_buf, "~{d}", .{pos});
        try lines.appendSlice(allocator, "Est. prompt+audio positions: ");
        try lines.appendSlice(allocator, pos_str);
        try lines.appendSlice(allocator, " tokens\n");
    }
    if (est_context) |ctx| {
        var num_buf: [32]u8 = undefined;
        const ctx_str = try std.fmt.bufPrint(&num_buf, "~{d}", .{ctx});
        try lines.appendSlice(allocator, "Est. context needed: ");
        try lines.appendSlice(allocator, ctx_str);
        try lines.appendSlice(allocator, " tokens\n");
    }

    const secs = duration.?;
    if (critical) {
        try lines.appendSlice(allocator, "This file likely exceeds the model context limit (65536). Split or trim the audio.");
    } else if (secs < 180) {
        try lines.appendSlice(allocator, "Short clip — default context is enough.");
    } else if (secs < 600) {
        try lines.appendSlice(allocator, "Medium length — a larger context will be allocated automatically.");
    } else {
        try lines.appendSlice(allocator, "Long recording — needs a large context; transcription may take longer.");
    }

    if (!critical and runtime == .vulkan and if (est_context) |ctx| ctx > 10000 else false) {
        try lines.appendSlice(allocator, "\nVulkan: large contexts use significant VRAM; try 0.6B/Q4 or CPU if you run out of memory.");
    } else if (!critical and runtime == .metal and if (est_context) |ctx| ctx > 16384 else false) {
        try lines.appendSlice(allocator, "\nLong file on GPU — ensure enough unified memory is available.");
    }

    return lines.toOwnedSlice(allocator);
}
