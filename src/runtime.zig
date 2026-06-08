const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cDefine("UINTPTR_MAX", "0xFFFFFFFFFFFFFFFF");
    @cInclude("llama_c.h");
});

/// Inference backend selected in the UI. Must match ggml backend registry names where noted.
pub const Id = enum {
    cpu,
    vulkan,
    metal,

    pub fn label(self: Id) [:0]const u8 {
        return switch (self) {
            .cpu => "CPU",
            .vulkan => "Vulkan",
            .metal => "Metal",
        };
    }

    pub fn backendName(self: Id) [:0]const u8 {
        return switch (self) {
            .cpu => "CPU",
            .vulkan => "Vulkan",
            .metal => "Metal",
        };
    }

    pub fn fromConfigString(s: []const u8) ?Id {
        if (std.mem.eql(u8, s, "cpu")) return .cpu;
        if (std.mem.eql(u8, s, "vulkan")) return .vulkan;
        if (std.mem.eql(u8, s, "metal")) return .metal;
        return null;
    }

    pub fn configString(self: Id) []const u8 {
        return switch (self) {
            .cpu => "cpu",
            .vulkan => "vulkan",
            .metal => "metal",
        };
    }

    pub fn useGpu(self: Id) bool {
        return self != .cpu;
    }
};

pub const Option = struct {
    id: Id,
    description: []const u8,
};

const platform_candidates = switch (builtin.os.tag) {
    .windows => &[_]Id{ .cpu, .vulkan },
    .macos => &[_]Id{ .cpu, .metal },
    else => &[_]Id{ .cpu},
};

/// Initialize ggml backends and return runtimes allowed on this OS that are linked and working.
pub fn discover(allocator: std.mem.Allocator) ![]Option {
    c.llama_backend_init();
    defer c.llama_backend_free();
    c.ggml_backend_load_all();

    var list: std.ArrayList(Option) = .empty;
    errdefer {
        for (list.items) |opt| allocator.free(opt.description);
        list.deinit(allocator);
    }

    for (platform_candidates) |id| {
        if (!isAvailable(id)) continue;
        const desc = try describeRuntime(allocator, id);
        try list.append(allocator, .{ .id = id, .description = desc });
    }

    if (list.items.len == 0) {
        const desc = try allocator.dupe(u8, "CPU");
        try list.append(allocator, .{ .id = .cpu, .description = desc });
    }

    return try list.toOwnedSlice(allocator);
}

pub fn freeOptions(allocator: std.mem.Allocator, options: []Option) void {
    for (options) |opt| allocator.free(opt.description);
    allocator.free(options);
}

pub fn findOption(options: []const Option, id: Id) ?usize {
    for (options, 0..) |opt, i| {
        if (opt.id == id) return i;
    }
    return null;
}

fn isAvailable(id: Id) bool {
    const reg = c.ggml_backend_reg_by_name(id.backendName().ptr) orelse return false;
    return c.ggml_backend_reg_dev_count(reg) > 0;
}

fn describeRuntime(allocator: std.mem.Allocator, id: Id) ![]u8 {
    const reg = c.ggml_backend_reg_by_name(id.backendName().ptr) orelse {
        return try allocator.dupe(u8, id.label());
    };
    if (c.ggml_backend_reg_dev_count(reg) == 0) {
        return try allocator.dupe(u8, id.label());
    }
    const dev = c.ggml_backend_reg_dev_get(reg, 0);
    const desc = c.ggml_backend_dev_description(dev);
    if (desc == null or desc[0] == 0) {
        return try allocator.dupe(u8, id.label());
    }
    return try std.fmt.allocPrint(allocator, "{s} — {s}", .{ id.label(), std.mem.span(desc) });
}
