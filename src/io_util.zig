const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn fileExists(absolute_path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io(), absolute_path, .{}) catch return false;
    return true;
}

pub fn readFileSmall(allocator: std.mem.Allocator, absolute_path: []const u8, max_size: usize) ![]u8 {
    var buf: [65536]u8 = undefined;
    const slice = buf[0..@min(buf.len, max_size)];
    const n = try std.Io.Dir.cwd().readFile(io(), absolute_path, slice);
    return try allocator.dupe(u8, n);
}

pub fn writeFileAbsolute(absolute_path: []const u8, data: []const u8) !void {
    try std.Io.Dir.writeFile(.cwd(), io(), .{
        .sub_path = absolute_path,
        .data = data,
        .flags = .{ .truncate = true },
    });
}
