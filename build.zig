const std = @import("std");

const llama_root = "deps/llama.cpp.zig/llama.cpp";

fn cmakeBuildDir(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .windows => ".zig-cache/llama-cpp-win",
        else => ".zig-cache/llama-cpp",
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const host_os = b.graph.host.result.os.tag;
    const target_os = target.result.os.tag;

    if (host_os != target_os) {
        std.debug.panic("cross-compilation is not supported (host {s}, target {s})", .{
            @tagName(host_os),
            @tagName(target_os),
        });
    }

    const llama_step = addLlamaCppBuild(b, optimize, host_os);

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    const exe = b.addExecutable(.{
        .name = "audio-transcriber",
        .root_module = root_mod,
    });

    exe.step.dependOn(llama_step);

    addPlatformDeps(root_mod, b, target_os);
    addLlamaIncludes(root_mod, b);
    root_mod.addIncludePath(.{ .cwd_relative = b.pathFromRoot("src") });
    addLlamaLibs(root_mod, b, host_os);

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    const zopengl = b.dependency("zopengl", .{});
    const zgui = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .shared = false,
        .backend = .glfw_opengl3,
    });

    root_mod.addImport("zglfw", zglfw.module("root"));
    root_mod.addImport("zopengl", zopengl.module("root"));
    root_mod.addImport("zgui", zgui.module("root"));
    root_mod.linkLibrary(zglfw.artifact("glfw"));
    root_mod.linkLibrary(zgui.artifact("imgui"));

    b.installArtifact(exe);
    addPackageStep(b, exe, target_os);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the audio transcriber app");
    run_step.dependOn(&run_cmd.step);
}

fn resolveCmakePath(b: *std.Build) []const u8 {
    if (b.option([]const u8, "cmake-path", "Path to the cmake executable")) |path| {
        return path;
    }

    return switch (b.graph.host.result.os.tag) {
        .windows => "C:\\Program Files\\CMake\\bin\\cmake.exe",
        .macos => "/opt/homebrew/bin/cmake",
        else => "cmake",
    };
}

fn cmakeConfigName(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "RelWithDebInfo",
        .ReleaseFast, .ReleaseSmall => "Release",
    };
}

fn addLlamaCppBuild(b: *std.Build, optimize: std.builtin.OptimizeMode, os: std.Target.Os.Tag) *std.Build.Step {
    const config_name = cmakeConfigName(optimize);

    const cmake = resolveCmakePath(b);
    const build_dir = cmakeBuildDir(os);

    var configure_args = std.ArrayList([]const u8).empty;
    defer configure_args.deinit(b.allocator);

    configure_args.appendSlice(b.allocator, &.{
        cmake,
        "-S", b.pathFromRoot(llama_root),
        "-B", b.pathFromRoot(build_dir),
        "-DBUILD_SHARED_LIBS=OFF",
        "-DLLAMA_BUILD_TESTS=OFF",
        "-DLLAMA_BUILD_EXAMPLES=OFF",
        "-DLLAMA_BUILD_SERVER=OFF",
    }) catch @panic("OOM");

    switch (os) {
        .macos => {
            configure_args.appendSlice(b.allocator, &.{
                b.fmt("-DCMAKE_BUILD_TYPE={s}", .{config_name}),
                "-DGGML_METAL=ON",
            }) catch @panic("OOM");
        },
        .windows => {
            const tools = b.pathFromRoot("tools");
            const ninja = b.pathJoin(&.{ tools, "ninja.exe" });
            const zigcc = b.pathJoin(&.{ tools, "zigcc.bat" });
            const zigcxx = b.pathJoin(&.{ tools, "zigcxx.bat" });
            const zigar = b.pathJoin(&.{ tools, "zigar.bat" });
            const zigranlib = b.pathJoin(&.{ tools, "zigranlib.bat" });
            configure_args.appendSlice(b.allocator, &.{
                "-G", "Ninja",
                b.fmt("-DCMAKE_MAKE_PROGRAM={s}", .{ninja}),
                b.fmt("-DCMAKE_C_COMPILER={s}", .{zigcc}),
                b.fmt("-DCMAKE_CXX_COMPILER={s}", .{zigcxx}),
                b.fmt("-DCMAKE_AR={s}", .{zigar}),
                b.fmt("-DCMAKE_RANLIB={s}", .{zigranlib}),
                b.fmt("-DCMAKE_BUILD_TYPE={s}", .{config_name}),
                "-DGGML_METAL=OFF",
            }) catch @panic("OOM");
        },
        else => std.debug.panic("unsupported host OS for llama.cpp build: {s}", .{@tagName(os)}),
    }

    const configure = b.addSystemCommand(configure_args.items);

    var build_args = std.ArrayList([]const u8).empty;
    defer build_args.deinit(b.allocator);
    build_args.appendSlice(b.allocator, &.{
        cmake,
        "--build",
        b.pathFromRoot(build_dir),
        "--target", "llama", "mtmd", "-j", "8",
    }) catch @panic("OOM");

    const build_cmd = b.addSystemCommand(build_args.items);
    build_cmd.step.dependOn(&configure.step);
    return &build_cmd.step;
}

fn addPlatformDeps(mod: *std.Build.Module, b: *std.Build, os: std.Target.Os.Tag) void {
    switch (os) {
        .macos => {
            mod.linkFramework("Foundation", .{});
            mod.linkFramework("AppKit", .{});
            mod.linkFramework("Metal", .{});
            mod.linkFramework("MetalKit", .{});
            mod.linkFramework("Accelerate", .{});
            mod.linkFramework("OpenGL", .{});
            mod.addCSourceFile(.{
                .file = b.path("src/dialog_macos.m"),
                .flags = &.{"-fobjc-arc"},
            });
        },
        .windows => {
            const win_libs = [_][]const u8{
                "opengl32", "gdi32", "user32", "shell32", "ole32", "uuid",
            };
            for (win_libs) |lib| {
                mod.linkSystemLibrary(lib, .{});
            }
            mod.addCSourceFile(.{
                .file = b.path("src/dialog_windows.c"),
                .flags = &.{},
            });
        },
        else => std.debug.panic("unsupported target OS: {s}", .{@tagName(os)}),
    }
}

fn addLlamaIncludes(mod: *std.Build.Module, b: *std.Build) void {
    const includes = [_][]const u8{
        b.pathJoin(&.{ llama_root, "include" }),
        b.pathJoin(&.{ llama_root, "ggml", "include" }),
        b.pathJoin(&.{ llama_root, "tools", "mtmd" }),
        b.pathJoin(&.{ llama_root, "common" }),
        b.pathJoin(&.{ llama_root, "vendor" }),
    };
    for (includes) |inc| {
        mod.addIncludePath(.{ .cwd_relative = b.pathFromRoot(inc) });
    }
}

fn addPackageStep(b: *std.Build, exe: *std.Build.Step.Compile, os: std.Target.Os.Tag) void {
    switch (os) {
        .macos => addMacPackageStep(b, exe),
        .windows => {
            const package_step = b.step("package", "Install audio-transcriber.exe to zig-out/bin/");
            package_step.dependOn(b.getInstallStep());
        },
        else => {
            const fail = b.addFail("packaging is only supported on macOS and Windows");
            const package_step = b.step("package", "Package the app");
            package_step.dependOn(&fail.step);
        },
    }
}

fn addMacPackageStep(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const package_step = b.step("package", "Create Audio Transcriber.app in zig-out/");

    const app_bundle = "Audio Transcriber.app";
    const app_contents = b.pathJoin(&.{ app_bundle, "Contents" });
    const plist_dest = b.pathJoin(&.{ app_contents, "Info.plist" });
    const macos_dest = b.pathJoin(&.{ app_contents, "MacOS" });
    const exe_dest = b.pathJoin(&.{ macos_dest, "audio-transcriber" });

    const install_plist = b.addInstallFile(b.path("packaging/Info.plist"), plist_dest);
    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = macos_dest } },
        .dest_sub_path = "audio-transcriber",
    });

    package_step.dependOn(&exe.step);
    package_step.dependOn(&install_plist.step);
    package_step.dependOn(&install_exe.step);

    const codesign_identity = b.option(
        []const u8,
        "codesign-identity",
        "Sign the app bundle (use \"-\" for ad-hoc signing)",
    ) orelse return;

    const entitlements = b.option(
        []const u8,
        "codesign-entitlements",
        "Optional entitlements plist passed to codesign",
    );

    const app_bundle_path = b.getInstallPath(.prefix, app_bundle);
    const exe_path = b.getInstallPath(.prefix, exe_dest);
    const ad_hoc = std.mem.eql(u8, codesign_identity, "-");

    const sign_exe = b.addSystemCommand(&.{"codesign", "--force", "--sign"});
    sign_exe.addArg(codesign_identity);
    if (entitlements) |path| {
        sign_exe.addArg("--entitlements");
        sign_exe.addArg(path);
    }
    if (!ad_hoc) {
        sign_exe.addArg("--options");
        sign_exe.addArg("runtime");
        sign_exe.addArg("--timestamp");
    }
    sign_exe.addArg(exe_path);
    sign_exe.step.dependOn(&install_exe.step);
    sign_exe.step.dependOn(&install_plist.step);

    const sign_app = b.addSystemCommand(&.{"codesign", "--force", "--sign"});
    sign_app.addArg(codesign_identity);
    if (entitlements) |path| {
        sign_app.addArg("--entitlements");
        sign_app.addArg(path);
    }
    if (!ad_hoc) {
        sign_app.addArg("--options");
        sign_app.addArg("runtime");
        sign_app.addArg("--timestamp");
    }
    sign_app.addArg(app_bundle_path);
    sign_app.step.dependOn(&sign_exe.step);

    package_step.dependOn(&sign_app.step);
}

fn addLlamaLibs(mod: *std.Build.Module, b: *std.Build, os: std.Target.Os.Tag) void {
    const build_dir = cmakeBuildDir(os);
    switch (os) {
        .macos => {
            const libs = [_][]const u8{
                b.pathJoin(&.{ build_dir, "tools", "mtmd", "libmtmd.a" }),
                b.pathJoin(&.{ build_dir, "src", "libllama.a" }),
                b.pathJoin(&.{ build_dir, "ggml", "src", "libggml.a" }),
                b.pathJoin(&.{ build_dir, "ggml", "src", "libggml-cpu.a" }),
                b.pathJoin(&.{ build_dir, "ggml", "src", "libggml-base.a" }),
                b.pathJoin(&.{ build_dir, "ggml", "src", "ggml-metal", "libggml-metal.a" }),
                b.pathJoin(&.{ build_dir, "ggml", "src", "ggml-blas", "libggml-blas.a" }),
            };
            for (libs) |lib| {
                mod.addObjectFile(.{ .cwd_relative = b.pathFromRoot(lib) });
            }
        },
        .windows => {
            const libs = [_][]const u8{
                b.pathJoin(&.{ build_dir, "tools", "mtmd", "libmtmd.a" }),
                b.pathJoin(&.{ build_dir, "src", "libllama.a" }),
                b.pathJoin(&.{ build_dir, "ggml", "src", "ggml.a" }),
                b.pathJoin(&.{ build_dir, "ggml", "src", "ggml-cpu.a" }),
                b.pathJoin(&.{ build_dir, "ggml", "src", "ggml-base.a" }),
            };
            for (libs) |lib| {
                mod.addObjectFile(.{ .cwd_relative = b.pathFromRoot(lib) });
            }
            const win_sys = [_][]const u8{ "ws2_32", "advapi32", "bcrypt" };
            for (win_sys) |lib| {
                mod.linkSystemLibrary(lib, .{});
            }
        },
        else => {},
    }
}
