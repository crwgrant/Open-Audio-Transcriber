const std = @import("std");
const c = @import("c.zig");
const testing = std.testing;

pub const openDialog = c.openDialog;
pub const saveDialog = c.saveDialog;
pub const pickFolder = c.pickFolder;
pub const openDialogZ = c.openDialogZ;
pub const saveDialogZ = c.saveDialogZ;
pub const pickFolderZ = c.pickFolderZ;

test "Open File Dialog" {
    const path: ?[]const u8 = try openDialog(testing.allocator, null, null);
    _ = path;
    try testing.expect(true);
}

test "Save File Dialog" {
    const path: ?[]const u8 = try saveDialog(testing.allocator, null, null);
    _ = path;
    try testing.expect(true);
}

test "Pick Folder Dialog" {
    const path: ?[]const u8 = try pickFolder(testing.allocator, null);
    _ = path;
    try testing.expect(true);
}
