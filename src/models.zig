const std = @import("std");
const io_util = @import("io_util.zig");
const paths = @import("paths.zig");

pub const AsrModel = struct {
    label: [:0]const u8,
    model_path: []const u8,
    mmproj_path: []const u8,
    source: []const u8,
};

pub const DiscoverOptions = struct {
    search_roots: []const []const u8 = defaultSearchRoots(),
};

pub fn defaultSearchRoots() []const []const u8 {
    return &.{
        ".lmstudio/models",
        ".ollama/models",
        ".cache/huggingface/hub",
    };
}

pub fn defaultModelPaths(allocator: std.mem.Allocator) !struct { model: []const u8, mmproj: []const u8 } {
    const home_slice = try paths.homeDir(allocator);
    defer allocator.free(home_slice);
    const base = try std.fs.path.join(allocator, &.{ home_slice, ".lmstudio", "models", "ggml-org", "Qwen3-ASR-1.7B-GGUF" });
    defer allocator.free(base);

    return .{
        .model = try std.fs.path.join(allocator, &.{ base, "Qwen3-ASR-1.7B-Q8_0.gguf" }),
        .mmproj = try std.fs.path.join(allocator, &.{ base, "mmproj-Qwen3-ASR-1.7B-bf16.gguf" }),
    };
}

pub fn discover(allocator: std.mem.Allocator, opts: DiscoverOptions) !std.ArrayList(AsrModel) {
    const home_slice = try paths.homeDir(allocator);
    defer allocator.free(home_slice);
    var models = std.ArrayList(AsrModel).empty;
    errdefer freeAll(allocator, &models);

    for (opts.search_roots) |root| {
        const abs = try std.fs.path.join(allocator, &.{ home_slice, root });
        defer allocator.free(abs);
        try scanDirectory(allocator, abs, root, &models);
    }

    std.sort.insertion(AsrModel, models.items, {}, lessThanLabel);
    return models;
}

fn lessThanLabel(_: void, a: AsrModel, b: AsrModel) bool {
    return std.ascii.lessThanIgnoreCase(a.label, b.label);
}

pub fn freeAll(allocator: std.mem.Allocator, models: *std.ArrayList(AsrModel)) void {
    for (models.items) |m| {
        allocator.free(m.label);
        allocator.free(m.model_path);
        allocator.free(m.mmproj_path);
        allocator.free(m.source);
    }
    models.deinit(allocator);
}

fn scanDirectory(allocator: std.mem.Allocator, abs_path: []const u8, source: []const u8, out: *std.ArrayList(AsrModel)) !void {
    const io = io_util.io();
    var dir = std.Io.Dir.openDirAbsolute(io, abs_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            const full = try std.fs.path.join(allocator, &.{ abs_path, entry.name });
            defer allocator.free(full);
            try scanDirectory(allocator, full, source, out);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), ".gguf")) continue;
        if (std.mem.startsWith(u8, entry.name, "mmproj-")) continue;
        try maybeAddPair(allocator, abs_path, entry.name, source, out);
    }
}

fn maybeAddPair(allocator: std.mem.Allocator, dir_path: []const u8, model_name: []const u8, source: []const u8, out: *std.ArrayList(AsrModel)) !void {
    const stem = std.fs.path.stem(model_name);
    const mmproj_name = findMmprojName(allocator, dir_path, stem) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    } orelse return;

    const model_path = try std.fs.path.join(allocator, &.{ dir_path, model_name });
    errdefer allocator.free(model_path);
    const mmproj_path = try std.fs.path.join(allocator, &.{ dir_path, mmproj_name });
    defer allocator.free(mmproj_name);

    const label = try allocator.dupeZ(u8, stem);
    errdefer allocator.free(label);
    const source_copy = try allocator.dupe(u8, source);

    try out.append(allocator, .{
        .label = label,
        .model_path = model_path,
        .mmproj_path = mmproj_path,
        .source = source_copy,
    });
}

pub fn findByModelPath(models: []const AsrModel, model_path: []const u8) ?usize {
    for (models, 0..) |m, i| {
        if (std.mem.eql(u8, m.model_path, model_path)) return i;
    }
    return null;
}

fn findMmprojName(allocator: std.mem.Allocator, dir_path: []const u8, model_stem: []const u8) !?[]const u8 {
    const exact = try std.fmt.allocPrint(allocator, "mmproj-{s}.gguf", .{model_stem});
    defer allocator.free(exact);
    const exact_path = try std.fs.path.join(allocator, &.{ dir_path, exact });
    defer allocator.free(exact_path);
    if (io_util.fileExists(exact_path)) {
        return try allocator.dupe(u8, exact);
    }

    const io = io_util.io();
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var mmprojs = std.ArrayList([]const u8).empty;
    defer {
        for (mmprojs.items) |name| allocator.free(name);
        mmprojs.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "mmproj-")) continue;
        try mmprojs.append(allocator, try allocator.dupe(u8, entry.name));
    }

    if (mmprojs.items.len == 0) return null;
    if (mmprojs.items.len == 1) return try allocator.dupe(u8, mmprojs.items[0]);

    const model_base = stripQuantSuffix(model_stem);
    for (mmprojs.items) |name| {
        const proj_stem = std.fs.path.stem(name); // mmproj-Qwen3-ASR-1.7B-bf16
        const proj_base = if (std.mem.startsWith(u8, proj_stem, "mmproj-"))
            proj_stem["mmproj-".len..]
        else
            proj_stem;
        const proj_core = stripQuantSuffix(proj_base);
        if (std.mem.eql(u8, model_base, proj_core) or std.mem.startsWith(u8, model_stem, proj_core)) {
            return try allocator.dupe(u8, name);
        }
    }

    return try allocator.dupe(u8, mmprojs.items[0]);
}

fn stripQuantSuffix(name: []const u8) []const u8 {
    const suffixes = [_][]const u8{ "-Q8_0", "-Q4_0", "-Q5_0", "-bf16", "-f16", "-f32", "-FP16" };
    var result = name;
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, result, suffix)) {
            result = result[0 .. result.len - suffix.len];
        }
    }
    return result;
}

pub fn findDefault(models: []const AsrModel, allocator: std.mem.Allocator) ?usize {
    const defaults = defaultModelPaths(allocator) catch return null;
    defer allocator.free(defaults.model);
    defer allocator.free(defaults.mmproj);

    for (models, 0..) |m, i| {
        if (std.mem.eql(u8, m.model_path, defaults.model)) return i;
    }
    return null;
}
