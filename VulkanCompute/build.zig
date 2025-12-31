const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "ZigVulkanCompute",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.linkLibC();

    // Attempt to locate Vulkan SDK
    // We check the environment variable VULKAN_SDK
    if (std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK")) |sdk_path| {
        defer b.allocator.free(sdk_path);

        // Add Library Path: %VULKAN_SDK%/Lib
        const lib_path = b.pathJoin(&.{ sdk_path, "Lib" });
        exe.addLibraryPath(.{ .cwd_relative = lib_path });

        // Add Include Path: %VULKAN_SDK%/Include
        const inc_path = b.pathJoin(&.{ sdk_path, "Include" });
        exe.addIncludePath(.{ .cwd_relative = inc_path });
    } else |_| {
        // Fallback to discovered path
        const sdk_path = "C:\\VulkanSDK\\1.4.335.0";
        const lib_path = b.pathJoin(&.{ sdk_path, "Lib" });
        const inc_path = b.pathJoin(&.{ sdk_path, "Include" });

        exe.addLibraryPath(.{ .cwd_relative = lib_path });
        exe.addIncludePath(.{ .cwd_relative = inc_path });

        std.debug.print("VULKAN_SDK not set. Using fallback: {s}\n", .{sdk_path});
    }

    exe.linkSystemLibrary("vulkan-1");

    // Install the executable
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    // Shader compilation step (optional helper, but we need comp.spv)
    // We can add a custom step to compile shaders if dxc is available
}
