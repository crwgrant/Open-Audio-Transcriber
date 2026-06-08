const std = @import("std");

const app_mod = @import("app.zig");
const gui = @import("gui.zig");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var application = app_mod.App.init(allocator);
    defer application.deinit();

    try application.bootstrap();
    try gui.run(allocator, &application);
}
