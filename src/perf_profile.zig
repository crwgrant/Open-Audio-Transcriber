const std = @import("std");

const runtime_mod = @import("runtime.zig");

/// Real-time factor: wall-clock processing seconds / audio duration seconds.
pub const Profile = struct {
    cpu: ?f64 = null,
    vulkan: ?f64 = null,
    metal: ?f64 = null,

    pub fn get(self: Profile, id: runtime_mod.Id) ?f64 {
        return switch (id) {
            .cpu => self.cpu,
            .vulkan => self.vulkan,
            .metal => self.metal,
        };
    }

    pub fn set(self: *Profile, id: runtime_mod.Id, rtf: f64) void {
        if (rtf <= 0.0 or !std.math.isFinite(rtf)) return;
        switch (id) {
            .cpu => self.cpu = rtf,
            .vulkan => self.vulkan = rtf,
            .metal => self.metal = rtf,
        }
    }
};

pub fn defaultRtfRange(id: runtime_mod.Id) struct { low: f64, high: f64 } {
    return switch (id) {
        .cpu => .{ .low = 4.0, .high = 15.0 },
        .vulkan => .{ .low = 0.4, .high = 3.0 },
        .metal => .{ .low = 0.3, .high = 2.0 },
    };
}
