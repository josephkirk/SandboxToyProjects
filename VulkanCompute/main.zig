const std = @import("std");
const vk_win = @import("vulkan_window.zig");
const vk_comp = @import("vulkan_compute.zig");

const SIM_WIDTH = 512;
const SIM_HEIGHT = 512;

const PushConstants = extern struct {
    mouseX: i32,
    mouseY: i32,
    mouseLeft: i32,
    mouseRight: i32,
    frame: u32,
};

pub fn main() !void {
    std.debug.print("Initializing Window...\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try vk_win.WindowContext.init(allocator, 1024, 1024, "Falling Sand GPU");
    defer ctx.deinit();

    // 1. Resources
    var img0 = try ctx.createStorageImage(SIM_WIDTH, SIM_HEIGHT, vk_win.VK_FORMAT_R32_SFLOAT);
    defer img0.destroy(ctx.device);
    var img1 = try ctx.createStorageImage(SIM_WIDTH, SIM_HEIGHT, vk_win.VK_FORMAT_R32_SFLOAT);
    defer img1.destroy(ctx.device);

    // 2. Descriptor Pool
    const pool = try ctx.createDescriptorPool(&.{
        .{ .type = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 10 },
    }, 10);
    defer ctx.destroyDescriptorPool(pool);

    // 3. Compute Pipeline
    const comp_dsl = try ctx.createDescriptorSetLayout(&.{
        .{ .binding = 0, .descriptorType = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = vk_win.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        .{ .binding = 1, .descriptorType = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = vk_win.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
    });
    defer ctx.destroyDescriptorSetLayout(comp_dsl);

    const comp_pipeline_layout = try ctx.createPipelineLayout(comp_dsl, @sizeOf(PushConstants), vk_win.VK_SHADER_STAGE_COMPUTE_BIT);
    defer ctx.destroyPipelineLayout(comp_pipeline_layout);

    const comp_spirv = try vk_comp.ShaderCompiler.compile(allocator, "sand_sim.hlsl", "main", "cs_6_0");
    defer allocator.free(comp_spirv);
    const comp_pipe = try ctx.createComputePipeline(comp_spirv, comp_pipeline_layout);
    defer ctx.destroyPipeline(comp_pipe);

    // 4. Graphics Pipeline
    const gfx_dsl = try ctx.createDescriptorSetLayout(&.{
        .{ .binding = 0, .descriptorType = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = vk_win.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
    });
    defer ctx.destroyDescriptorSetLayout(gfx_dsl);

    const vert_spirv = try vk_comp.ShaderCompiler.compile(allocator, "sand_display.hlsl", "VSMain", "vs_6_0");
    defer allocator.free(vert_spirv);
    const frag_spirv = try vk_comp.ShaderCompiler.compile(allocator, "sand_display.hlsl", "PSMain", "ps_6_0");
    defer allocator.free(frag_spirv);

    const gfx_pipe = try ctx.createSimpleGraphicsPipeline(vert_spirv, frag_spirv, "VSMain", "PSMain", &.{gfx_dsl});
    defer gfx_pipe.destroy(ctx.device);

    // 5. Descriptor Sets
    const setA = try ctx.allocateDescriptorSet(pool, comp_dsl);
    const setB = try ctx.allocateDescriptorSet(pool, comp_dsl);
    const setDisplay = try ctx.allocateDescriptorSet(pool, gfx_dsl);

    ctx.updateDescriptorSetImage(setA, 0, img0.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setA, 1, img1.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setB, 0, img1.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setB, 1, img0.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);

    // Initial Transition
    {
        const cmdbuf = try ctx.beginFrame();
        ctx.transitionImageLayout(cmdbuf, img0.handle, vk_win.VK_IMAGE_LAYOUT_UNDEFINED, vk_win.VK_IMAGE_LAYOUT_GENERAL);
        ctx.transitionImageLayout(cmdbuf, img1.handle, vk_win.VK_IMAGE_LAYOUT_UNDEFINED, vk_win.VK_IMAGE_LAYOUT_GENERAL);
        ctx.clearImage(cmdbuf, img0.handle, vk_win.VK_IMAGE_LAYOUT_GENERAL, 0.0, 0.0, 0.0, 0.0);
        ctx.clearImage(cmdbuf, img1.handle, vk_win.VK_IMAGE_LAYOUT_GENERAL, 0.0, 0.0, 0.0, 0.0);
        ctx.beginRenderPass(cmdbuf);
        ctx.endRenderPass(cmdbuf);
        try ctx.endFrame();
    }

    var frame_count: u32 = 0;
    std.debug.print("Starting simulation loop...\n", .{});
    while (ctx.update()) {
        const cmdbuf = try ctx.beginFrame();

        const pc = PushConstants{
            .mouseX = @intCast(@divTrunc(ctx.mouse_x * SIM_WIDTH, @as(i32, @intCast(ctx.width)))),
            .mouseY = @intCast(@divTrunc(ctx.mouse_y * SIM_HEIGHT, @as(i32, @intCast(ctx.height)))),
            .mouseLeft = if (ctx.mouse_left) 1 else 0,
            .mouseRight = if (ctx.mouse_right) 1 else 0,
            .frame = frame_count,
        };

        const activeSet = if (frame_count % 2 == 0) setA else setB;
        const outImg = if (frame_count % 2 == 0) img1 else img0;

        // COMPUTE STAGE
        ctx.bindComputePipeline(cmdbuf, comp_pipe);
        ctx.bindDescriptorSet(cmdbuf, vk_win.VK_PIPELINE_BIND_POINT_COMPUTE, comp_pipeline_layout, activeSet);
        ctx.pushConstants(cmdbuf, comp_pipeline_layout, vk_win.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(PushConstants), &pc);
        ctx.dispatchCompute(cmdbuf, SIM_WIDTH / 16, SIM_HEIGHT / 16, 1);

        // SYNC: Compute Write -> Fragment Read
        ctx.memoryBarrier(cmdbuf, vk_win.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk_win.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, vk_win.VK_ACCESS_SHADER_WRITE_BIT, vk_win.VK_ACCESS_SHADER_READ_BIT);

        // GRAPHICS STAGE
        ctx.beginRenderPass(cmdbuf);
        {
            ctx.updateDescriptorSetImage(setDisplay, 0, outImg.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
            ctx.bindGraphicsPipeline(cmdbuf, gfx_pipe.pipeline);
            ctx.bindDescriptorSet(cmdbuf, vk_win.VK_PIPELINE_BIND_POINT_GRAPHICS, gfx_pipe.layout, setDisplay);
            ctx.draw(cmdbuf, 3, 1, 0, 0);
        }
        ctx.endRenderPass(cmdbuf);

        try ctx.endFrame();
        frame_count += 1;
    }

    ctx.waitIdle();
}
