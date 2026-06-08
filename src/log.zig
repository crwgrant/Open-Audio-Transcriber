const std = @import("std");
const io_util = @import("io_util.zig");

pub const Buffer = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    max_bytes: usize = 256 * 1024,

    pub fn init(allocator: std.mem.Allocator) Buffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn clear(self: *Buffer) void {
        self.lock();
        defer self.unlock();
        self.bytes.clearRetainingCapacity();
    }

    pub fn append(self: *Buffer, text: []const u8) void {
        if (text.len == 0) return;
        self.lock();
        defer self.unlock();
        self.bytes.appendSlice(self.allocator, text) catch return;
        self.trimToMax();
    }

    pub fn appendFmt(self: *Buffer, comptime fmt: []const u8, args: anytype) void {
        var stack: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&stack, fmt, args) catch return;
        self.append(msg);
        self.append("\n");
    }

    pub fn copyTo(self: *Buffer, dest: [:0]u8) void {
        self.lock();
        defer self.unlock();
        const len = @min(dest.len - 1, self.bytes.items.len);
        @memcpy(dest[0..len], self.bytes.items[0..len]);
        dest[len] = 0;
    }

    fn lock(self: *Buffer) void {
        self.mutex.lockUncancelable(io_util.io());
    }

    fn unlock(self: *Buffer) void {
        self.mutex.unlock(io_util.io());
    }

    fn trimToMax(self: *Buffer) void {
        while (self.bytes.items.len > self.max_bytes) {
            const drop = self.bytes.items.len - self.max_bytes;
            const nl = std.mem.indexOfScalar(u8, self.bytes.items[0..drop], '\n') orelse drop;
            self.bytes.replaceRange(self.allocator, 0, nl + 1, "") catch {
                self.bytes.clearRetainingCapacity();
                break;
            };
        }
    }
};

pub fn llamaCallback(level: c_uint, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = level;
    if (text == null) return;
    const buffer: *Buffer = @ptrCast(@alignCast(user_data.?));
    buffer.append(std.mem.span(text));
}
