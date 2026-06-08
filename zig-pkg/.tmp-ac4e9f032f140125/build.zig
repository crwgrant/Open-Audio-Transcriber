const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "nfd.zig",
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    install(lib_unit_tests);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

pub fn install(step: *std.Build.Step.Compile) void {
    const prefix = srcdir ++ std.fs.path.sep_str;

    step.root_module.addAnonymousImport("nfd", .{
        .root_source_file = .{ .path = prefix ++ "src/root.zig" },
    });

    const cflags = [_][]const u8{"-Wall"};
    step.addIncludePath(.{ .path = prefix ++ "nativefiledialog/src/include" });

    step.addCSourceFile(.{ .file = .{ .path = prefix ++ "nativefiledialog/src/nfd_common.c" }, .flags = &cflags });

    switch (step.rootModuleTarget().os.tag) {
        .windows => {
            step.addCSourceFile(.{ .file = .{ .path = prefix ++ "nativefiledialog/src/nfd_win.cpp" }, .flags = &cflags });
            step.linkSystemLibrary("shell32");
            step.linkSystemLibrary("ole32");
            step.linkSystemLibrary("uuid");
        },
        .macos => {
            step.addCSourceFile(.{ .file = .{ .path = prefix ++ "nativefiledialog/src/nfd_cocoa.m" }, .flags = &cflags });
            step.linkFramework("AppKit");
        },
        else => {
            step.addCSourceFile(.{ .file = .{ .path = prefix ++ "nativefiledialog/src/nfd_gtk.c" }, .flags = &cflags });
            step.linkSystemLibrary("atk-1.0");
            step.linkSystemLibrary("gdk-3");
            step.linkSystemLibrary("gtk-3");
            step.linkSystemLibrary("glib-2.0");
            step.linkSystemLibrary("gobject-2.0");
        },
    }
    step.installHeadersDirectory(prefix ++ "nativefiledialog/src/include", ".");
    step.installHeader(prefix ++ "nativefiledialog/src/include/nfd.h", "nfd.h");
    step.linkLibC();
}

const srcdir = struct {
    fn getSrcDir() []const u8 {
        return std.fs.path.dirname(@src().file).?;
    }
}.getSrcDir();
