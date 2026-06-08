const std = @import("std");
const builtin = @import("builtin");

pub fn homeDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = if (builtin.os.tag == .windows)
        std.c.getenv("USERPROFILE")
    else
        std.c.getenv("HOME");
    const home_ptr = home orelse return error.HomeNotFound;
    return try allocator.dupe(u8, std.mem.span(home_ptr));
}
