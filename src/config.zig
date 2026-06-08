const std = @import("std");
const io_util = @import("io_util.zig");

pub const Config = struct {
    model_path: []const u8,
    mmproj_path: []const u8,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.model_path);
        allocator.free(self.mmproj_path);
    }
};

pub fn configPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.c.getenv("HOME") orelse return error.HomeNotFound;
    const home_slice = std.mem.span(home);
    const dir = try std.fs.path.join(allocator, &.{ home_slice, ".config", "audio-transcriber" });
    defer allocator.free(dir);
    try std.Io.Dir.createDirPath(.cwd(), io_util.io(), dir);
    return std.fs.path.join(allocator, &.{ home_slice, ".config", "audio-transcriber", "config.json" });
}

pub fn load(allocator: std.mem.Allocator) !?Config {
    const path = try configPath(allocator);
    defer allocator.free(path);

    const data = io_util.readFileSmall(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const model = root.get("model_path") orelse return null;
    const mmproj = root.get("mmproj_path") orelse return null;
    if (model != .string or mmproj != .string) return null;

    return .{
        .model_path = try allocator.dupe(u8, model.string),
        .mmproj_path = try allocator.dupe(u8, mmproj.string),
    };
}

pub fn save(allocator: std.mem.Allocator, model_path: []const u8, mmproj_path: []const u8) !void {
    const path = try configPath(allocator);
    defer allocator.free(path);

    var buf: [4096]u8 = undefined;
    const json = try std.fmt.bufPrint(&buf,
        \\{{"model_path":"{s}","mmproj_path":"{s}"}}
    , .{ model_path, mmproj_path });

    try io_util.writeFileAbsolute(path, json);
}
