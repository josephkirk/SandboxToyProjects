const std = @import("std");
const vk_win = @import("vulkan_window");
const vk_comp = @import("vulkan_compute");

// Simulation resolution. This can be lower than window resolution for performance.
const SIM_WIDTH = 512;
const SIM_HEIGHT = 512;

/// PushConstants allow us to send small amounts of data (like mouse position)
/// directly to the shader without creating a separate buffer.
/// They are extremely fast but limited in size (usually 128-256 bytes).
const PushConstants = extern struct {
    mouseX: i32,
    mouseY: i32,
    mouseLeft: i32,
    mouseRight: i32,
    frame: u32,
};

/// CRT Post-Process parameters - time-based effects
const CRTParams = extern struct {
    time: f32, // Current time in seconds
    flickerSpeed: f32, // Speed of flicker effect
    scanSpeed: f32, // Speed of scanning line
    padding: f32, // Alignment padding
};

pub fn main() !void {
    std.debug.print("Initializing Window...\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize our abstraction layer. This creates the Win32 window,
    // selects a GPU, and sets up the swapchain (the images shown on screen).
    var ctx = try vk_win.WindowContext.init(allocator, 1024, 1024, "Falling Sand GPU + TAA");
    defer ctx.deinit();

    // =========================================================================
    // 1. RESOURCE CREATION
    // =========================================================================

    // Simulation state images (ping-pong buffering for cellular automata).
    var img0 = try ctx.createStorageImage(SIM_WIDTH, SIM_HEIGHT, vk_win.VK_FORMAT_R32_SFLOAT);
    defer img0.destroy(ctx.device);
    var img1 = try ctx.createStorageImage(SIM_WIDTH, SIM_HEIGHT, vk_win.VK_FORMAT_R32_SFLOAT);
    defer img1.destroy(ctx.device);

    // =========================================================================
    // TAA (Temporal Anti-Aliasing) RESOURCES
    // =========================================================================
    // TAA works by blending the current frame with previous frames to smooth out
    // aliasing artifacts. We need three images:
    //
    // 1. taaCurrentFrame: The "raw" rendered frame before TAA processing
    // 2. taaHistory: Accumulated result from ALL previous frames (exponential moving average)
    // 3. taaOutput: The blended result that gets displayed
    //
    // Each frame, we blend: output = lerp(history, current, 0.15)
    // Then history = output for next frame.
    //
    var taaCurrentFrame = try ctx.createStorageImage(ctx.width, ctx.height, vk_win.VK_FORMAT_R8G8B8A8_UNORM);
    defer taaCurrentFrame.destroy(ctx.device);
    var taaHistory = try ctx.createStorageImage(ctx.width, ctx.height, vk_win.VK_FORMAT_R8G8B8A8_UNORM);
    defer taaHistory.destroy(ctx.device);
    var taaOutput = try ctx.createStorageImage(ctx.width, ctx.height, vk_win.VK_FORMAT_R8G8B8A8_UNORM);
    defer taaOutput.destroy(ctx.device);

    // =========================================================================
    // 2. DESCRIPTOR POOL
    // =========================================================================
    const pool = try ctx.createDescriptorPool(&.{
        .{ .type = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 20 },
    }, 20);
    defer ctx.destroyDescriptorPool(pool);

    // =========================================================================
    // 3. COMPUTE PIPELINE SETUP (Sand Simulation)
    // =========================================================================
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

    // =========================================================================
    // 4. GRAPHICS PIPELINE SETUP (Two display modes)
    // =========================================================================
    // Press 1: Simple colored shader (HLSL)
    // Press 2: CRT terminal text effect (GLSL)
    const gfx_dsl = try ctx.createDescriptorSetLayout(&.{
        .{ .binding = 0, .descriptorType = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = vk_win.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
    });
    defer ctx.destroyDescriptorSetLayout(gfx_dsl);

    // MODE 1: Simple colored display (HLSL)
    const simple_vert_spirv = try vk_comp.ShaderCompiler.compile(allocator, "sand_display.hlsl", "VSMain", "vs_6_0");
    defer allocator.free(simple_vert_spirv);
    const simple_frag_spirv = try vk_comp.ShaderCompiler.compile(allocator, "sand_display.hlsl", "PSMain", "ps_6_0");
    defer allocator.free(simple_frag_spirv);
    const gfx_pipe_simple = try ctx.createSimpleGraphicsPipeline(simple_vert_spirv, simple_frag_spirv, "VSMain", "PSMain", &.{gfx_dsl});
    defer gfx_pipe_simple.destroy(ctx.device);

    // MODE 2: CRT terminal text effect (GLSL)
    const crt_vert_spirv = try vk_comp.ShaderCompiler.compile(allocator, "sand_crt.vert.glsl", "main", "");
    defer allocator.free(crt_vert_spirv);
    const crt_frag_spirv = try vk_comp.ShaderCompiler.compile(allocator, "sand_crt.frag.glsl", "main", "");
    defer allocator.free(crt_frag_spirv);
    const gfx_pipe_crt = try ctx.createSimpleGraphicsPipeline(crt_vert_spirv, crt_frag_spirv, "main", "main", &.{gfx_dsl});
    defer gfx_pipe_crt.destroy(ctx.device);

    // =========================================================================
    // 5. TAA RESOLVE COMPUTE PIPELINE
    // =========================================================================
    // The TAA resolve shader takes 3 images:
    //   binding 0: taaCurrentFrame (READ)  - This frame's raw render
    //   binding 1: taaHistory (READ/WRITE) - Accumulated history from past frames
    //   binding 2: taaOutput (WRITE)       - Final blended result
    //
    // The shader performs neighborhood clamping to prevent ghosting artifacts
    // when objects move quickly, then blends in linear color space for accuracy.
    //
    const taa_dsl = try ctx.createDescriptorSetLayout(&.{
        .{ .binding = 0, .descriptorType = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = vk_win.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        .{ .binding = 1, .descriptorType = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = vk_win.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        .{ .binding = 2, .descriptorType = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = vk_win.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
    });
    defer ctx.destroyDescriptorSetLayout(taa_dsl);

    const taa_pipeline_layout = try ctx.createPipelineLayout(taa_dsl, 0, 0);
    defer ctx.destroyPipelineLayout(taa_pipeline_layout);

    const taa_spirv = try vk_comp.ShaderCompiler.compile(allocator, "taa_resolve.hlsl", "main", "cs_6_0");
    defer allocator.free(taa_spirv);
    const taa_pipe = try ctx.createComputePipeline(taa_spirv, taa_pipeline_layout);
    defer ctx.destroyPipeline(taa_pipe);

    // =========================================================================
    // 6. CRT POST-PROCESS COMPUTE PIPELINE (HLSL) - Final Pass
    // =========================================================================
    // Adds animated CRT effects: scrolling scanlines, flicker, chromatic aberration
    // This demonstrates the FULL pipeline:
    //   Compute(HLSL) → Fragment(GLSL) → Compute(HLSL TAA) → Compute(HLSL CRT)
    //
    var crtOutput = try ctx.createStorageImage(ctx.width, ctx.height, vk_win.VK_FORMAT_R8G8B8A8_UNORM);
    defer crtOutput.destroy(ctx.device);

    const crt_dsl = try ctx.createDescriptorSetLayout(&.{
        .{ .binding = 0, .descriptorType = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = vk_win.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        .{ .binding = 1, .descriptorType = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = vk_win.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
    });
    defer ctx.destroyDescriptorSetLayout(crt_dsl);

    const crt_pipeline_layout = try ctx.createPipelineLayout(crt_dsl, @sizeOf(CRTParams), vk_win.VK_SHADER_STAGE_COMPUTE_BIT);
    defer ctx.destroyPipelineLayout(crt_pipeline_layout);

    const crt_spirv = try vk_comp.ShaderCompiler.compile(allocator, "crt_postprocess.hlsl", "main", "cs_6_0");
    defer allocator.free(crt_spirv);
    const crt_pipe = try ctx.createComputePipeline(crt_spirv, crt_pipeline_layout);
    defer ctx.destroyPipeline(crt_pipe);

    // =========================================================================
    // 6. DESCRIPTOR SET ALLOCATION & BINDING
    // =========================================================================
    const setA = try ctx.allocateDescriptorSet(pool, comp_dsl);
    const setB = try ctx.allocateDescriptorSet(pool, comp_dsl);
    const setDisplay = try ctx.allocateDescriptorSet(pool, gfx_dsl);
    const setTAA = try ctx.allocateDescriptorSet(pool, taa_dsl);

    // Bind simulation images (ping-pong pattern)
    ctx.updateDescriptorSetImage(setA, 0, img0.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setA, 1, img1.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setB, 0, img1.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setB, 1, img0.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);

    // Bind TAA images
    ctx.updateDescriptorSetImage(setTAA, 0, taaCurrentFrame.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setTAA, 1, taaHistory.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setTAA, 2, taaOutput.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);

    // Allocate and bind CRT post-process descriptor set
    const setCRT = try ctx.allocateDescriptorSet(pool, crt_dsl);
    ctx.updateDescriptorSetImage(setCRT, 0, taaOutput.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setCRT, 1, crtOutput.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);

    // =========================================================================
    // 7. INITIALIZATION FRAME
    // =========================================================================
    // Clear all images to defined initial states
    {
        const cmdbuf = try ctx.beginFrame();

        // Transition and clear simulation images
        ctx.transitionImageLayout(cmdbuf, img0.handle, vk_win.VK_IMAGE_LAYOUT_UNDEFINED, vk_win.VK_IMAGE_LAYOUT_GENERAL);
        ctx.transitionImageLayout(cmdbuf, img1.handle, vk_win.VK_IMAGE_LAYOUT_UNDEFINED, vk_win.VK_IMAGE_LAYOUT_GENERAL);
        ctx.clearImage(cmdbuf, img0.handle, vk_win.VK_IMAGE_LAYOUT_GENERAL, 0.0, 0.0, 0.0, 0.0);
        ctx.clearImage(cmdbuf, img1.handle, vk_win.VK_IMAGE_LAYOUT_GENERAL, 0.0, 0.0, 0.0, 0.0);

        // Transition and clear TAA images
        ctx.transitionImageLayout(cmdbuf, taaCurrentFrame.handle, vk_win.VK_IMAGE_LAYOUT_UNDEFINED, vk_win.VK_IMAGE_LAYOUT_GENERAL);
        ctx.transitionImageLayout(cmdbuf, taaHistory.handle, vk_win.VK_IMAGE_LAYOUT_UNDEFINED, vk_win.VK_IMAGE_LAYOUT_GENERAL);
        ctx.transitionImageLayout(cmdbuf, taaOutput.handle, vk_win.VK_IMAGE_LAYOUT_UNDEFINED, vk_win.VK_IMAGE_LAYOUT_GENERAL);
        ctx.clearImage(cmdbuf, taaCurrentFrame.handle, vk_win.VK_IMAGE_LAYOUT_GENERAL, 0.0, 0.0, 0.0, 1.0);
        ctx.clearImage(cmdbuf, taaHistory.handle, vk_win.VK_IMAGE_LAYOUT_GENERAL, 0.0, 0.0, 0.0, 1.0);
        ctx.clearImage(cmdbuf, taaOutput.handle, vk_win.VK_IMAGE_LAYOUT_GENERAL, 0.0, 0.0, 0.0, 1.0);

        // Initialize CRT output image
        ctx.transitionImageLayout(cmdbuf, crtOutput.handle, vk_win.VK_IMAGE_LAYOUT_UNDEFINED, vk_win.VK_IMAGE_LAYOUT_GENERAL);
        ctx.clearImage(cmdbuf, crtOutput.handle, vk_win.VK_IMAGE_LAYOUT_GENERAL, 0.0, 0.0, 0.0, 1.0);

        ctx.beginRenderPass(cmdbuf);
        ctx.endRenderPass(cmdbuf);
        try ctx.endFrame();
    }

    var frame_count: u32 = 0;
    const start_time = std.time.milliTimestamp();

    // Display mode: 1 = simple colored, 2 = CRT terminal text
    var display_mode: u8 = 2; // Start with CRT mode
    // TAA toggle: true = enabled, false = disabled
    var taa_enabled: bool = true;
    std.debug.print("Controls: 1=Simple, 2=CRT, 3=Toggle TAA\n", .{});

    // =========================================================================
    // MAIN SIMULATION LOOP
    // =========================================================================
    // Each frame follows this pipeline:
    //
    //   ┌─────────────────┐
    //   │ 1. SAND COMPUTE │  Simulate physics (cellular automata)
    //   └────────┬────────┘
    //            ▼
    //   ┌─────────────────┐
    //   │ 2. RENDER PASS  │  Draw simulation state to swapchain
    //   └────────┬────────┘
    //            ▼
    //   ┌─────────────────┐
    //   │ 3. COPY TO TAA  │  Swapchain → taaCurrentFrame
    //   └────────┬────────┘
    //            ▼
    //   ┌─────────────────┐
    //   │ 4. TAA RESOLVE  │  Blend current + history → output
    //   └────────┬────────┘  (Also updates history for next frame)
    //            ▼
    //   ┌─────────────────┐
    //   │ 5. BLIT OUTPUT  │  taaOutput → swapchain for display
    //   └────────┬────────┘
    //            ▼
    //        [PRESENT]
    //
    while (ctx.update()) {
        const cmdbuf = try ctx.beginFrame();

        // Prepare mouse and frame data for the shader
        const pc = PushConstants{
            .mouseX = @intCast(@divTrunc(ctx.mouse_x * SIM_WIDTH, @as(i32, @intCast(ctx.width)))),
            .mouseY = @intCast(@divTrunc(ctx.mouse_y * SIM_HEIGHT, @as(i32, @intCast(ctx.height)))),
            .mouseLeft = if (ctx.mouse_left) 1 else 0,
            .mouseRight = if (ctx.mouse_right) 1 else 0,
            .frame = frame_count,
        };

        const activeSet = if (frame_count % 2 == 0) setA else setB;
        const outImg = if (frame_count % 2 == 0) img1 else img0;

        // =====================================================================
        // STAGE 1: COMPUTE (Sand Simulation)
        // =====================================================================
        // Run the cellular automata simulation. Each pixel reads neighbors and
        // decides whether sand falls, walls block, etc.
        ctx.bindComputePipeline(cmdbuf, comp_pipe);
        ctx.bindDescriptorSet(cmdbuf, vk_win.VK_PIPELINE_BIND_POINT_COMPUTE, comp_pipeline_layout, activeSet);
        ctx.pushConstants(cmdbuf, comp_pipeline_layout, vk_win.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(PushConstants), &pc);
        ctx.dispatchCompute(cmdbuf, SIM_WIDTH / 16, SIM_HEIGHT / 16, 1);

        // SYNC: Wait for compute writes before fragment shader reads
        ctx.memoryBarrier(cmdbuf, vk_win.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk_win.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, vk_win.VK_ACCESS_SHADER_WRITE_BIT, vk_win.VK_ACCESS_SHADER_READ_BIT);

        // =====================================================================
        // STAGE 2: GRAPHICS (Render simulation to swapchain)
        // =====================================================================
        // Draw a fullscreen triangle. The fragment shader samples the simulation
        // texture and applies visualization (simple or CRT text based on mode).
        //
        // Toggle with number keys:
        //   1 = Simple colored shader (HLSL)
        //   2 = CRT terminal text (GLSL)
        //
        if (ctx.key_pressed == 1) {
            display_mode = 1;
            std.debug.print("Display mode: Simple\n", .{});
        } else if (ctx.key_pressed == 2) {
            display_mode = 2;
            std.debug.print("Display mode: CRT Terminal\n", .{});
        } else if (ctx.key_pressed == 3) {
            taa_enabled = !taa_enabled;
            if (taa_enabled) {
                std.debug.print("TAA: ON\n", .{});
            } else {
                std.debug.print("TAA: OFF\n", .{});
            }
        }

        const active_pipe = if (display_mode == 1) gfx_pipe_simple else gfx_pipe_crt;

        ctx.beginRenderPass(cmdbuf);
        {
            ctx.updateDescriptorSetImage(setDisplay, 0, outImg.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
            ctx.bindGraphicsPipeline(cmdbuf, active_pipe.pipeline);
            ctx.bindDescriptorSet(cmdbuf, vk_win.VK_PIPELINE_BIND_POINT_GRAPHICS, active_pipe.layout, setDisplay);
            ctx.draw(cmdbuf, 3, 1, 0, 0);
        }
        ctx.endRenderPass(cmdbuf);

        // =====================================================================
        // STAGE 3-5: TAA AND CRT POST-PROCESSING (conditional)
        // =====================================================================
        if (taa_enabled) {
            // --- STAGE 3: COPY SWAPCHAIN -> taaCurrentFrame ---
            ctx.transitionForBlitSrc(cmdbuf, ctx.getCurrentSwapchainImage(), vk_win.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
            ctx.transitionForBlitDst(cmdbuf, taaCurrentFrame.handle, vk_win.VK_IMAGE_LAYOUT_GENERAL);
            ctx.blitImage(cmdbuf, ctx.getCurrentSwapchainImage(), ctx.width, ctx.height, taaCurrentFrame.handle, ctx.width, ctx.height);
            ctx.transitionFromBlitDstToGeneral(cmdbuf, taaCurrentFrame.handle);

            // --- STAGE 4: TAA RESOLVE ---
            ctx.bindComputePipeline(cmdbuf, taa_pipe);
            ctx.bindDescriptorSet(cmdbuf, vk_win.VK_PIPELINE_BIND_POINT_COMPUTE, taa_pipeline_layout, setTAA);
            ctx.dispatchCompute(cmdbuf, ctx.width / 16, ctx.height / 16, 1);

            // --- STAGE 5: CRT POST-PROCESS ---
            ctx.memoryBarrier(cmdbuf, vk_win.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk_win.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk_win.VK_ACCESS_SHADER_WRITE_BIT, vk_win.VK_ACCESS_SHADER_READ_BIT);

            const current_time = std.time.milliTimestamp();
            const elapsed_seconds: f32 = @as(f32, @floatFromInt(current_time - start_time)) / 1000.0;

            const crt_params = CRTParams{
                .time = elapsed_seconds,
                .flickerSpeed = 15.0,
                .scanSpeed = 2.0,
                .padding = 0.0,
            };

            ctx.bindComputePipeline(cmdbuf, crt_pipe);
            ctx.bindDescriptorSet(cmdbuf, vk_win.VK_PIPELINE_BIND_POINT_COMPUTE, crt_pipeline_layout, setCRT);
            ctx.pushConstants(cmdbuf, crt_pipeline_layout, vk_win.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(CRTParams), &crt_params);
            ctx.dispatchCompute(cmdbuf, ctx.width / 16, ctx.height / 16, 1);

            // --- STAGE 6: BLIT CRT OUTPUT -> SWAPCHAIN ---
            ctx.transitionForBlitSrc(cmdbuf, crtOutput.handle, vk_win.VK_IMAGE_LAYOUT_GENERAL);
            ctx.transitionForBlitDst(cmdbuf, ctx.getCurrentSwapchainImage(), vk_win.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
            ctx.blitImage(cmdbuf, crtOutput.handle, ctx.width, ctx.height, ctx.getCurrentSwapchainImage(), ctx.width, ctx.height);
            ctx.transitionForPresent(cmdbuf, ctx.getCurrentSwapchainImage());
            ctx.transitionFromBlitSrcToGeneral(cmdbuf, crtOutput.handle);
        } else {
            // TAA disabled - just present the swapchain directly
            ctx.transitionForPresent(cmdbuf, ctx.getCurrentSwapchainImage());
        }

        try ctx.endFrame();
        frame_count += 1;
    }

    ctx.waitIdle();
}
