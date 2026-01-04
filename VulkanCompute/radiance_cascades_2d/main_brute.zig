//==============================================================================
// RADIANCE CASCADES 2D - MAIN APPLICATION
//==============================================================================
//
// A real-time 2D global illumination demo using the Radiance Cascades algorithm.
// Written in Zig with Vulkan compute shaders for GPU acceleration.
//
// === WHAT IS RADIANCE CASCADES? ===
//
// Radiance Cascades is a multi-resolution technique for computing global
// illumination (GI) in real-time. The key insight is that far-away light
// contributions need less detail than nearby ones, so we can use lower
// resolution for distant sampling.
//
// === RENDERING PIPELINE ===
//
// Each frame executes these compute shader passes:
//
// 1. CASCADE PASS (cascade.hlsl) - Run for each level, coarse to fine:
//    - Level 0: Direct lighting + merge GI from upper levels
//    - Level 1+: Cast rays in distance interval, sample bounces from History
//
// 2. ACCUMULATE PASS (accumulate.hlsl):
//    - Blend current frame with previous frames using EMA
//    - Smooths out stochastic noise over time
//
// 3. DISPLAY PASS (display.hlsl):
//    - Reinhard tone mapping (HDR -> LDR)
//    - Gamma correction (linear -> sRGB)
//
// 4. BLIT + IMGUI:
//    - Copy result to swapchain
//    - Render debug UI overlay
//
// === CONTROLS ===
//
// - Left Click: Add light (color selected by 1-9 keys)
// - Right Click: Draw wall (color selected by 1-9 keys)
// - 1-9: Select color from palette
// - +/-: Increase/decrease brush size
// - C: Clear scene
//
// === VULKAN CONCEPTS USED ===
//
// - Compute Shaders: GPU programs for non-graphics work (our GI calculation)
// - Storage Images: Textures that shaders can write to (RWTexture2D in HLSL)
// - Push Constants: Small, fast shader parameters (like uniforms)
// - Descriptor Sets: Groups of resource bindings for shaders
// - Memory Barriers: Synchronization between shader passes
//
// Author: Nguyen Phi Hung
//==============================================================================

const std = @import("std");
const vk_win = @import("vulkan_window");
const vk_comp = @import("vulkan_compute");
const imgui = @import("imgui_backend");

const c = vk_win.c;

// Maximum number of cascade levels (resolution halves each level)
const MAX_CASCADES = 6;
const MAX_LIGHTS = 256;
const MAX_OBSTACLES = 4096;

//==============================================================================
// DATA STRUCTURES
//
// These structs are shared between Zig (CPU) and HLSL (GPU). They must be
// 'extern struct' to ensure consistent memory layout. Padding is explicit
// to match GPU alignment requirements (typically 16-byte aligned).
//==============================================================================

/// Light source for the scene. Emits radiance in a circular area.
const Light = extern struct {
    pos: [2]f32, // Position in screen coordinates
    radius: f32, // Light influence radius in pixels
    falloff: f32 = 1.0, // Attenuation exponent (1.0 = linear, 2.0 = quadratic)
    color: [3]f32, // RGB emission color (HDR - can exceed 1.0)
    padding2: f32 = 0.0,
};

/// Wall/obstacle that blocks light and can receive bounced illumination.
const Obstacle = extern struct {
    pos: [2]f32, // Position in screen coordinates
    radius: f32, // Circle radius in pixels
    padding: f32 = 0.0, // GPU alignment
    color: [3]f32, // Material albedo for rendering
    padding2: f32 = 0.0,
};

/// Push constants for the cascade shader - small, frequently changing data.
/// Push constants are faster than uniform buffers for small amounts of data
/// because they are stored directly in the command buffer.
const PushConstants = extern struct {
    level: i32, // Current cascade level (0 = base/direct)
    maxLevel: i32, // Total cascade levels
    baseRays: i32, // Ray count at level 0 (doubles each level)
    lightCount: i32, // Number of active lights
    obstacleCount: i32, // Number of active obstacles
    time: f32, // Animation time for temporal noise
    showIntervals: i32, // Debug: visualize cascade distance rings
    stochasticMode: i32, // 0 = stable dither, 1 = temporal noise
    resolution: [2]f32, // Screen dimensions
    blendRadius: f32, // Metaball SDF blend radius
    padding1: f32 = 0.0,
};

/// Push constants for the accumulate (temporal blend) shader.
const AccumConstants = extern struct {
    blend: f32, // EMA blend factor: 0 = keep history, 1 = use current
};

/// Push constants for JFA (Jump Flooding Algorithm) shaders.
const JFAConstants = extern struct {
    stepSize: i32, // 0 = Init pass, >0 = Jump pass with this step size
    obstacleCount: i32, // Number of obstacles to seed
    resolution: [2]f32, // Texture dimensions
};

/// Push constants for Display shader (Debug visualization)
const DisplayConstants = extern struct {
    debugMode: i32, // 0=None, 1=L1x, 2=L1y, 3=Vector
};

// Helper to create a buffer
fn createBufferHelper(ctx: *vk_win.WindowContext, size: u64, usage: c.VkBufferUsageFlags, properties: c.VkMemoryPropertyFlags) !vk_win.Buffer {
    // Explicitly using the pub createBuffer method from context if available, or re-implementing logic
    // We discovered ctx.createBuffer is pub!
    return try ctx.createBuffer(size, usage, properties);
}

// Helper to create a linear sampler
fn createLinearSampler(ctx: *vk_win.WindowContext) !c.VkSampler {
    const samplerInfo = c.VkSamplerCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = c.VK_FILTER_LINEAR,
        .minFilter = c.VK_FILTER_LINEAR,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .anisotropyEnable = c.VK_FALSE,
        .maxAnisotropy = 1.0,
        .borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = c.VK_FALSE,
        .compareEnable = c.VK_FALSE,
        .compareOp = c.VK_COMPARE_OP_ALWAYS,
        .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR,
    };

    var sampler: c.VkSampler = undefined;
    if (c.vkCreateSampler(ctx.device, &samplerInfo, null, &sampler) != c.VK_SUCCESS) {
        return error.SamplerCreationFailed;
    }
    return sampler;
}

// Helper to update descriptor set with buffer
fn updateDescriptorSetBuffer(ctx: *vk_win.WindowContext, set: c.VkDescriptorSet, binding: u32, buffer: c.VkBuffer, size: u64, descriptorType: c.VkDescriptorType) void {
    const bufferInfo = c.VkDescriptorBufferInfo{
        .buffer = buffer,
        .offset = 0,
        .range = size,
    };

    const write = c.VkWriteDescriptorSet{
        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = set,
        .dstBinding = binding,
        .descriptorCount = 1,
        .descriptorType = descriptorType,
        .pBufferInfo = &bufferInfo,
        .pImageInfo = null,
        .pTexelBufferView = null,
    };

    c.vkUpdateDescriptorSets(ctx.device, 1, &write, 0, null);
}

// Helper to update descriptor set with combined image sampler
//
// CASCADE SHADER BINDINGS (after texture array refactor):
// Binding 0: OutputSH (RWTexture2DArray, 3 layers: L0, L1x, L1y)
// Binding 1: UpperSH (Texture2DArray, sampled)
// Binding 2: HistorySH (Texture2DArray, sampled)
// Binding 3: Lights (StorageBuffer)
// Binding 4: Obstacles (StorageBuffer)
// Binding 5: LinearSampler
// Binding 6: JFABuffer (Texture2D)

pub fn main() void {
    run_app() catch |err| {
        std.debug.print("CRITICAL ERROR: {}\n", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        std.process.exit(1);
    };
}

fn run_app() !void {
    std.debug.print("Initializing Radiance Cascades...\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try vk_win.WindowContext.init(allocator, 1024, 1024, "Radiance Cascades 2D (Zig+Vulkan)");
    defer ctx.deinit();

    const sampler = try createLinearSampler(&ctx);
    defer c.vkDestroySampler(ctx.device, sampler, null);

    // =========================================================================
    // Resources
    // =========================================================================

    // Cascade SH Array Textures (3 layers: L0, L1x, L1y)
    var cascadesSH = try std.ArrayList(vk_win.StorageImageArray).initCapacity(allocator, MAX_CASCADES);
    defer cascadesSH.deinit(allocator);

    var w: u32 = ctx.width;
    var h: u32 = ctx.height;

    for (0..MAX_CASCADES) |_| {
        const img = try ctx.createStorageImageArray(w, h, 3, c.VK_FORMAT_R32G32B32A32_SFLOAT);
        try cascadesSH.append(allocator, img);
        w = @max(1, w / 2);
        h = @max(1, h / 2);
    }
    defer {
        for (cascadesSH.items) |img| img.destroy(ctx.device);
    }

    // History SH Array Textures (Ping Pong) - 3 layers each
    var historySH_A = try ctx.createStorageImageArray(ctx.width, ctx.height, 3, c.VK_FORMAT_R32G32B32A32_SFLOAT);
    defer historySH_A.destroy(ctx.device);
    var historySH_B = try ctx.createStorageImageArray(ctx.width, ctx.height, 3, c.VK_FORMAT_R32G32B32A32_SFLOAT);
    defer historySH_B.destroy(ctx.device);

    // Display Image
    var displayImg = try ctx.createStorageImage(ctx.width, ctx.height, c.VK_FORMAT_R8G8B8A8_UNORM);
    defer displayImg.destroy(ctx.device);

    // JFA Images (Ping-Pong for Jump Flooding Algorithm)
    // R32G32 stores (x, y) position of nearest seed
    var jfaImgA = try ctx.createStorageImage(ctx.width, ctx.height, c.VK_FORMAT_R32G32_SFLOAT);
    defer jfaImgA.destroy(ctx.device);
    var jfaImgB = try ctx.createStorageImage(ctx.width, ctx.height, c.VK_FORMAT_R32G32_SFLOAT);
    defer jfaImgB.destroy(ctx.device);

    // =========================================================================
    // ImGui Resources
    // =========================================================================

    // ImGui Descriptor Pool
    const imgui_pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 10 },
    };
    var imgui_pool_info = c.VkDescriptorPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        .maxSets = 10,
        .poolSizeCount = imgui_pool_sizes.len,
        .pPoolSizes = &imgui_pool_sizes,
    };
    var imgui_descriptor_pool: c.VkDescriptorPool = undefined;
    if (c.vkCreateDescriptorPool(ctx.device, &imgui_pool_info, null, &imgui_descriptor_pool) != c.VK_SUCCESS) {
        return error.FailedToCreateImGuiDescriptorPool;
    }
    defer c.vkDestroyDescriptorPool(ctx.device, imgui_descriptor_pool, null);

    // ImGui Render Pass (Load existing color, don't clear)
    const imgui_color_attachment = c.VkAttachmentDescription{
        .format = c.VK_FORMAT_B8G8R8A8_SRGB, // Swapchain format
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_LOAD, // Load blitted image
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };
    const imgui_color_ref = c.VkAttachmentReference{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    const imgui_subpass = c.VkSubpassDescription{
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &imgui_color_ref,
    };
    const imgui_dependency = c.VkSubpassDependency{
        .srcSubpass = c.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    };
    const imgui_rp_info = c.VkRenderPassCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &imgui_color_attachment,
        .subpassCount = 1,
        .pSubpasses = &imgui_subpass,
        .dependencyCount = 1,
        .pDependencies = &imgui_dependency,
    };
    var imgui_render_pass: c.VkRenderPass = undefined;
    if (c.vkCreateRenderPass(ctx.device, &imgui_rp_info, null, &imgui_render_pass) != c.VK_SUCCESS) {
        return error.FailedToCreateImGuiRenderPass;
    }
    defer c.vkDestroyRenderPass(ctx.device, imgui_render_pass, null);

    // ImGui Framebuffers (one per swapchain image)
    var imgui_framebuffers: [3]c.VkFramebuffer = undefined;
    for (ctx.swapchain_image_views, 0..) |view, i| {
        const fb_info = c.VkFramebufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = imgui_render_pass,
            .attachmentCount = 1,
            .pAttachments = &view,
            .width = ctx.width,
            .height = ctx.height,
            .layers = 1,
        };
        if (c.vkCreateFramebuffer(ctx.device, &fb_info, null, &imgui_framebuffers[i]) != c.VK_SUCCESS) {
            return error.FailedToCreateImGuiFramebuffer;
        }
    }
    defer {
        for (imgui_framebuffers) |fb| {
            c.vkDestroyFramebuffer(ctx.device, fb, null);
        }
    }

    // Register ImGui WndProc callback to forward Win32 messages to ImGui
    vk_win.g_wndProcCallback = imgui.imguiWndProcHandler;

    // Initialize ImGui
    var imgui_backend = try imgui.ImGuiBackend.init(
        @ptrCast(ctx.hwnd),
        @ptrCast(ctx.device),
        @ptrCast(ctx.physical_device),
        @ptrCast(ctx.instance),
        ctx.queue_family_index,
        @ptrCast(ctx.queue),
        @ptrCast(imgui_descriptor_pool),
        @ptrCast(imgui_render_pass),
        2, // minImageCount
        @intCast(ctx.swapchain_image_views.len),
    );
    defer imgui_backend.shutdown();

    // Buffers (Host Visible)
    const lightsSize = @sizeOf(Light) * MAX_LIGHTS;
    const obstaclesSize = @sizeOf(Obstacle) * MAX_OBSTACLES;

    var lightBuf = try createBufferHelper(&ctx, lightsSize, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    defer lightBuf.destroy(ctx.device);

    var obstacleBuf = try createBufferHelper(&ctx, obstaclesSize, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    defer obstacleBuf.destroy(ctx.device);

    // Persistent Mapped Pointers
    var lightDataPtr: ?*anyopaque = undefined;
    _ = c.vkMapMemory(ctx.device, lightBuf.memory, 0, lightsSize, 0, &lightDataPtr);
    defer c.vkUnmapMemory(ctx.device, lightBuf.memory);
    const lightSlice = @as([*]Light, @ptrCast(@alignCast(lightDataPtr)))[0..MAX_LIGHTS];

    var obstacleDataPtr: ?*anyopaque = undefined;
    _ = c.vkMapMemory(ctx.device, obstacleBuf.memory, 0, obstaclesSize, 0, &obstacleDataPtr);
    defer c.vkUnmapMemory(ctx.device, obstacleBuf.memory);
    const obstacleSlice = @as([*]Obstacle, @ptrCast(@alignCast(obstacleDataPtr)))[0..MAX_OBSTACLES];

    // Initial Data
    lightSlice[0] = Light{ .pos = .{ @as(f32, @floatFromInt(ctx.width)) * 0.5, @as(f32, @floatFromInt(ctx.height)) * 0.5 }, .radius = 50.0, .color = .{ 0.0, 0.8, 1.0 } }; // Cyan

    var lightCount: i32 = 1;
    var obstacleCount: i32 = 0;

    // Interaction State
    var last_mouse_x: i32 = -1;
    var last_mouse_y: i32 = -1;
    var brush_radius: f32 = 25.0;
    var light_radius: f32 = 50.0;
    var light_intensity: f32 = 1.0;
    var light_falloff: f32 = 1.0;

    // Shader Control State (exposed via ImGui)
    var stochastic_mode: bool = true;
    var blend_speed: f32 = 0.1;
    var base_rays: i32 = 4;
    var show_intervals: bool = false;
    var blend_radius: f32 = 100.0; // Metaball blend radius
    var display_debug_mode: i32 = 0; // 0=Normal, 1=L1x, 2=L1y, 3=Vector
    var accum_iterations: i32 = 1; // Number of cascade+accumulate passes per frame
    var clear_requested: bool = false; // Flag to trigger history buffer clearing

    // Color palette (indexed by 1-9 keys)
    const colors = [_][3]f32{
        .{ 1.0, 1.0, 1.0 }, // 1: White
        .{ 1.0, 0.0, 0.0 }, // 2: Red
        .{ 0.0, 1.0, 0.0 }, // 3: Green
        .{ 0.0, 0.5, 1.0 }, // 4: Blue/Cyan
        .{ 1.0, 1.0, 0.0 }, // 5: Yellow
        .{ 1.0, 0.0, 1.0 }, // 6: Magenta
        .{ 0.0, 1.0, 1.0 }, // 7: Cyan
        .{ 1.0, 0.5, 0.0 }, // 8: Orange
        .{ 0.5, 0.0, 1.0 }, // 9: Purple
    };
    var current_color_idx: usize = 3; // Default: Blue/Cyan

    // =========================================================================
    // Pipelines
    // =========================================================================

    // 1. Cascade Pipeline with Spherical Harmonics using array textures
    const cascade_bindings = &[_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // OutputSH (3-layer array)
        .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // UpperSH (3-layer array)
        .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // HistorySH (3-layer array)
        .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // Lights
        .{ .binding = 4, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // Obstacles
        .{ .binding = 5, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // Sampler
        .{ .binding = 6, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // JFA SDF
    };
    const cascade_dsl = try ctx.createDescriptorSetLayout(cascade_bindings);
    defer ctx.destroyDescriptorSetLayout(cascade_dsl);
    const cascade_layout = try ctx.createPipelineLayout(cascade_dsl, @sizeOf(PushConstants), c.VK_SHADER_STAGE_COMPUTE_BIT);
    defer ctx.destroyPipelineLayout(cascade_layout);

    // Compile Cascade Shader
    const cascade_spirv = try vk_comp.ShaderCompiler.compile(allocator, "cascade.hlsl", "main", "cs_6_0");
    defer allocator.free(cascade_spirv);
    const cascade_pipe = try ctx.createComputePipeline(cascade_spirv, cascade_layout);
    defer ctx.destroyPipeline(cascade_pipe);

    // 2. Accumulate Pipeline with SH array textures
    const accum_bindings = &[_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // ResultSH (3-layer array)
        .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // CurrentSH (3-layer array)
        .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // HistorySH (3-layer array)
    };
    const accum_dsl = try ctx.createDescriptorSetLayout(accum_bindings);
    defer ctx.destroyDescriptorSetLayout(accum_dsl);
    const accum_layout = try ctx.createPipelineLayout(accum_dsl, @sizeOf(AccumConstants), c.VK_SHADER_STAGE_COMPUTE_BIT);
    defer ctx.destroyPipelineLayout(accum_layout);

    const accum_spirv = try vk_comp.ShaderCompiler.compile(allocator, "accumulate.hlsl", "main", "cs_6_0");
    defer allocator.free(accum_spirv);
    const accum_pipe = try ctx.createComputePipeline(accum_spirv, accum_layout);
    defer ctx.destroyPipeline(accum_pipe);

    // 3. Display Pipeline (Tone Map + Debug) with SH array texture
    const display_bindings = &[_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // Output
        .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // HistorySH (3-layer array)
    };
    const display_dsl = try ctx.createDescriptorSetLayout(display_bindings);
    defer ctx.destroyDescriptorSetLayout(display_dsl);
    const display_layout = try ctx.createPipelineLayout(display_dsl, @sizeOf(DisplayConstants), c.VK_SHADER_STAGE_COMPUTE_BIT);
    defer ctx.destroyPipelineLayout(display_layout);

    const display_spirv = try vk_comp.ShaderCompiler.compile(allocator, "display.hlsl", "main", "cs_6_0");
    defer allocator.free(display_spirv);
    const display_pipe = try ctx.createComputePipeline(display_spirv, display_layout);
    defer ctx.destroyPipeline(display_pipe);

    // 4. JFA Pipeline (Jump Flooding Algorithm for SDF generation)
    const jfa_bindings = &[_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // Output
        .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // Input
        .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT }, // Obstacles
    };
    const jfa_dsl = try ctx.createDescriptorSetLayout(jfa_bindings);
    defer ctx.destroyDescriptorSetLayout(jfa_dsl);
    const jfa_layout = try ctx.createPipelineLayout(jfa_dsl, @sizeOf(JFAConstants), c.VK_SHADER_STAGE_COMPUTE_BIT);
    defer ctx.destroyPipelineLayout(jfa_layout);

    // Compile JFA shaders (separate init and jump passes)
    const jfa_init_spirv = try vk_comp.ShaderCompiler.compile(allocator, "jfa_init.hlsl", "main", "cs_6_0");
    defer allocator.free(jfa_init_spirv);
    const jfa_init_pipe = try ctx.createComputePipeline(jfa_init_spirv, jfa_layout);
    defer ctx.destroyPipeline(jfa_init_pipe);

    const jfa_jump_spirv = try vk_comp.ShaderCompiler.compile(allocator, "jfa_jump.hlsl", "main", "cs_6_0");
    defer allocator.free(jfa_jump_spirv);
    const jfa_jump_pipe = try ctx.createComputePipeline(jfa_jump_spirv, jfa_layout);
    defer ctx.destroyPipeline(jfa_jump_pipe);

    // =========================================================================
    // Descriptor Pool & Sets
    // =========================================================================
    // We need lots of sets.
    // Cascade Sets: MAX_CASCADES (Ping Pong frame count? No, just 1 set of sets usually sufficient if we bind correctly, but better to have 1 per level).
    // Let's alloc one set per level.
    const pool = try ctx.createDescriptorPool(&.{
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 100 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 100 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 20 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 10 },
    }, 100);
    defer ctx.destroyDescriptorPool(pool);

    var cascadeSets = try std.ArrayList(c.VkDescriptorSet).initCapacity(allocator, MAX_CASCADES);
    defer cascadeSets.deinit(allocator);

    for (0..MAX_CASCADES) |_| {
        const set = try ctx.allocateDescriptorSet(pool, cascade_dsl);
        try cascadeSets.append(allocator, set);

        // Bind constant buffers
        updateDescriptorSetBuffer(&ctx, set, 3, lightBuf.handle, lightsSize, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER);
        updateDescriptorSetBuffer(&ctx, set, 4, obstacleBuf.handle, obstaclesSize, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER);

        // Bind Sampler
        const samplerInfo = c.VkDescriptorImageInfo{
            .imageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED, // Ignored for pure sampler
            .imageView = null,
            .sampler = sampler,
        };
        const write = c.VkWriteDescriptorSet{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = set,
            .dstBinding = 5,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER,
            .pImageInfo = &samplerInfo,
        };
        c.vkUpdateDescriptorSets(ctx.device, 1, &write, 0, null);
    }

    // Accum/Display Sets
    // We need 2 Accum sets (Flip History A->B and B->A)
    const accumSetA = try ctx.allocateDescriptorSet(pool, accum_dsl);
    const accumSetB = try ctx.allocateDescriptorSet(pool, accum_dsl);

    const displaySet = try ctx.allocateDescriptorSet(pool, display_dsl);

    // JFA Sets (Ping-Pong for iterative jump flooding)
    const jfaSetA = try ctx.allocateDescriptorSet(pool, jfa_dsl);
    const jfaSetB = try ctx.allocateDescriptorSet(pool, jfa_dsl);

    // =========================================================================
    // Loop
    // =========================================================================
    const start_time = std.time.milliTimestamp();
    var frame_count: u32 = 0;

    // Initialize Images
    {
        const cmdbuf = try ctx.beginFrame();
        // Clear all cascade SH array textures (3 layers each)
        for (cascadesSH.items) |img| {
            ctx.transitionImageLayout(cmdbuf, img.handle, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_GENERAL);
            ctx.clearImage(cmdbuf, img.handle, c.VK_IMAGE_LAYOUT_GENERAL, 0, 0, 0, 0);
        }
        // Clear history SH array textures
        ctx.transitionImageLayout(cmdbuf, historySH_A.handle, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_GENERAL);
        ctx.clearImage(cmdbuf, historySH_A.handle, c.VK_IMAGE_LAYOUT_GENERAL, 0, 0, 0, 0);
        ctx.transitionImageLayout(cmdbuf, historySH_B.handle, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_GENERAL);
        ctx.clearImage(cmdbuf, historySH_B.handle, c.VK_IMAGE_LAYOUT_GENERAL, 0, 0, 0, 0);
        ctx.transitionImageLayout(cmdbuf, displayImg.handle, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_GENERAL);
        ctx.transitionImageLayout(cmdbuf, jfaImgA.handle, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_GENERAL);
        ctx.transitionImageLayout(cmdbuf, jfaImgB.handle, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_GENERAL);

        // Also transition Sampled bits for History/Upper?
        // Layout GENERAL is compatible with everything usually (Storage+Sampled).
        // Best to keep everything GENERAL for simplicity for now.

        ctx.beginRenderPass(cmdbuf);
        ctx.endRenderPass(cmdbuf); // Just to satisfy graph?
        try ctx.endFrame();
    }

    while (ctx.update()) {
        // Handle resize: skip frame if swapchain is out of date
        const cmdbuf = ctx.beginFrame() catch |err| {
            if (err == error.SwapchainOutOfDate) {
                // Window was resized - recreate swapchain and skip this frame
                ctx.recreateSwapchain() catch |recreate_err| {
                    std.debug.print("Failed to recreate swapchain: {}\\n", .{recreate_err});
                    return recreate_err;
                };
                continue;
            }
            return err;
        };

        // Input Handling
        const mx = ctx.mouse_x;
        const my = ctx.mouse_y;

        // Skip drawing input if ImGui wants the mouse (mouse is over ImGui window)
        const imgui_wants_mouse = imgui.wantCaptureMouse();

        // Left Click: Add Light
        if (ctx.mouse_left and !imgui_wants_mouse) {
            const dx = mx - last_mouse_x;
            const dy = my - last_mouse_y;
            const dist_sq = dx * dx + dy * dy;

            if (last_mouse_x == -1 or dist_sq > 400) {
                if (lightCount < MAX_LIGHTS) {
                    lightSlice[@intCast(lightCount)] = Light{
                        .pos = .{ @as(f32, @floatFromInt(mx)), @as(f32, @floatFromInt(my)) },
                        .radius = light_radius,
                        .falloff = light_falloff,
                        .color = .{
                            colors[current_color_idx][0] * light_intensity,
                            colors[current_color_idx][1] * light_intensity,
                            colors[current_color_idx][2] * light_intensity,
                        },
                    };
                    lightCount += 1;
                    std.debug.print("Added light {d} at ({d}, {d}) color={d}\n", .{ lightCount, mx, my, current_color_idx + 1 });
                    last_mouse_x = mx;
                    last_mouse_y = my;
                }
            }
        } else if (ctx.mouse_right and !imgui_wants_mouse) {
            // Right Click: Add Wall
            const dx = mx - last_mouse_x;
            const dy = my - last_mouse_y;
            const dist_sq = dx * dx + dy * dy;

            if (last_mouse_x == -1 or dist_sq > 400) {
                if (obstacleCount < MAX_OBSTACLES) {
                    obstacleSlice[@intCast(obstacleCount)] = Obstacle{
                        .pos = .{ @as(f32, @floatFromInt(mx)), @as(f32, @floatFromInt(my)) },
                        .radius = brush_radius,
                        .color = colors[current_color_idx], // Use selected color
                    };
                    obstacleCount += 1;
                    std.debug.print("Added wall {d} at ({d}, {d})\n", .{ obstacleCount, mx, my });
                    last_mouse_x = mx;
                    last_mouse_y = my;
                }
            }
        } else {
            last_mouse_x = -1;
            last_mouse_y = -1;
        }

        // 'C' Key: Clear
        if (ctx.key_pressed == 'C') {
            lightCount = 0;
            obstacleCount = 0;
            // Clear history SH array images
            ctx.clearImage(cmdbuf, historySH_A.handle, c.VK_IMAGE_LAYOUT_GENERAL, 0, 0, 0, 0);
            ctx.clearImage(cmdbuf, historySH_B.handle, c.VK_IMAGE_LAYOUT_GENERAL, 0, 0, 0, 0);
            // Clear cascades SH too
            for (cascadesSH.items) |img| {
                ctx.clearImage(cmdbuf, img.handle, c.VK_IMAGE_LAYOUT_GENERAL, 0, 0, 0, 0);
            }
            std.debug.print("Cleared scene\n", .{});
        }

        // '+' Key: Increase brush size (VK_OEM_PLUS = 0xBB on US layout, or '=' key)
        if (ctx.key_pressed == 0xBB or ctx.key_pressed == '=') {
            brush_radius = @min(brush_radius + 5.0, 100.0);
            std.debug.print("Brush size: {d}\n", .{brush_radius});
        }

        // '-' Key: Decrease brush size (VK_OEM_MINUS = 0xBD)
        if (ctx.key_pressed == 0xBD or ctx.key_pressed == '-') {
            brush_radius = @max(brush_radius - 5.0, 5.0);
            std.debug.print("Brush size: {d}\n", .{brush_radius});
        }

        // Number keys 1-9: Select color
        if (ctx.key_pressed >= '1' and ctx.key_pressed <= '9') {
            current_color_idx = ctx.key_pressed - '1';
            std.debug.print("Color: {d}\n", .{current_color_idx + 1});
        }

        // 'D' Key: Toggle Debug Mode (0=Normal, 1=L1x, 2=L1y, 3=Vector)
        if (ctx.key_pressed == 'D') {
            display_debug_mode = @mod(display_debug_mode + 1, 4);
            std.debug.print("Debug Mode: {d}\n", .{display_debug_mode});
        }

        const current_time = std.time.milliTimestamp();
        const elapsed = @as(f32, @floatFromInt(current_time - start_time)) / 1000.0;

        // Render Pipeline

        // History Pointers for SH array textures
        const historySHRead = if (frame_count % 2 == 0) historySH_A else historySH_B;
        const historySHWrite = if (frame_count % 2 == 0) historySH_B else historySH_A;

        // Clear history buffers if requested (for instant Clear Scene effect)
        if (clear_requested) {
            ctx.clearImageArray(cmdbuf, historySH_A.handle, c.VK_IMAGE_LAYOUT_GENERAL, 3, 0, 0, 0, 0);
            ctx.clearImageArray(cmdbuf, historySH_B.handle, c.VK_IMAGE_LAYOUT_GENERAL, 3, 0, 0, 0, 0);
            ctx.memoryBarrier(cmdbuf, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_ACCESS_TRANSFER_WRITE_BIT, c.VK_ACCESS_SHADER_READ_BIT);
            clear_requested = false;
        }

        // 1. JFA Pass (Generate SDF from obstacles)
        var jfaResult = jfaImgA;
        {
            // Update JFA Descriptors
            ctx.updateDescriptorSetImage(jfaSetA, 0, jfaImgA.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
            ctx.updateDescriptorSetImage(jfaSetA, 1, jfaImgB.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
            updateDescriptorSetBuffer(&ctx, jfaSetA, 2, obstacleBuf.handle, obstaclesSize, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER);

            ctx.updateDescriptorSetImage(jfaSetB, 0, jfaImgB.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
            ctx.updateDescriptorSetImage(jfaSetB, 1, jfaImgA.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
            updateDescriptorSetBuffer(&ctx, jfaSetB, 2, obstacleBuf.handle, obstaclesSize, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER);

            // Init Pass: Seed obstacle positions
            {
                const pc_jfa = JFAConstants{
                    .stepSize = 0,
                    .obstacleCount = obstacleCount,
                    .resolution = .{ @as(f32, @floatFromInt(ctx.width)), @as(f32, @floatFromInt(ctx.height)) },
                };
                ctx.bindComputePipeline(cmdbuf, jfa_init_pipe);
                ctx.bindDescriptorSet(cmdbuf, c.VK_PIPELINE_BIND_POINT_COMPUTE, jfa_layout, jfaSetA);
                ctx.pushConstants(cmdbuf, jfa_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(JFAConstants), &pc_jfa);
                ctx.dispatchCompute(cmdbuf, (ctx.width + 15) / 16, (ctx.height + 15) / 16, 1);
                ctx.memoryBarrier(cmdbuf, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_ACCESS_SHADER_WRITE_BIT, c.VK_ACCESS_SHADER_READ_BIT);
                jfaResult = jfaImgA;
            }

            // Jump Passes: Flood nearest seed info
            const max_dim = @max(ctx.width, ctx.height);
            const max_steps = std.math.log2_int(u32, max_dim);

            if (max_steps > 0) {
                var use_set_b = true;
                var step: u32 = @as(u32, 1) << @intCast(max_steps - 1);
                while (step >= 1) : (step /= 2) {
                    const pc_jfa = JFAConstants{
                        .stepSize = @intCast(step),
                        .obstacleCount = obstacleCount,
                        .resolution = .{ @as(f32, @floatFromInt(ctx.width)), @as(f32, @floatFromInt(ctx.height)) },
                    };
                    const set = if (use_set_b) jfaSetB else jfaSetA;
                    ctx.bindComputePipeline(cmdbuf, jfa_jump_pipe);
                    ctx.bindDescriptorSet(cmdbuf, c.VK_PIPELINE_BIND_POINT_COMPUTE, jfa_layout, set);
                    ctx.pushConstants(cmdbuf, jfa_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(JFAConstants), &pc_jfa);
                    ctx.dispatchCompute(cmdbuf, (ctx.width + 15) / 16, (ctx.height + 15) / 16, 1);
                    ctx.memoryBarrier(cmdbuf, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_ACCESS_SHADER_WRITE_BIT, c.VK_ACCESS_SHADER_READ_BIT);
                    jfaResult = if (use_set_b) jfaImgB else jfaImgA;
                    use_set_b = !use_set_b;
                }
            }
        }

        // 2. Cascades (Coarse -> Fine)
        // MaxLevel-1 downto 0
        const maxLevel = MAX_CASCADES;

        // Pre-barrier: ensure HistoryRead is safe to read
        // It was written last frame.

        var i: i32 = maxLevel - 1;
        while (i >= 0) : (i -= 1) {
            const levelIdx = @as(usize, @intCast(i));
            const targetSH = cascadesSH.items[levelIdx];
            const upperSH = if (i < maxLevel - 1) cascadesSH.items[levelIdx + 1] else cascadesSH.items[maxLevel - 1];

            // Update Descriptor Set for this level (simplified for array textures)
            // Binding 0: OutputSH (3-layer array)
            ctx.updateDescriptorSetImage(cascadeSets.items[levelIdx], 0, targetSH.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
            // Binding 1: UpperSH (3-layer array)
            ctx.updateDescriptorSetImage(cascadeSets.items[levelIdx], 1, upperSH.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
            // Binding 2: HistorySH (3-layer array)
            ctx.updateDescriptorSetImage(cascadeSets.items[levelIdx], 2, historySHRead.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
            // Binding 6: JFA SDF
            ctx.updateDescriptorSetImage(cascadeSets.items[levelIdx], 6, jfaResult.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);

            const pc = PushConstants{
                .resolution = .{ @as(f32, @floatFromInt(ctx.width)), @as(f32, @floatFromInt(ctx.height)) },
                .level = i,
                .maxLevel = maxLevel,
                .time = elapsed,
                .baseRays = base_rays,
                .lightCount = lightCount,
                .obstacleCount = obstacleCount,
                .showIntervals = if (show_intervals) 1 else 0,
                .stochasticMode = if (stochastic_mode) 1 else 0,
                .blendRadius = blend_radius,
            };

            ctx.bindComputePipeline(cmdbuf, cascade_pipe);
            ctx.bindDescriptorSet(cmdbuf, c.VK_PIPELINE_BIND_POINT_COMPUTE, cascade_layout, cascadeSets.items[levelIdx]);
            ctx.pushConstants(cmdbuf, cascade_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(PushConstants), &pc);

            const gx = (targetSH.width + 15) / 16;
            const gy = (targetSH.height + 15) / 16;
            ctx.dispatchCompute(cmdbuf, gx, gy, 1);

            // Barrier for Next Level (reading this level as upper)
            ctx.memoryBarrier(cmdbuf, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_ACCESS_SHADER_WRITE_BIT, c.VK_ACCESS_SHADER_READ_BIT);
        }

        // 2. Accumulate
        // Input: Cascade[0], HistoryRead
        // Output: HistoryWrite (Result)

        const activeAccumSet = if (frame_count % 2 == 0) accumSetA else accumSetB;

        // Bind SH array textures (simplified: 3 bindings instead of 9)
        // Binding 0: ResultSH (output)
        ctx.updateDescriptorSetImage(activeAccumSet, 0, historySHWrite.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
        // Binding 1: CurrentSH (cascade output)
        ctx.updateDescriptorSetImage(activeAccumSet, 1, cascadesSH.items[0].view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);
        // Binding 2: HistorySH (previous frame)
        ctx.updateDescriptorSetImage(activeAccumSet, 2, historySHRead.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);

        ctx.bindComputePipeline(cmdbuf, accum_pipe);
        ctx.bindDescriptorSet(cmdbuf, c.VK_PIPELINE_BIND_POINT_COMPUTE, accum_layout, activeAccumSet);
        // Blend speed: in stochastic mode use slider value * accum_iterations, otherwise instant (1.0)
        const effective_blend = if (stochastic_mode) @min(blend_speed * @as(f32, @floatFromInt(accum_iterations)), 1.0) else 1.0;
        const ac = AccumConstants{ .blend = effective_blend };
        ctx.pushConstants(cmdbuf, accum_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(AccumConstants), &ac);

        ctx.dispatchCompute(cmdbuf, (ctx.width + 15) / 16, (ctx.height + 15) / 16, 1);
        ctx.memoryBarrier(cmdbuf, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_ACCESS_SHADER_WRITE_BIT, c.VK_ACCESS_SHADER_READ_BIT);

        // 3. Display
        // Input: HistorySHWrite (array texture)
        // Output: DisplayImg
        ctx.updateDescriptorSetImage(displaySet, 0, displayImg.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE);
        ctx.updateDescriptorSetImage(displaySet, 1, historySHWrite.view, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE);

        ctx.bindComputePipeline(cmdbuf, display_pipe);

        const pc_display = DisplayConstants{ .debugMode = display_debug_mode };
        ctx.pushConstants(cmdbuf, display_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(DisplayConstants), &pc_display);

        ctx.bindDescriptorSet(cmdbuf, c.VK_PIPELINE_BIND_POINT_COMPUTE, display_layout, displaySet);
        ctx.dispatchCompute(cmdbuf, (ctx.width + 15) / 16, (ctx.height + 15) / 16, 1);

        ctx.memoryBarrier(cmdbuf, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_ACCESS_SHADER_WRITE_BIT, c.VK_ACCESS_TRANSFER_READ_BIT);

        // 4. Blit to Swapchain
        ctx.transitionForBlitSrc(cmdbuf, displayImg.handle, c.VK_IMAGE_LAYOUT_GENERAL);
        ctx.transitionForBlitDst(cmdbuf, ctx.getCurrentSwapchainImage(), c.VK_IMAGE_LAYOUT_UNDEFINED);
        ctx.blitImage(cmdbuf, displayImg.handle, ctx.width, ctx.height, ctx.getCurrentSwapchainImage(), ctx.width, ctx.height);
        ctx.transitionFromBlitSrcToGeneral(cmdbuf, displayImg.handle);

        // 5. ImGui Render Pass
        // Transition swapchain to color attachment for ImGui rendering
        const barrier_to_color = c.VkImageMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = ctx.getCurrentSwapchainImage(),
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        c.vkCmdPipelineBarrier(cmdbuf, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, &barrier_to_color);

        // ImGui NewFrame
        imgui_backend.newFrame();

        // Debug UI Window
        if (imgui.begin("Radiance Cascades Debug")) {
            imgui.text("Drawing:");
            _ = imgui.sliderFloat("Brush Size", &brush_radius, 5.0, 100.0);
            _ = imgui.sliderFloat("Light Radius", &light_radius, 0.01, 300.0);
            _ = imgui.sliderFloat("Light Intensity", &light_intensity, 0.01, 10.0);
            _ = imgui.sliderFloat("Light Falloff", &light_falloff, 0.1, 16.0);
            imgui.text("Colors (press 1-9 keys)");

            imgui.text("");
            imgui.text("Rendering:");
            _ = imgui.checkbox("Stochastic Mode", &stochastic_mode);
            _ = imgui.sliderFloat("Blend Speed", &blend_speed, 0.001, 2.0);
            _ = imgui.sliderInt("Accum Iterations", &accum_iterations, 1, 16);
            _ = imgui.sliderInt("Base Rays", &base_rays, 1, 80);
            _ = imgui.checkbox("Show Intervals", &show_intervals);
            _ = imgui.sliderFloat("GI Smoothness", &blend_radius, 50.0, 200.0);

            imgui.text("");
            if (imgui.button("Clear Scene")) {
                lightCount = 0;
                obstacleCount = 0;
                clear_requested = true;
            }
        }
        imgui.end();

        // Begin ImGui Render Pass
        const rp_info = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = imgui_render_pass,
            .framebuffer = imgui_framebuffers[ctx.current_image_index],
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = ctx.width, .height = ctx.height } },
            .clearValueCount = 0,
            .pClearValues = null,
        };
        c.vkCmdBeginRenderPass(cmdbuf, &rp_info, c.VK_SUBPASS_CONTENTS_INLINE);
        imgui_backend.render(@ptrCast(cmdbuf));
        c.vkCmdEndRenderPass(cmdbuf);

        // Final transition to present is handled by render pass finalLayout

        // Handle resize on frame end as well
        ctx.endFrame() catch |err| {
            if (err == error.SwapchainOutOfDate) {
                ctx.recreateSwapchain() catch |recreate_err| {
                    std.debug.print("Failed to recreate swapchain on present: {}\\n", .{recreate_err});
                    return recreate_err;
                };
                continue;
            }
            return err;
        };
        frame_count += 1;
    }

    ctx.waitIdle();
}
