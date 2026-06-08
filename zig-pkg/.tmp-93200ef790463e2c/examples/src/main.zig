const std = @import("std");
const osd = @import("osdialog");

pub fn main() void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	_ = osd.message("Hello, World!", .{});
	if (!osd.message("Do you want to continue?", .{ .buttons = .yes_no })) {
		std.process.exit(0);
	}
	if (osd.prompt(allocator, "Give me some input", .{})) |input| {
		defer allocator.free(input);
		std.debug.print("Input: {s}\n", .{input});
	}
	if (osd.color(.{ .color = .{ .r = 247, .g = 163, .b = 29, .a = 255 } })) |selected| {
		std.debug.print("Color RRR,GGG,BBB,AAA: {d},{d},{d},{d}\n", .{ selected.r, selected.g, selected.b, selected.a });
	}
	if (osd.path(allocator, .open, .{})) |path| {
		defer allocator.free(path);
		std.debug.print("Selected file: {s}\n", .{path});
	}
	if (osd.path(allocator, .open_dir, .{})) |path| {
		defer allocator.free(path);
	}
	if (osd.path(allocator, .save, .{ .path = ".", .filename = "myfile.txt" })) |path| {
		defer allocator.free(path);
		std.debug.print("Save location: {s}\n", .{path});
	}
}
