const std = @import("std");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");

const app_mod = @import("app.zig");
const dialog = @import("dialog.zig");

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
    var preview_buf: [65536:0]u8 = @splat(0);
    var log_buf: [262144:0]u8 = @splat(0);

    while (!window.shouldClose()) {
        application.poll();

        zglfw.pollEvents();

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
            drawAudioSection(application);
            zgui.separator();
            drawOutputSection(application, &preview_buf);
            zgui.separator();
            drawActionSection(application);
            drawStatusSection(application, &log_buf);
        }
        zgui.end();

        zgui.backend.draw();
        window.swapBuffers();
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

fn pickModelPair(app: *app_mod.App) void {
    const model_path = dialog.pickGgufFile(app.allocator) catch return orelse return;
    defer app.allocator.free(model_path);
    const mmproj_path = dialog.pickGgufFile(app.allocator) catch return orelse return;
    defer app.allocator.free(mmproj_path);
    app.setCustomModel(model_path, mmproj_path);
}

fn drawAudioSection(app: *app_mod.App) void {
    zgui.text("Audio input", .{});
    zgui.textWrapped("{s}", .{if (app.audio_path.len > 0) app.audio_path else "(none selected)"});
    if (zgui.button("Choose audio file...", .{})) {
        if (dialog.pickAudioFile(app.allocator) catch null) |path| {
            defer app.allocator.free(path);
            app.setAudioPath(path) catch {};
        }
    }
    zgui.sameLine(.{});
    zgui.textDisabled("Supports wav, mp3, flac via llama.cpp", .{});
}

fn drawOutputSection(app: *app_mod.App, preview_buf: *[65536:0]u8) void {
    zgui.text("Output", .{});
    zgui.textWrapped("{s}", .{if (app.output_path.len > 0) app.output_path else "(none selected)"});
    if (zgui.button("Choose output file...", .{})) {
        const default_name = if (app.output_path.len > 0)
            std.fs.path.basename(app.output_path)
        else
            "transcription.txt";
        if (dialog.pickOutputFile(app.allocator, default_name) catch null) |path| {
            defer app.allocator.free(path);
            app.setOutputPath(path) catch {};
        }
    }

    if (app.last_transcript.len > 0) {
        zgui.separator();
        zgui.text("Preview", .{});
        const copy_len = @min(app.last_transcript.len, preview_buf.len - 1);
        @memcpy(preview_buf[0..copy_len], app.last_transcript[0..copy_len]);
        preview_buf[copy_len] = 0;
        _ = zgui.inputTextMultiline("##preview", .{
            .buf = preview_buf,
            .flags = .{ .read_only = true },
        });
    }
}

fn drawActionSection(app: *app_mod.App) void {
    const disabled = !app.canTranscribe();
    if (disabled) zgui.beginDisabled(.{});
    if (zgui.button("Transcribe", .{ .w = 140 })) {
        app.startTranscription() catch {};
    }
    if (disabled) zgui.endDisabled();
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
    app.process_log.copyTo(log_buf);
    if (zgui.beginChild("##log_panel", .{ .w = 0, .h = 180 })) {
        _ = zgui.inputTextMultiline("##process_log", .{
            .buf = log_buf,
            .flags = .{ .read_only = true },
        });
        if (app.status == .transcribing) {
            zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
        }
        zgui.endChild();
    }
}
