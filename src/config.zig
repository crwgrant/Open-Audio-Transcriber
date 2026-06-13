const std = @import("std");
const io_util = @import("io_util.zig");
const paths = @import("paths.zig");
const perf_profile = @import("perf_profile.zig");
const runtime = @import("runtime.zig");

pub const Config = struct {
    model_path: []const u8,
    mmproj_path: []const u8,
    runtime: ?runtime.Id = null,
    rtf_cpu: ?f64 = null,
    rtf_vulkan: ?f64 = null,
    rtf_metal: ?f64 = null,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.model_path);
        allocator.free(self.mmproj_path);
    }

    pub fn rtfProfile(self: Config) perf_profile.Profile {
        return .{
            .cpu = self.rtf_cpu,
            .vulkan = self.rtf_vulkan,
            .metal = self.rtf_metal,
        };
    }
};

pub const SaveOptions = struct {
    model_path: []const u8,
    mmproj_path: []const u8,
    runtime: runtime.Id,
    rtf_profile: perf_profile.Profile = .{},
};

pub fn configPath(allocator: std.mem.Allocator) ![]const u8 {
    const home_slice = try paths.homeDir(allocator);
    defer allocator.free(home_slice);
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

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value.object;
    const model = root.get("model_path") orelse return null;
    const mmproj = root.get("mmproj_path") orelse return null;
    if (model != .string or mmproj != .string) return null;

    var rt: ?runtime.Id = null;
    if (root.get("runtime")) |runtime_val| {
        if (runtime_val == .string) {
            rt = runtime.Id.fromConfigString(runtime_val.string);
        }
    }

    const rtf_cpu = parseOptionalFloat(root.get("rtf_cpu"));
    const rtf_vulkan = parseOptionalFloat(root.get("rtf_vulkan"));
    const rtf_metal = parseOptionalFloat(root.get("rtf_metal"));

    return .{
        .model_path = try allocator.dupe(u8, model.string),
        .mmproj_path = try allocator.dupe(u8, mmproj.string),
        .runtime = rt,
        .rtf_cpu = rtf_cpu,
        .rtf_vulkan = rtf_vulkan,
        .rtf_metal = rtf_metal,
    };
}

fn parseOptionalFloat(val: ?std.json.Value) ?f64 {
    const v = val orelse return null;
    switch (v) {
        .float => |f| return f,
        .integer => |i| return @floatFromInt(i),
        else => return null,
    }
}

const SavedConfig = struct {
    model_path: []const u8,
    mmproj_path: []const u8,
    runtime: []const u8,
    rtf_cpu: ?f64,
    rtf_vulkan: ?f64,
    rtf_metal: ?f64,
};

pub fn save(allocator: std.mem.Allocator, opts: SaveOptions) !void {
    const path = try configPath(allocator);
    defer allocator.free(path);

    const json = try std.json.Stringify.valueAlloc(allocator, SavedConfig{
        .model_path = opts.model_path,
        .mmproj_path = opts.mmproj_path,
        .runtime = opts.runtime.configString(),
        .rtf_cpu = opts.rtf_profile.cpu,
        .rtf_vulkan = opts.rtf_profile.vulkan,
        .rtf_metal = opts.rtf_profile.metal,
    }, .{});
    defer allocator.free(json);

    try io_util.writeFileAbsolute(path, json);
}
