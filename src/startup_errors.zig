const std = @import("std");
const builtin = @import("builtin");

const io_util = @import("io_util.zig");

const windows_ui = if (builtin.os.tag == .windows)
    @import("startup_errors_win.zig")
else
    struct {
        pub fn show(_: [*:0]const u8) void {}
    };

pub const Stage = enum {
    bootstrap,
    gui,
};

pub fn reportFailure(stage: Stage, err: anyerror) void {
    const allocator = std.heap.page_allocator;

    var summary_buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "{s} failed: {s}", .{
        @tagName(stage),
        @errorName(err),
    }) catch "Audio Transcriber failed to start";

    const log_path = logPath(allocator) catch null;
    defer if (log_path) |path| allocator.free(path);

    if (log_path) |path| {
        writeLog(path, stage, err) catch {};
    }

    var summary_z: [257]u8 = undefined;
    @memcpy(summary_z[0..summary.len], summary);
    summary_z[summary.len] = 0;
    const summary_nt: [:0]const u8 = summary_z[0..summary.len :0];

    var message_buf: [2048]u8 = undefined;
    const message = if (log_path) |path| blk: {
        break :blk std.fmt.bufPrintZ(&message_buf, "Audio Transcriber could not start.\n\n{s}\n\nDetails were written to:\n{s}", .{
            summary,
            path,
        }) catch summary_nt;
    } else blk: {
        break :blk std.fmt.bufPrintZ(&message_buf, "Audio Transcriber could not start.\n\n{s}", .{summary}) catch summary_nt;
    };

    std.debug.print("Audio Transcriber startup error: {s}\n", .{summary});
    if (log_path) |path| {
        std.debug.print("Log: {s}\n", .{path});
    }

    windows_ui.show(message.ptr);
}

fn logPath(allocator: std.mem.Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .windows => blk: {
            const temp = std.c.getenv("TEMP") orelse std.c.getenv("TMP") orelse return error.NoTempDir;
            break :blk try std.fmt.allocPrint(allocator, "{s}\\audio-transcriber-startup.log", .{std.mem.span(temp)});
        },
        else => blk: {
            if (std.c.getenv("TMPDIR")) |tmpdir| {
                break :blk try std.fmt.allocPrint(allocator, "{s}/audio-transcriber-startup.log", .{std.mem.span(tmpdir)});
            }
            break :blk try allocator.dupe(u8, "/tmp/audio-transcriber-startup.log");
        },
    };
}

fn writeLog(path: []const u8, stage: Stage, err: anyerror) !void {
    const content = try std.fmt.allocPrint(std.heap.page_allocator, "Audio Transcriber startup failure\nStage: {s}\nError: {s}\n", .{
        @tagName(stage),
        @errorName(err),
    });
    defer std.heap.page_allocator.free(content);
    try io_util.writeFileAbsolute(path, content);
}
