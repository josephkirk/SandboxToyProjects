// ImGui Backend for Vulkan + Win32
// Wraps the cimgui C API for Zig usage with Vulkan rendering and Win32 input

const std = @import("std");

pub const c = @cImport({
    @cInclude("dcimgui.h");
    @cInclude("backends/dcimgui_impl_vulkan.h");
    @cInclude("backends/dcimgui_impl_win32.h");
});

const vk = @import("vulkan_window");

// Vulkan function loader callback for ImGui
fn vulkanLoader(name: [*c]const u8, user_data: ?*anyopaque) callconv(.c) ?*const fn () callconv(.c) void {
    // Cast to vk.c's VkInstance type (different cimport)
    const instance: vk.c.VkInstance = @ptrCast(user_data);
    return vk.c.vkGetInstanceProcAddr(instance, name);
}

pub const ImGuiBackend = struct {
    initialized: bool = false,

    pub fn init(hwnd: *anyopaque, device: *anyopaque, physical_device: *anyopaque, instance: *anyopaque, queue_family: u32, queue: *anyopaque, descriptor_pool: *anyopaque, render_pass: *anyopaque, min_image_count: u32, image_count: u32) !ImGuiBackend {
        // Create ImGui context
        if (c.ImGui_CreateContext(null) == null) {
            return error.ImGuiCreateContextFailed;
        }

        const io = c.ImGui_GetIO();
        io.*.ConfigFlags |= c.ImGuiConfigFlags_NavEnableKeyboard;

        // Dark theme
        c.ImGui_StyleColorsDark(null);

        // Initialize Win32 backend
        if (!c.cImGui_ImplWin32_Init(hwnd)) {
            return error.ImGuiWin32InitFailed;
        }

        // Initialize Vulkan backend
        // First, load Vulkan functions via the loader callback
        if (!c.cImGui_ImplVulkan_LoadFunctionsEx(c.VK_API_VERSION_1_2, vulkanLoader, instance)) {
            return error.ImGuiVulkanLoadFunctionsFailed;
        }

        var init_info = c.ImGui_ImplVulkan_InitInfo{};
        init_info.Instance = @ptrCast(instance);
        init_info.PhysicalDevice = @ptrCast(physical_device);
        init_info.Device = @ptrCast(device);
        init_info.QueueFamily = queue_family;
        init_info.Queue = @ptrCast(queue);
        init_info.DescriptorPool = @ptrCast(descriptor_pool);
        init_info.MinImageCount = min_image_count;
        init_info.ImageCount = image_count;
        init_info.PipelineInfoMain.RenderPass = @ptrCast(render_pass);
        init_info.PipelineInfoMain.Subpass = 0;
        init_info.PipelineInfoMain.MSAASamples = c.VK_SAMPLE_COUNT_1_BIT;

        if (!c.cImGui_ImplVulkan_Init(&init_info)) {
            return error.ImGuiVulkanInitFailed;
        }

        return ImGuiBackend{ .initialized = true };
    }

    pub fn newFrame(self: *ImGuiBackend) void {
        if (!self.initialized) return;
        c.cImGui_ImplVulkan_NewFrame();
        c.cImGui_ImplWin32_NewFrame();
        c.ImGui_NewFrame();
    }

    pub fn render(self: *ImGuiBackend, command_buffer: *anyopaque) void {
        if (!self.initialized) return;
        c.ImGui_Render();
        const draw_data = c.ImGui_GetDrawData();
        c.cImGui_ImplVulkan_RenderDrawData(draw_data, @ptrCast(command_buffer));
    }

    pub fn shutdown(self: *ImGuiBackend) void {
        if (!self.initialized) return;
        c.cImGui_ImplVulkan_Shutdown();
        c.cImGui_ImplWin32_Shutdown();
        c.ImGui_DestroyContext(null);
        self.initialized = false;
    }
};

// Helper functions for common UI elements
pub fn sliderFloat(label: [*:0]const u8, value: *f32, min: f32, max: f32) bool {
    return c.ImGui_SliderFloat(label, value, min, max);
}

pub fn sliderInt(label: [*:0]const u8, value: *i32, min: i32, max: i32) bool {
    return c.ImGui_SliderInt(label, value, min, max);
}

pub fn colorEdit3(label: [*:0]const u8, col: *[3]f32) bool {
    return c.ImGui_ColorEdit3(label, col, 0);
}

pub fn checkbox(label: [*:0]const u8, value: *bool) bool {
    return c.ImGui_Checkbox(label, value);
}

pub fn text(fmt: [*:0]const u8) void {
    c.ImGui_Text(fmt);
}

pub fn begin(name: [*:0]const u8) bool {
    return c.ImGui_Begin(name, null, 0);
}

pub fn end() void {
    c.ImGui_End();
}

pub fn button(label: [*:0]const u8) bool {
    return c.ImGui_Button(label);
}

pub fn sameLine() void {
    c.ImGui_SameLine();
}
