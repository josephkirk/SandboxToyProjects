const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "nbody-viewer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const raylib_path = "../../thirdparties/raylib-5.5_win64_msvc16";
    exe.addIncludePath(b.path(b.pathJoin(&.{ raylib_path, "include" })));
    exe.addLibraryPath(b.path(b.pathJoin(&.{ raylib_path, "lib" })));
    exe.linkSystemLibrary("raylib");

    // Link Rust Simulation Library
    const rust_lib_path = "../simulation/target/release";
    exe.addLibraryPath(b.path(rust_lib_path));
    exe.linkSystemLibrary("nbody_simulation");

    // Link C library explicitly
    exe.linkLibC();
    exe.linkLibCpp();

    // Windows system libraries for Raylib and Rust
    exe.linkSystemLibrary("winmm");
    exe.linkSystemLibrary("gdi32");
    exe.linkSystemLibrary("user32");
    exe.linkSystemLibrary("shell32");
    exe.linkSystemLibrary("opengl32");
    exe.linkSystemLibrary("advapi32");
    exe.linkSystemLibrary("ws2_32");
    exe.linkSystemLibrary("userenv");
    exe.linkSystemLibrary("bcrypt");
    exe.linkSystemLibrary("ntdll");

    b.installArtifact(exe);

    // Copy raylib.dll to the output directory
    const copy_dll = b.addInstallFile(
        b.path(b.pathJoin(&.{ raylib_path, "lib", "raylib.dll" })),
        "bin/raylib.dll",
    );
    b.getInstallStep().dependOn(&copy_dll.step);

    const copy_sim_dll = b.addInstallFile(
        b.path(b.pathJoin(&.{ rust_lib_path, "nbody_simulation.dll" })),
        "bin/nbody_simulation.dll",
    );
    b.getInstallStep().dependOn(&copy_sim_dll.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
