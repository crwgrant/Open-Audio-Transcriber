const std = @import("std");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");

const app_mod = @import("app.zig");
const dialog = @import("dialog.zig");
const runtime_mod = @import("runtime.zig");

const PendingDialog = enum {
    none,
    audio,
    output,
    model_model,
    model_mmproj,
};

var pending_dialog: PendingDialog = .none;
var pending_output_default: [256:0]u8 = @splat(0);
var pending_model_path: ?[]const u8 = null;
var pending_audio_path: ?[]const u8 = null;

pub fn run(allocator: std.mem.Allocator, application: *app_mod.App) !void {
    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .opengl_api);
    zglfw.windowHint(.context_version_major, 3);
    zglfw.windowHint(.context_version_minor, 3);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.opengl_forward_compat, true);

    const window = try zglfw.createWindow(960, 720, "Audio Transcriber", null, null);
    defer zglfw.destroyWindow(window);
    zglfw.makeContextCurrent(window);
    zglfw.swapInterval(1);

    try zopengl.loadCoreProfile(zglfw.getProcAddress, 3, 3);

    zgui.init(allocator);
    defer zgui.deinit();
    zgui.backend.init(window);
    defer zgui.backend.deinit();

    const gl = zopengl.bindings;
    var log_buf: [262144:0]u8 = @splat(0);

    while (!window.shouldClose()) {
        application.poll();
        applyPendingAudioPath(application, allocator);

        zglfw.pollEvents();
        dialog.pumpEvents();

        const window_size = window.getSize();
        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(window_size[0]), @intCast(window_size[1]));
        applyDisplayScale(window);

        gl.viewport(0, 0, @intCast(fb_size[0]), @intCast(fb_size[1]));
        gl.clearColor(0.11, 0.11, 0.12, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);

        const display_w = @as(f32, @floatFromInt(window_size[0]));
        const display_h = @as(f32, @floatFromInt(window_size[1]));
        zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
        zgui.setNextWindowSize(.{ .w = display_w, .h = display_h, .cond = .always });

        if (zgui.begin("Audio Transcriber", .{
            .flags = .{
                .no_collapse = true,
                .no_move = true,
                .no_resize = true,
            },
        })) {
            drawModelSection(application);
            zgui.separator();
            drawRuntimeSection(application);
            zgui.separator();
            drawAudioSection(application);
            zgui.separator();
            drawOutputSection(application);
            zgui.separator();
            drawActionSection(application);
            drawStatusSection(application, &log_buf);
        }
        zgui.end();

        runDeferredDialogs(application, allocator);

        zgui.backend.draw();
        window.swapBuffers();
    }
}

fn applyPendingAudioPath(app: *app_mod.App, allocator: std.mem.Allocator) void {
    if (pending_audio_path) |path| {
        pending_audio_path = null;
        app.setAudioPath(path) catch {};
        allocator.free(path);
    }
}

fn runDeferredDialogs(app: *app_mod.App, allocator: std.mem.Allocator) void {
    switch (pending_dialog) {
        .none => {},
        .audio => {
            pending_dialog = .none;
            if (dialog.pickAudioFile(allocator) catch null) |path| {
                pending_audio_path = path;
            }
        },
        .output => {
            pending_dialog = .none;
            const default_len = std.mem.indexOfScalar(u8, &pending_output_default, 0) orelse pending_output_default.len;
            if (dialog.pickOutputFile(allocator, pending_output_default[0..default_len]) catch null) |path| {
                defer allocator.free(path);
                app.setOutputPath(path) catch {};
            }
        },
        .model_model => {
            pending_dialog = .none;
            if (dialog.pickGgufFile(allocator) catch null) |path| {
                pending_model_path = path;
                pending_dialog = .model_mmproj;
            }
        },
        .model_mmproj => {
            pending_dialog = .none;
            const model_path = pending_model_path;
            pending_model_path = null;
            if (model_path) |model| {
                if (dialog.pickGgufFile(allocator) catch null) |mmproj| {
                    defer allocator.free(mmproj);
                    app.setCustomModel(model, mmproj);
                }
                allocator.free(model);
            }
        },
    }
}

fn applyDisplayScale(window: *zglfw.Window) void {
    const window_size = window.getSize();
    const fb_size = window.getFramebufferSize();
    const scale_x: f32 = if (window_size[0] > 0)
        @as(f32, @floatFromInt(fb_size[0])) / @as(f32, @floatFromInt(window_size[0]))
    else
        1.0;
    const scale_y: f32 = if (window_size[1] > 0)
        @as(f32, @floatFromInt(fb_size[1])) / @as(f32, @floatFromInt(window_size[1]))
    else
        1.0;
    zgui.io.setDisplaySize(
        @floatFromInt(window_size[0]),
        @floatFromInt(window_size[1]),
    );
    zgui.io.setDisplayFramebufferScale(scale_x, scale_y);
}

fn drawModelSection(app: *app_mod.App) void {
    zgui.text("Model", .{});
    if (app.selectedModel()) |model| {
        zgui.textWrapped("{s}", .{model.label});
        zgui.textDisabled("Model: {s}", .{model.model});
        zgui.textDisabled("MMProj: {s}", .{model.mmproj});
    } else {
        zgui.textColored(.{ 1.0, 0.4, 0.4, 1.0 }, "No model selected", .{});
    }

    const preview_label = if (app.selectedModel()) |m| m.label else "Choose model";
    var preview_buf: [512]u8 = undefined;
    if (preview_label.len >= preview_buf.len) return;
    @memcpy(preview_buf[0..preview_label.len], preview_label);
    preview_buf[preview_label.len] = 0;

    if (zgui.beginCombo("##model_combo", .{ .preview_value = @ptrCast(&preview_buf) })) {
        for (app.discovered.items, 0..) |m, i| {
            const selected = app.selected_index == i and app.custom_model_path.len == 0;
            if (zgui.selectable(m.label, .{ .selected = selected })) {
                app.selectDiscovered(i);
            }
            if (selected) zgui.setItemDefaultFocus();
        }
        zgui.endCombo();
    }

    if (zgui.beginPopupContextItem()) {
        if (zgui.menuItem("Browse model pair...", .{})) {
            pickModelPair(app);
        }
        if (zgui.menuItem("Rescan model directories", .{})) {
            app.bootstrap() catch {};
        }
        zgui.endPopup();
    }

    if (zgui.button("Browse model pair...", .{})) {
        pickModelPair(app);
    }
    zgui.sameLine(.{});
    zgui.textDisabled("Searches ~/.lmstudio, ~/.ollama, ~/.cache/huggingface", .{});
}

fn drawRuntimeSection(app: *app_mod.App) void {
    zgui.text("Runtime", .{});
    if (app.runtimes.len == 0) {
        zgui.textDisabled("No runtimes detected", .{});
        return;
    }

    const selected_idx = runtime_mod.findOption(app.runtimes, app.selected_runtime) orelse 0;
    const preview = app.runtimes[selected_idx].description;

    const busy = app.status == .transcribing;
    if (busy or app.runtimes.len == 1) zgui.beginDisabled(.{});

    var preview_buf: [512]u8 = undefined;
    const copy_len = @min(preview.len, preview_buf.len - 1);
    @memcpy(preview_buf[0..copy_len], preview[0..copy_len]);
    preview_buf[copy_len] = 0;

    if (zgui.beginCombo("##runtime_combo", .{ .preview_value = @ptrCast(&preview_buf) })) {
        for (app.runtimes) |opt| {
            const selected = app.selected_runtime == opt.id;
            if (zgui.selectable(opt.id.label(), .{ .selected = selected })) {
                app.selectRuntime(opt.id);
            }
            if (selected) zgui.setItemDefaultFocus();
        }
        zgui.endCombo();
    }

    if (busy or app.runtimes.len == 1) zgui.endDisabled();
}

fn pickModelPair(_: *app_mod.App) void {
    pending_dialog = .model_model;
}

fn drawAudioSection(app: *app_mod.App) void {
    zgui.text("Audio input", .{});
    zgui.textWrapped("{s}", .{if (app.audio_path.len > 0) app.audio_path else "(none selected)"});
    if (app.audio_estimate) |est| {
        const color: [4]f32 = if (est.critical)
            .{ 1.0, 0.35, 0.35, 1.0 }
        else if (est.warn)
            .{ 1.0, 0.75, 0.2, 1.0 }
        else
            .{ 0.55, 0.55, 0.55, 1.0 };
        zgui.textColored(color, "{s}", .{est.text});
    }
    if (zgui.button("Choose audio file...", .{})) {
        pending_dialog = .audio;
    }
    zgui.sameLine(.{});
    zgui.textDisabled("Supports wav, mp3, flac via llama.cpp", .{});
}

fn drawOutputSection(app: *app_mod.App) void {
    zgui.text("Output", .{});
    zgui.textWrapped("{s}", .{if (app.output_path.len > 0) app.output_path else "(none selected)"});
    if (zgui.button("Choose output file...", .{})) {
        const default_name = if (app.output_path.len > 0)
            std.fs.path.basename(app.output_path)
        else
            "transcription.txt";
        const copy_len = @min(default_name.len, pending_output_default.len - 1);
        @memcpy(pending_output_default[0..copy_len], default_name[0..copy_len]);
        pending_output_default[copy_len] = 0;
        pending_dialog = .output;
    }
}

fn drawActionSection(app: *app_mod.App) void {
    const transcribing = app.status == .transcribing;
    if (transcribing) {
        if (zgui.button("Cancel", .{ .w = 140 })) {
            app.cancelTranscription();
        }
    } else {
        const disabled = !app.canTranscribe();
        if (disabled) zgui.beginDisabled(.{});
        if (zgui.button("Transcribe", .{ .w = 140 })) {
            app.startTranscription() catch {};
        }
        if (disabled) zgui.endDisabled();
    }
}

fn drawStatusSection(app: *app_mod.App, log_buf: *[262144:0]u8) void {
    zgui.separator();
    const color: [4]f32 = switch (app.status) {
        .idle, .loading_models, .ready => .{ 0.7, 0.7, 0.7, 1.0 },
        .transcribing => .{ 0.9, 0.8, 0.2, 1.0 },
        .done => .{ 0.2, 0.9, 0.3, 1.0 },
        .error_state => .{ 1.0, 0.3, 0.3, 1.0 },
    };
    zgui.textColored(color, "{s}", .{app.status_message});

    zgui.text("Log", .{});
    zgui.sameLine(.{});
    const log_busy = app.status == .transcribing;
    if (log_busy) zgui.beginDisabled(.{});
    if (zgui.button("Clear log", .{})) {
        app.clearLog();
        log_buf[0] = 0;
    }
    if (log_busy) zgui.endDisabled();

    app.process_log.copyTo(log_buf);

    const avail = zgui.getContentRegionAvail();
    const log_h = @max(avail[1], 120);
    if (zgui.beginChild("##log_panel", .{
        .w = avail[0],
        .h = log_h,
        .window_flags = .{ .no_scrollbar = true },
    })) {
        _ = zgui.inputTextMultiline("##process_log", .{
            .buf = log_buf,
            .w = -1,
            .h = -1,
            .flags = .{ .read_only = true },
        });
        if (app.status == .transcribing) {
            zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
        }
        zgui.endChild();
    }
}
