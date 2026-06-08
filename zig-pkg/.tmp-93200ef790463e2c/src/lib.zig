const std = @import("std");
const bindings = @import("bindings.zig");
const Allocator = std.mem.Allocator;

pub const MessageButtons = enum {
	ok,
	ok_cancel,
	yes_no,
};

pub const MessageLevel = enum {
	info,
	warning,
	err,
};

pub const MessageOptions = struct {
	level: MessageLevel = .info,
	buttons: MessageButtons = .ok,
};

pub const PromptOptions = struct {
	level: MessageLevel = .info,
	/// The text that pre-fills the input field.
	text: [*:0]const u8 = "",
};

pub const Color = bindings.osdialog_color;

pub const ColorPickerOptions = struct {
	/// The initial color in the color picker.
	color: Color = Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
	/// The opacity slider can be disabled on unix-like systems. It has no effect on Windows.
	opacity: bool = true,
};

pub const PathAction = enum {
	open,
	open_dir,
	save,
};

pub const PathOptions = struct {
	/// The initial path the dialog will attempt to open in.
	path: [*:0]const u8 = "",
	/// The initial filename in the input field.
	filename: [*:0]const u8 = "",
	// TODO:
	filters: ?*bindings.osdialog_filters = null,
};

/// Opens a message box and returns `true` if `OK` or `Yes` was pressed.
pub fn message(text: [*:0]const u8, opts: MessageOptions) bool {
	return bindings.osdialog_message(@intFromEnum(opts.level), @intFromEnum(opts.buttons), text) == 1;
}

/// Opens an input prompt with an "OK" and "Cancel" button.
pub fn prompt(allocator: Allocator, text: [*:0]const u8, opts: PromptOptions) ?[:0]u8 {
	return bindings.toZString(allocator, bindings.osdialog_prompt(@intFromEnum(opts.level), text, opts.text));
}

/// Opens an RGBA color picker and returns the selected `Color` or `null` if the selection was canceled.
pub fn color(options: ColorPickerOptions) ?Color {
	var col = options.color;
	return if (bindings.osdialog_color_picker(&col, @intFromBool(options.opacity)) == 1) col else null;
}

/// Opens a file dialog and returns the selected path or `null` if the selection was canceled.
pub fn path(allocator: Allocator, action: PathAction, options: PathOptions) ?[:0]u8 {
	return bindings.toZString(allocator, bindings.osdialog_file(@intFromEnum(action), options.path, options.filename, null));
}
