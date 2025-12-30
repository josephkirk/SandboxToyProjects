const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "windsim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const raylib_path = "../thirdparties/raylib-5.5_win64_msvc16";
    exe.addIncludePath(b.path(b.pathJoin(&.{ raylib_path, "include" })));
    exe.addLibraryPath(b.path(b.pathJoin(&.{ raylib_path, "lib" })));
    exe.linkSystemLibrary("raylib");

    // Link C library explicitly
    exe.linkLibC();
    exe.linkLibCpp();

    // Add C header path for the shim import
    exe.addIncludePath(b.path("libs"));

    // Windows system libraries for Raylib
    exe.linkSystemLibrary("winmm");
    exe.linkSystemLibrary("gdi32");
    exe.linkSystemLibrary("user32");
    exe.linkSystemLibrary("shell32");
    exe.linkSystemLibrary("opengl32");

    exe.addCSourceFile(.{
        .file = b.path("libs/windsim_shim.cpp"),
        .flags = &.{
            "-std=c++20",
            "-mavx2",
            "-O3",
        },
    });

    exe.linkLibCpp();

    b.installArtifact(exe);

    // Copy raylib.dll to the output directory
    const copy_dll = b.addInstallFile(
        b.path(b.pathJoin(&.{ raylib_path, "lib", "raylib.dll" })),
        "bin/raylib.dll",
    );
    b.getInstallStep().dependOn(&copy_dll.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
