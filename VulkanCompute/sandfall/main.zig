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

pub fn main() !void {
    std.debug.print("Initializing Window...\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize our abstraction layer. This creates the Win32 window,
    // selects a GPU, and sets up the swapchain (the images shown on screen).
    var ctx = try vk_win.WindowContext.init(allocator, 1024, 1024, "Falling Sand GPU");
    defer ctx.deinit();

    // 1. RESOURCE CREATION
    // We create two 'Storage Images'. One for the current state, one for the next state.
    // This 'ping-pong' buffering prevents reading and writing to the same image simultaneously.
    var img0 = try ctx.createStorageImage(SIM_WIDTH, SIM_HEIGHT, vk_win.VK_FORMAT_R32_SFLOAT);
    defer img0.destroy(ctx.device);
    var img1 = try ctx.createStorageImage(SIM_WIDTH, SIM_HEIGHT, vk_win.VK_FORMAT_R32_SFLOAT);
    defer img1.destroy(ctx.device);

    // 2. DESCRIPTOR POOL
    // Descriptors are "pointers" that tell the GPU which resources to use.
    // We must allocate them from a Pool.
    const pool = try ctx.createDescriptorPool(&.{
        .{ .type = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 10 },
    }, 10);
    defer ctx.destroyDescriptorPool(pool);

    // 3. COMPUTE PIPELINE SETUP (The Brains)
    // First, we define the 'Descriptor Set Layout' (the interface).
    // Our compute shader expects two images (Current state at binding 0, Next state at binding 1).
    const comp_dsl = try ctx.createDescriptorSetLayout(&.{
        .{ .binding = 0, .descriptorType = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = vk_win.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        .{ .binding = 1, .descriptorType = vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = vk_win.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
    });
    defer ctx.destroyDescriptorSetLayout(comp_dsl);

    // The 'Pipeline Layout' combines the DSL and our PushConstants definition.
    const comp_pipeline_layout = try ctx.createPipelineLayout(comp_dsl, @sizeOf(PushConstants), vk_win.VK_SHADER_STAGE_COMPUTE_BIT);
    defer ctx.destroyPipelineLayout(comp_pipeline_layout);

    // Compile HLSL to SPIR-V (the bytecode GPUs understand) and create the pipeline.
    const comp_spirv = try vk_comp.ShaderCompiler.compile(allocator, "sand_sim.hlsl", "main", "cs_6_0");
    defer allocator.free(comp_spirv);
    const comp_pipe = try ctx.createComputePipeline(comp_spirv, comp_pipeline_layout);
    defer ctx.destroyPipeline(comp_pipe);

    // 4. GRAPHICS PIPELINE SETUP (The Eyes)
    // The Graphics pipeline converts our simulation data into pixels on the screen.
    // It expects ONE image to read from (our simulation result).
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

    // 5. DESCRIPTOR SET ALLOCATION & BINDING
    // We allocate sets and link them to our specific images.
    // SetA: img0 -> img1 (img0 is current)
    // SetB: img1 -> img0 (img1 is current)
    const setA = try ctx.allocateDescriptorSet(pool, comp_dsl);
    const setB = try ctx.allocateDescriptorSet(pool, comp_dsl);
    const setDisplay = try ctx.allocateDescriptorSet(pool, gfx_dsl);

    ctx.updateDescriptorSetImage(setA, 0, img0.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setA, 1, img1.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setB, 0, img1.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
    ctx.updateDescriptorSetImage(setB, 1, img0.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);

    // 6. INITIALIZATION FRAME: Preparing the Opaque Blobs
    // In Vulkan, an Image is just an "Opaque Blob" of memory. The GPU needs to know
    // its "Layout" to access it efficiently (e.g., for writing vs. reading).
    //
    // - VK_IMAGE_LAYOUT_UNDEFINED: The starting state. The data is garbage/unknown.
    // - VK_IMAGE_LAYOUT_GENERAL: A flexible layout that allows the Compute shader to
    //   both Read and Write (necessary for our simulation).
    //
    // We also "Clear" the images to black (0.0). Since these images persist between
    // frames, we must define their initial state, or they might contain random GPU memory noise.
    {
        // Even for initialization, we follow the 'Frame' cycle because our WindowContext
        // handles the boilerplate of getting a command buffer and syncing with the screen.
        const cmdbuf = try ctx.beginFrame();

        // Tell the GPU: "This raw memory blob (img0/1) is now a General-purpose simulation grid."
        ctx.transitionImageLayout(cmdbuf, img0.handle, vk_win.VK_IMAGE_LAYOUT_UNDEFINED, vk_win.VK_IMAGE_LAYOUT_GENERAL);
        ctx.transitionImageLayout(cmdbuf, img1.handle, vk_win.VK_IMAGE_LAYOUT_UNDEFINED, vk_win.VK_IMAGE_LAYOUT_GENERAL);

        // Wipe the grid clean. Without this, the simulation might start with "ghost" sand.
        ctx.clearImage(cmdbuf, img0.handle, vk_win.VK_IMAGE_LAYOUT_GENERAL, 0.0, 0.0, 0.0, 0.0);
        ctx.clearImage(cmdbuf, img1.handle, vk_win.VK_IMAGE_LAYOUT_GENERAL, 0.0, 0.0, 0.0, 0.0);

        // We run an "Empty" Render Pass.
        // Our 'beginFrame' acquired a screen image from the Swapchain; 'endFrame' expects us
        // to have done something with it (or at least acknowledge it) before it can Present.
        ctx.beginRenderPass(cmdbuf);
        ctx.endRenderPass(cmdbuf);

        // Submit these setup commands to the GPU.
        try ctx.endFrame();
    }

    var frame_count: u32 = 0;
    std.debug.print("Starting simulation loop...\n", .{});

    // MAIN SIMULATION LOOP
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

        // Determine which image is the 'Source' this frame (ping-ponging)
        const activeSet = if (frame_count % 2 == 0) setA else setB;
        const outImg = if (frame_count % 2 == 0) img1 else img0;

        // --- COMPUTE STAGE ---
        // We "dispatch" threads to run our sand simulation shader.
        // Each thread handles one pixel of the simulation.
        ctx.bindComputePipeline(cmdbuf, comp_pipe);
        ctx.bindDescriptorSet(cmdbuf, vk_win.VK_PIPELINE_BIND_POINT_COMPUTE, comp_pipeline_layout, activeSet);
        ctx.pushConstants(cmdbuf, comp_pipeline_layout, vk_win.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(PushConstants), &pc);
        ctx.dispatchCompute(cmdbuf, SIM_WIDTH / 16, SIM_HEIGHT / 16, 1);

        // --- SYNCHRONIZATION ---
        // CRITICAL: We must tell the GPU to finish all COMPUTE writes (Compute Shader Bit)
        // before the graphics engine starts reading (Fragment Shader Bit).
        ctx.memoryBarrier(cmdbuf, vk_win.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, vk_win.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, vk_win.VK_ACCESS_SHADER_WRITE_BIT, vk_win.VK_ACCESS_SHADER_READ_BIT);

        // --- GRAPHICS STAGE ---
        // We draw a single full-screen triangle. The Fragment shader reads the simulation
        // result and paints it onto the triangle.
        ctx.beginRenderPass(cmdbuf);
        {
            // Update the display set to point to the IMAGE WE JUST FINISHED WRITING.
            ctx.updateDescriptorSetImage(setDisplay, 0, outImg.view, vk_win.VK_IMAGE_LAYOUT_GENERAL, vk_win.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);

            ctx.bindGraphicsPipeline(cmdbuf, gfx_pipe.pipeline);
            ctx.bindDescriptorSet(cmdbuf, vk_win.VK_PIPELINE_BIND_POINT_GRAPHICS, gfx_pipe.layout, setDisplay);

            // Draw 3 vertices to make a large triangle that covers the screen.
            ctx.draw(cmdbuf, 3, 1, 0, 0);
        }
        ctx.endRenderPass(cmdbuf);

        // Submit commands to the GPU and Present to the screen.
        try ctx.endFrame();
        frame_count += 1;
    }

    // Wait for the GPU to finish everything before we close.
    ctx.waitIdle();
}
