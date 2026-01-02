const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ZigClient",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const raylib_path = "../../../thirdparties/raylib-5.5_win64_msvc16";
    exe.addIncludePath(b.path(std.fmt.allocPrint(b.allocator, "{s}/include", .{raylib_path}) catch unreachable));
    exe.addLibraryPath(b.path(std.fmt.allocPrint(b.allocator, "{s}/lib", .{raylib_path}) catch unreachable));

    exe.linkSystemLibrary("raylib");
    exe.linkSystemLibrary("opengl32");
    exe.linkSystemLibrary("gdi32");
    exe.linkSystemLibrary("winmm");
    exe.linkSystemLibrary("shell32");
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the client");
    run_step.dependOn(&run_cmd.step);
}
