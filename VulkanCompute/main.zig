const std = @import("std");
const vk_win = @import("vulkan_window.zig");
const vk_comp = @import("vulkan_compute.zig");
const c = vk_win.c;

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
    var img0 = try ctx.createStorageImage(SIM_WIDTH, SIM_HEIGHT, c.VK_FORMAT_R32_SFLOAT);
    defer img0.destroy(ctx.device);
    var img1 = try ctx.createStorageImage(SIM_WIDTH, SIM_HEIGHT, c.VK_FORMAT_R32_SFLOAT);
    defer img1.destroy(ctx.device);

    // 2. Descriptor Pool
    const pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 10 },
    };
    const pool = try ctx.createDescriptorPool(&pool_sizes, 10);
    defer c.vkDestroyDescriptorPool(ctx.device, pool, null);

    // 3. Compute Pipeline
    const comp_bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
    };
    const comp_dsl = try ctx.createDescriptorSetLayout(&comp_bindings);
    defer c.vkDestroyDescriptorSetLayout(ctx.device, comp_dsl, null);

    const pc_range = [_]c.VkPushConstantRange{.{
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
        .offset = 0,
        .size = @sizeOf(PushConstants),
    }};

    const comp_layout_info = c.VkPipelineLayoutCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &comp_dsl,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &pc_range[0],
    };
    var comp_pipeline_layout: c.VkPipelineLayout = undefined;
    _ = c.vkCreatePipelineLayout(ctx.device, &comp_layout_info, null, &comp_pipeline_layout);
    defer c.vkDestroyPipelineLayout(ctx.device, comp_pipeline_layout, null);

    const comp_spirv = try vk_comp.ShaderCompiler.compile(allocator, "sand_sim.hlsl", "main", "cs_6_0");
    defer allocator.free(comp_spirv);
    const comp_pipe = try ctx.createComputePipeline(comp_spirv, comp_pipeline_layout);
    defer c.vkDestroyPipeline(ctx.device, comp_pipe, null);

    // 4. Graphics Pipeline
    const gfx_bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
    };
    const gfx_dsl = try ctx.createDescriptorSetLayout(&gfx_bindings);
    defer c.vkDestroyDescriptorSetLayout(ctx.device, gfx_dsl, null);

    const vert_spirv = try vk_comp.ShaderCompiler.compile(allocator, "sand_display.hlsl", "VSMain", "vs_6_0");
    defer allocator.free(vert_spirv);
    const frag_spirv = try vk_comp.ShaderCompiler.compile(allocator, "sand_display.hlsl", "PSMain", "ps_6_0");
    defer allocator.free(frag_spirv);

    const gfx_pipe = try ctx.createSimpleGraphicsPipeline(vert_spirv, frag_spirv, "VSMain", "PSMain", &[_]c.VkDescriptorSetLayout{gfx_dsl});
    defer gfx_pipe.destroy(ctx.device);

    // 5. Descriptor Sets
    const setA = try ctx.allocateDescriptorSet(pool, comp_dsl);
    const setB = try ctx.allocateDescriptorSet(pool, comp_dsl);
    const setDisplay = try ctx.allocateDescriptorSet(pool, gfx_dsl);

    ctx.updateDescriptorSetImage(setA, 0, img0.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setA, 1, img1.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setB, 0, img1.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setB, 1, img0.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);

    // Initial Transition
    {
        const cmdbuf = try ctx.beginFrame();
        ctx.transitionImageLayout(cmdbuf, img0.handle, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_GENERAL);
        ctx.transitionImageLayout(cmdbuf, img1.handle, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_GENERAL);
        const clearColor = c.VkClearColorValue{ .float32 = .{ 0.0, 0.0, 0.0, 0.0 } };
        const range = c.VkImageSubresourceRange{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        c.vkCmdClearColorImage(cmdbuf, img0.handle, c.VK_IMAGE_LAYOUT_GENERAL, &clearColor, 1, &range);
        c.vkCmdClearColorImage(cmdbuf, img1.handle, c.VK_IMAGE_LAYOUT_GENERAL, &clearColor, 1, &range);
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
        c.vkCmdBindPipeline(cmdbuf, c.VK_PIPELINE_BIND_POINT_COMPUTE, comp_pipe);
        ctx.bindDescriptorSet(cmdbuf, c.VK_PIPELINE_BIND_POINT_COMPUTE, comp_pipeline_layout, activeSet);
        ctx.pushConstants(cmdbuf, comp_pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(PushConstants), &pc);
        ctx.dispatchCompute(cmdbuf, SIM_WIDTH / 16, SIM_HEIGHT / 16, 1);

        // SYNC: Compute Write -> Fragment Read
        var barrier = c.VkMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
        };
        c.vkCmdPipelineBarrier(cmdbuf, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);

        // GRAPHICS STAGE
        ctx.beginRenderPass(cmdbuf);
        {
            ctx.updateDescriptorSetImage(setDisplay, 0, outImg.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);

            c.vkCmdBindPipeline(cmdbuf, c.VK_PIPELINE_BIND_POINT_GRAPHICS, gfx_pipe.pipeline);
            ctx.bindDescriptorSet(cmdbuf, c.VK_PIPELINE_BIND_POINT_GRAPHICS, gfx_pipe.layout, setDisplay);
            c.vkCmdDraw(cmdbuf, 3, 1, 0, 0);
        }
        ctx.endRenderPass(cmdbuf);

        try ctx.endFrame();
        frame_count += 1;
    }

    _ = c.vkDeviceWaitIdle(ctx.device);
}
