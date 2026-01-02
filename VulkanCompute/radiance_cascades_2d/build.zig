const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create modules for the Vulkan abstraction library
    const vk_win_mod = b.createModule(.{
        .root_source_file = b.path("../vulkan/vulkan_window.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const vk_comp_mod = b.createModule(.{
        .root_source_file = b.path("../vulkan/vulkan_compute.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "ZigVulkanCompute_RadianceCascades",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Add imports to the main module
    exe.root_module.addImport("vulkan_window", vk_win_mod);
    exe.root_module.addImport("vulkan_compute", vk_comp_mod);

    // Attempt to locate Vulkan SDK
    var sdk_path_opt: ?[]const u8 = null;
    if (std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK")) |sdk_path| {
        sdk_path_opt = sdk_path;
    } else |_| {
        // Fallback or try to find it
        sdk_path_opt = b.allocator.dupe(u8, "C:\\VulkanSDK\\1.4.335.0") catch unreachable;
        std.debug.print("VULKAN_SDK not set. Using fallback: {s}\n", .{sdk_path_opt.?});
    }

    if (sdk_path_opt) |sdk_path| {
        defer b.allocator.free(sdk_path);

        const lib_path = b.pathJoin(&.{ sdk_path, "Lib" });
        const inc_path = b.pathJoin(&.{ sdk_path, "Include" });

        // Use cwd_relative for absolute paths
        const inc_lazy = std.Build.LazyPath{ .cwd_relative = inc_path };
        const lib_lazy = std.Build.LazyPath{ .cwd_relative = lib_path };

        exe.addLibraryPath(lib_lazy);
        exe.addIncludePath(inc_lazy);

        // Modules also need include paths for @cInclude
        vk_win_mod.addIncludePath(inc_lazy);
        vk_comp_mod.addIncludePath(inc_lazy);
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
}
