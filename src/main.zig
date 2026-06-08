const std = @import("std");

const app_mod = @import("app.zig");
const gui = @import("gui.zig");
const startup_errors = @import("startup_errors.zig");

pub fn main() void {
    const allocator = std.heap.smp_allocator;

    var application = app_mod.App.init(allocator);
    defer application.deinit();

    application.bootstrap() catch |err| {
        startup_errors.reportFailure(.bootstrap, err);
        return;
    };

    gui.run(allocator, &application) catch |err| {
        startup_errors.reportFailure(.gui, err);
        return;
    };
}
