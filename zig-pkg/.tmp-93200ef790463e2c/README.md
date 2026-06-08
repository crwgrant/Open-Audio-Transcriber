# osdialog-zig

[badge__build-status]: https://img.shields.io/github/actions/workflow/status/ttytm/osdialog-zig/ci.yml?branch=main&logo=github&logoColor=C0CAF5&labelColor=333
[badge__version-lib]: https://img.shields.io/github/v/tag/ttytm/osdialog-zig?logo=task&logoColor=C0CAF5&labelColor=333&color=
[badge__version-zig]: https://img.shields.io/badge/Zig-0.13.0-cc742f?logo=zig&logoColor=C0CAF5&labelColor=333

[![][badge__build-status]](https://github.com/ttytm/osdialog-zig/actions?query=branch%3Amain)
[![][badge__version-lib]](https://github.com/ttytm/osdialog-zig/releases/latest)
[![][badge__version-zig]](https://github.com/ttytm/osdialog-zig/releases/latest)

Cross-platform utility module for Zig to open native dialogs for the filesystem, message boxes, color-picking.

## Quickstart

- [Installation](#installation)
- [Usage](#usage)
  - [Example](#example)
- [Credits](#credits)

## Showcase

<table align="center">
  <tr>
    <th>Linux</th>
    <th>Windows</th>
    <th>macOS</th>
  </tr>
  <tr>
    <td width="400">
      <img alt="Linux File Dialog" src="https://github.com/ttytm/dialog/assets/34311583/6ba6e96b-3581-4382-8074-79918a99dcbd">
    </td>
    <td width="400">
      <img alt="Windows File Dialog" src="https://github.com/ttytm/dialog/assets/34311583/911e8c71-0cc1-4426-a62c-04714b6b071f">
    </td>
    <td width="400">
      <img alt="macOS File Dialog" src="https://github.com/ttytm/dialog/assets/34311583/f7c4375e-d2e4-4121-ad34-db0473d8fabe">
    </td>
  </tr>
</table>

<details open>
<summary><b>More Examples</b> <sub><sup>Toggle visibility...</sup></sub></summary><br>

<table align="center">
  <tr>
    <th>Linux</th>
    <th>Windows</th>
    <th>macOS</th>
  </tr>
  <tr>
    <td width="400">
      <img alt="Linux Color Picker GTK3" src="https://github.com/ttytm/dialog/assets/34311583/8e587c8c-2f12-41ee-9a10-4c3f92e72885">
      <img alt="Linux Message" src="https://github.com/ttytm/dialog/assets/34311583/42e1081b-ee52-4286-abfd-ad9eda63d282">
      <img alt="Linux Message with Yes and No Buttons" src="https://github.com/ttytm/dialog/assets/34311583/07aa26bd-f887-417b-9c1a-56724ceb2589">
      <img alt="Linux Input Prompt" src="https://github.com/ttytm/dialog/assets/34311583/bc5e3ec1-88b5-4e1a-b46e-381b322b8a6c">
      <img alt="Linux Color Picker GTK2" src="https://github.com/ttytm/dialog/assets/34311583/37619ed0-8fe2-4e5c-af11-70d7f2304b2b">
    </td>
    <td width="400">
      <img alt="Windows Color Picker" src="https://github.com/ttytm/dialog/assets/34311583/966b1395-55ac-45b8-aa1b-516f673b64e8">
      <img alt="Windows Message" src="https://github.com/ttytm/dialog/assets/34311583/a73e0eaf-e56b-44e6-bcc5-31bb381c6e37">
      <img alt="Windows Message with Yes and No Buttons" src="https://github.com/ttytm/dialog/assets/34311583/16a1ad65-571e-4183-8c0b-119cbf126aec">
      <img alt="Windows Input Prompt" src="https://github.com/ttytm/dialog/assets/34311583/54e4a708-de38-44ea-ae61-be39c1bdbff9">
    </td>
    <td width="400">
      <img alt="macOS Color Picker" src="https://github.com/user-attachments/assets/551ac8d6-406d-4b01-9095-d0a357cc8250">
      <!-- <img alt="macOS Message" src="https://github.com/ttytm/dialog/assets/34311583/15920c46-e529-405f-9731-3ac57ce46449"> -->
      <img alt="macOS Message with Yes and No Buttons" src="https://github.com/ttytm/dialog/assets/34311583/11cba10b-3190-4114-b1ad-e49e56d4498c">
      <img alt="macOS Input Prompt" src="https://github.com/ttytm/dialog/assets/34311583/e6d496b4-3c20-4ece-8808-0eba99a59a45">
    </td>
  </tr>
</table>

</details>

## Installation

```sh
# ~/<ProjectsPath>/your-awesome-projct
zig fetch --save https://github.com/ttytm/osdialog-zig/archive/main.tar.gz
```

```zig
// your-awesome-projct/build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
	// ..
	const osdialog_dep = b.dependency("osdialog", .{});
	const exe = b.addExecutable(.{
		.name = "your-awesome-projct",
		// ..
	});
	exe.root_module.addImport("osdialog", osdialog_dep.module("osdialog"));
	// ...
}
```

## Usage

Ref.: [`osdialog-zig/src/lib.zig`](https://github.com/ttytm/osdialog-zig/blob/main/src/lib.zig)
```zig
/// Opens a message box and returns `true` if `OK` or `Yes` was pressed.
pub fn message(text: [*:0]const u8, opts: MessageOptions) bool

/// Opens an input prompt with an "OK" and "Cancel" button.
pub fn prompt(allocator: std.mem.Allocator, text: [*:0]const u8, opts: PromptOptions) ?[:0]u8

/// Opens an RGBA color picker and returns the selected `Color` or `null` if the selection was canceled.
pub fn color(options: ColorPickerOptions) ?Color

/// Opens a file dialog and returns the selected path or `null` if the selection was canceled.
pub fn path(allocator: std.mem.Allocator, action: PathAction, options: PathOptions) ?[:0]u8
```

### Example

Ref.: [`osdialog-zig/examples/src/main.zig`](https://github.com/ttytm/osdialog-zig/blob/main/examples/src/main.zig)

```zig
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
```

```sh
# osdialog/examples
zig build run
```

## Credits

- [AndrewBelt/osdialog](https://github.com/AndrewBelt/osdialog) - The C project this library is leveraging
