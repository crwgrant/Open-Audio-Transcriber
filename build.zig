const std = @import("std");

const llama_root = "deps/llama.cpp.zig/llama.cpp";
const cmake_build_dir = ".zig-cache/llama-cpp";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const llama_step = addLlamaCppBuild(b, optimize);

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });

    const exe = b.addExecutable(.{
        .name = "audio-transcriber",
        .root_module = root_mod,
    });

    exe.step.dependOn(llama_step);

    root_mod.linkFramework("Foundation", .{});
    root_mod.linkFramework("AppKit", .{});
    root_mod.linkFramework("Metal", .{});
    root_mod.linkFramework("MetalKit", .{});
    root_mod.linkFramework("Accelerate", .{});
    root_mod.linkFramework("OpenGL", .{});

    addLlamaIncludes(root_mod, b);
    addLlamaLibs(root_mod, b);

    root_mod.addCSourceFile(.{
        .file = b.path("src/dialog_macos.m"),
        .flags = &.{"-fobjc-arc"},
    });

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
    addPackageStep(b, exe, target);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the audio transcriber app");
    run_step.dependOn(&run_cmd.step);
}

fn addLlamaCppBuild(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const build_type = switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "RelWithDebInfo",
        .ReleaseFast, .ReleaseSmall => "Release",
    };

    const configure = b.addSystemCommand(&.{
        "/opt/homebrew/bin/cmake",
        "-S", b.pathFromRoot(llama_root),
        "-B", b.pathFromRoot(cmake_build_dir),
        b.fmt("-DCMAKE_BUILD_TYPE={s}", .{build_type}),
        "-DGGML_METAL=ON",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DLLAMA_BUILD_TESTS=OFF",
        "-DLLAMA_BUILD_EXAMPLES=OFF",
        "-DLLAMA_BUILD_SERVER=OFF",
    });

    const build_cmd = b.addSystemCommand(&.{
        "/opt/homebrew/bin/cmake",
        "--build",
        b.pathFromRoot(cmake_build_dir),
        "--target",
        "llama",
        "mtmd",
        "-j",
        "8",
    });
    build_cmd.step.dependOn(&configure.step);
    return &build_cmd.step;
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

fn addPackageStep(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const package_step = b.step("package", "Create Audio Transcriber.app in zig-out/");

    if (target.result.os.tag != .macos) {
        const fail = b.addFail("packaging is only supported on macOS");
        package_step.dependOn(&fail.step);
        return;
    }

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

fn addLlamaLibs(mod: *std.Build.Module, b: *std.Build) void {
    const libs = [_][]const u8{
        b.pathJoin(&.{ cmake_build_dir, "tools", "mtmd", "libmtmd.a" }),
        b.pathJoin(&.{ cmake_build_dir, "src", "libllama.a" }),
        b.pathJoin(&.{ cmake_build_dir, "ggml", "src", "libggml.a" }),
        b.pathJoin(&.{ cmake_build_dir, "ggml", "src", "libggml-cpu.a" }),
        b.pathJoin(&.{ cmake_build_dir, "ggml", "src", "libggml-base.a" }),
        b.pathJoin(&.{ cmake_build_dir, "ggml", "src", "ggml-metal", "libggml-metal.a" }),
        b.pathJoin(&.{ cmake_build_dir, "ggml", "src", "ggml-blas", "libggml-blas.a" }),
    };
    for (libs) |lib| {
        mod.addObjectFile(.{ .cwd_relative = b.pathFromRoot(lib) });
    }
}
