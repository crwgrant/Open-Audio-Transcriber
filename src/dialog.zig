const std = @import("std");

extern fn dialog_pick_open_file(title: ?[*:0]const u8, filter_name: ?[*:0]const u8, filter_ext: ?[*:0]const u8) ?[*:0]const u8;
extern fn dialog_pick_open_directory(title: ?[*:0]const u8) ?[*:0]const u8;
extern fn dialog_pick_save_file(title: ?[*:0]const u8, default_name: ?[*:0]const u8) ?[*:0]const u8;
extern fn dialog_free_path(path: ?[*:0]const u8) void;

pub fn pickAudioFile(allocator: std.mem.Allocator) !?[]const u8 {
    return pickOpenFile(allocator, "Select audio file", "Audio", "wav,mp3,flac");
}

pub fn pickGgufFile(allocator: std.mem.Allocator) !?[]const u8 {
    return pickOpenFile(allocator, "Select GGUF model", "GGUF", "gguf");
}

pub fn pickOutputFile(allocator: std.mem.Allocator, default_name: []const u8) !?[]const u8 {
    const default_z = try allocator.dupeZ(u8, default_name);
    defer allocator.free(default_z);
    const path = dialog_pick_save_file("Save transcription", default_z.ptr);
    if (path == null) return null;
    defer dialog_free_path(path);
    return try allocator.dupe(u8, std.mem.span(path.?));
}

pub fn pickOpenFile(allocator: std.mem.Allocator, title: []const u8, filter_name: []const u8, filter_ext: []const u8) !?[]const u8 {
    const title_z = try allocator.dupeZ(u8, title);
    defer allocator.free(title_z);
    const filter_name_z = try allocator.dupeZ(u8, filter_name);
    defer allocator.free(filter_name_z);
    const filter_ext_z = try allocator.dupeZ(u8, filter_ext);
    defer allocator.free(filter_ext_z);

    const path = dialog_pick_open_file(title_z.ptr, filter_name_z.ptr, filter_ext_z.ptr);
    if (path == null) return null;
    defer dialog_free_path(path);
    return try allocator.dupe(u8, std.mem.span(path.?));
}

pub fn pickDirectory(allocator: std.mem.Allocator, title: []const u8) !?[]const u8 {
    const title_z = try allocator.dupeZ(u8, title);
    defer allocator.free(title_z);
    const path = dialog_pick_open_directory(title_z.ptr);
    if (path == null) return null;
    defer dialog_free_path(path);
    return try allocator.dupe(u8, std.mem.span(path.?));
}
