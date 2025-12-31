const std = @import("std");
const builtin = @import("builtin");

// We only support Windows for this simple window library
pub const os = if (builtin.os.tag == .windows) std.os.windows else @compileError("Only Windows is supported");
pub const WINAPI: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86) .stdcall else .c;

pub const c = @cImport({
    @cDefine("VK_USE_PLATFORM_WIN32_KHR", "1");
    @cInclude("vulkan/vulkan.h");
});

// Re-export common Vulkan constants for cleaner API
pub const VK_FORMAT_R32_SFLOAT = c.VK_FORMAT_R32_SFLOAT;
pub const VK_FORMAT_R32_UINT = c.VK_FORMAT_R32_UINT;
pub const VK_DESCRIPTOR_TYPE_STORAGE_IMAGE = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
pub const VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
pub const VK_SHADER_STAGE_COMPUTE_BIT = c.VK_SHADER_STAGE_COMPUTE_BIT;
pub const VK_SHADER_STAGE_FRAGMENT_BIT = c.VK_SHADER_STAGE_FRAGMENT_BIT;
pub const VK_SHADER_STAGE_VERTEX_BIT = c.VK_SHADER_STAGE_VERTEX_BIT;
pub const VK_IMAGE_LAYOUT_GENERAL = c.VK_IMAGE_LAYOUT_GENERAL;
pub const VK_IMAGE_LAYOUT_UNDEFINED = c.VK_IMAGE_LAYOUT_UNDEFINED;
pub const VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
pub const VK_PIPELINE_BIND_POINT_COMPUTE = c.VK_PIPELINE_BIND_POINT_COMPUTE;
pub const VK_PIPELINE_BIND_POINT_GRAPHICS = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
pub const VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT = c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
pub const VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
pub const VK_ACCESS_SHADER_WRITE_BIT = c.VK_ACCESS_SHADER_WRITE_BIT;
pub const VK_ACCESS_SHADER_READ_BIT = c.VK_ACCESS_SHADER_READ_BIT;

pub const WindowContext = struct {
    allocator: std.mem.Allocator,
    instance: c.VkInstance,
    surface: c.VkSurfaceKHR,
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
    queue_family_index: u32,
    queue: c.VkQueue,
    swapchain: c.VkSwapchainKHR,
    swapchain_images: []c.VkImage,
    swapchain_image_views: []c.VkImageView,
    render_pass: c.VkRenderPass,
    framebuffers: []c.VkFramebuffer,
    command_pool: c.VkCommandPool,
    command_buffers: []c.VkCommandBuffer,

    // Sync objects (single set, wait on fence between frames)
    image_available_semaphore: c.VkSemaphore,
    render_finished_semaphore: c.VkSemaphore,
    in_flight_fence: c.VkFence,
    images_in_flight: []?c.VkFence,

    // Win32 handles
    h_instance: os.HINSTANCE,
    hwnd: os.HWND,

    current_frame: usize = 0,
    current_image_index: u32 = 0,
    MAX_FRAMES_IN_FLIGHT: usize = 2,
    width: u32,
    height: u32,

    // Input state
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_left: bool = false,
    mouse_right: bool = false,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, title: [*:0]const u8) !WindowContext {
        // 1. Create Win32 Window
        const h_instance = @as(os.HINSTANCE, @ptrCast(os.kernel32.GetModuleHandleW(null)));
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigVulkanWindowClass");

        const wnd_class = WNDCLASSEXW{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = h_instance,
            .hIcon = null,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };

        _ = RegisterClassExW(&wnd_class);

        const title_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, std.mem.span(title));
        defer allocator.free(title_w);

        const hwnd = CreateWindowExW(
            0,
            class_name,
            title_w,
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            @intCast(width),
            @intCast(height),
            null,
            null,
            h_instance,
            null,
        ) orelse return error.WindowCreationFailed;

        // 2. Create Vulkan Instance
        const appInfo = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = title,
            .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0),
            .pEngineName = "ZigVulkanWindow",
            .engineVersion = c.VK_MAKE_VERSION(1, 0, 0),
            .apiVersion = c.VK_API_VERSION_1_2,
        };

        const extensions = [_][*:0]const u8{
            "VK_KHR_surface",
            "VK_KHR_win32_surface",
        };

        const createInfo = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &appInfo,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = extensions.len,
            .ppEnabledExtensionNames = &extensions[0],
        };

        var instance: c.VkInstance = undefined;
        if (c.vkCreateInstance(&createInfo, null, &instance) != c.VK_SUCCESS) {
            return error.VulkanInstanceCreationFailed;
        }
        errdefer c.vkDestroyInstance(instance, null);

        var surface_create_info = c.VkWin32SurfaceCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .hinstance = null,
            .hwnd = null,
        };
        @as(*allowzero usize, @ptrCast(&surface_create_info.hinstance)).* = @intFromPtr(h_instance);
        @as(*allowzero usize, @ptrCast(&surface_create_info.hwnd)).* = @intFromPtr(hwnd);

        var surface: c.VkSurfaceKHR = undefined;
        if (c.vkCreateWin32SurfaceKHR(instance, &surface_create_info, null, &surface) != c.VK_SUCCESS) {
            return error.VulkanSurfaceCreationFailed;
        }
        errdefer c.vkDestroySurfaceKHR(instance, surface, null);

        // 4. Pick Physical Device and Queue Family
        var device_count: u32 = 0;
        _ = c.vkEnumeratePhysicalDevices(instance, &device_count, null);
        if (device_count == 0) return error.NoVulkanDevicesFound;

        const pdevs = try allocator.alloc(c.VkPhysicalDevice, device_count);
        defer allocator.free(pdevs);
        _ = c.vkEnumeratePhysicalDevices(instance, &device_count, pdevs.ptr);

        var picked_pdev: c.VkPhysicalDevice = null;
        var picked_qfi: u32 = 0;

        for (pdevs) |pdev| {
            var queue_count: u32 = 0;
            c.vkGetPhysicalDeviceQueueFamilyProperties(pdev, &queue_count, null);
            const queue_props = try allocator.alloc(c.VkQueueFamilyProperties, queue_count);
            defer allocator.free(queue_props);
            c.vkGetPhysicalDeviceQueueFamilyProperties(pdev, &queue_count, queue_props.ptr);

            for (queue_props, 0..) |props, i| {
                if ((props.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0) {
                    var present_support: c.VkBool32 = c.VK_FALSE;
                    _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(pdev, @intCast(i), surface, &present_support);
                    if (present_support == c.VK_TRUE) {
                        picked_pdev = pdev;
                        picked_qfi = @intCast(i);

                        break;
                    }
                }
            }
            if (picked_pdev != null) break;
        }

        if (picked_pdev == null) return error.NoSuitableDeviceFound;

        // 5. Create Logical Device
        const queue_priority = @as(f32, 1.0);
        const queue_create_info = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = picked_qfi,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};

        var features = std.mem.zeroInit(c.VkPhysicalDeviceFeatures, .{});
        features.fragmentStoresAndAtomics = c.VK_TRUE;

        const device_create_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = &device_extensions[0],
            .pEnabledFeatures = &features,
        };

        var device: c.VkDevice = undefined;
        if (c.vkCreateDevice(picked_pdev, &device_create_info, null, &device) != c.VK_SUCCESS) {
            return error.VulkanDeviceCreationFailed;
        }
        errdefer c.vkDestroyDevice(device, null);

        var queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(device, picked_qfi, 0, &queue);

        // 6. Create Swapchain
        var caps: c.VkSurfaceCapabilitiesKHR = undefined;
        _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(picked_pdev, surface, &caps);

        var format_count: u32 = 0;
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(picked_pdev, surface, &format_count, null);
        const formats = try allocator.alloc(c.VkSurfaceFormatKHR, format_count);
        defer allocator.free(formats);
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(picked_pdev, surface, &format_count, formats.ptr);

        var chosen_format = formats[0];
        for (formats) |fmt| {
            if (fmt.format == c.VK_FORMAT_B8G8R8A8_SRGB and fmt.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                chosen_format = fmt;
                break;
            }
        }

        var present_mode_count: u32 = 0;
        _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(picked_pdev, surface, &present_mode_count, null);
        const present_modes = try allocator.alloc(c.VkPresentModeKHR, present_mode_count);
        defer allocator.free(present_modes);
        _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(picked_pdev, surface, &present_mode_count, present_modes.ptr);

        var chosen_present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_IMMEDIATE_KHR;
        for (present_modes) |mode| {
            if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                chosen_present_mode = mode;
                break;
            }
        }

        var extent = caps.currentExtent;
        if (extent.width == 0xFFFFFFFF) {
            extent.width = @max(caps.minImageExtent.width, @min(caps.maxImageExtent.width, width));
            extent.height = @max(caps.minImageExtent.height, @min(caps.maxImageExtent.height, height));
        }

        var image_count = caps.minImageCount + 1;
        if (caps.maxImageCount > 0 and image_count > caps.maxImageCount) {
            image_count = caps.maxImageCount;
        }

        const swapchain_create_info = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = surface,
            .minImageCount = image_count,
            .imageFormat = chosen_format.format,
            .imageColorSpace = chosen_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = caps.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = chosen_present_mode,
            .clipped = c.VK_TRUE,
            .oldSwapchain = null,
        };

        var swapchain: c.VkSwapchainKHR = undefined;
        if (c.vkCreateSwapchainKHR(device, &swapchain_create_info, null, &swapchain) != c.VK_SUCCESS) {
            return error.VulkanSwapchainCreationFailed;
        }
        errdefer c.vkDestroySwapchainKHR(device, swapchain, null);

        // Get Images
        _ = c.vkGetSwapchainImagesKHR(device, swapchain, &image_count, null);
        const swapchain_images = try allocator.alloc(c.VkImage, image_count);
        errdefer allocator.free(swapchain_images);

        _ = c.vkGetSwapchainImagesKHR(device, swapchain, &image_count, swapchain_images.ptr);

        // Create Image Views
        const swapchain_image_views = try allocator.alloc(c.VkImageView, image_count);
        errdefer allocator.free(swapchain_image_views); // Cleanup memory if fail, but views need destroy

        for (swapchain_images, 0..) |img, i| {
            const view_info = c.VkImageViewCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = img,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = chosen_format.format,
                .components = c.VkComponentMapping{ .r = c.VK_COMPONENT_SWIZZLE_IDENTITY, .g = c.VK_COMPONENT_SWIZZLE_IDENTITY, .b = c.VK_COMPONENT_SWIZZLE_IDENTITY, .a = c.VK_COMPONENT_SWIZZLE_IDENTITY },
                .subresourceRange = c.VkImageSubresourceRange{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };
            if (c.vkCreateImageView(device, &view_info, null, &swapchain_image_views[i]) != c.VK_SUCCESS) {
                return error.VulkanImageViewCreationFailed;
            }
        }
        errdefer {
            for (swapchain_image_views) |view| c.vkDestroyImageView(device, view, null);
        }

        // 7. Create Render Pass
        const color_attachment = c.VkAttachmentDescription{
            .flags = 0,
            .format = chosen_format.format,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };

        const color_attachment_ref = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const subpass = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };

        const dependency = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };

        const render_pass_info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 1,
            .pAttachments = &color_attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };

        var render_pass: c.VkRenderPass = undefined;
        if (c.vkCreateRenderPass(device, &render_pass_info, null, &render_pass) != c.VK_SUCCESS) {
            return error.VulkanRenderPassCreationFailed;
        }
        errdefer c.vkDestroyRenderPass(device, render_pass, null);

        // 8. Create Framebuffers
        const framebuffers = try allocator.alloc(c.VkFramebuffer, image_count);
        errdefer allocator.free(framebuffers);

        for (swapchain_image_views, 0..) |view, i| {
            const attachments = [_]c.VkImageView{view};
            const framebuffer_info = c.VkFramebufferCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .renderPass = render_pass,
                .attachmentCount = 1,
                .pAttachments = &attachments,
                .width = extent.width,
                .height = extent.height,
                .layers = 1,
            };
            if (c.vkCreateFramebuffer(device, &framebuffer_info, null, &framebuffers[i]) != c.VK_SUCCESS) {
                return error.VulkanFramebufferCreationFailed;
            }
        }
        errdefer {
            for (framebuffers) |fb| c.vkDestroyFramebuffer(device, fb, null);
        }

        // 9. Create Command Pool
        const pool_info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = picked_qfi,
        };

        var command_pool: c.VkCommandPool = undefined;
        if (c.vkCreateCommandPool(device, &pool_info, null, &command_pool) != c.VK_SUCCESS) {
            return error.VulkanCommandPoolCreationFailed;
        }
        errdefer c.vkDestroyCommandPool(device, command_pool, null);

        // 10. Allocate Command Buffers
        const MAX_FRAMES_IN_FLIGHT = 2;
        const command_buffers = try allocator.alloc(c.VkCommandBuffer, MAX_FRAMES_IN_FLIGHT);
        errdefer allocator.free(command_buffers);

        const alloc_info = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = MAX_FRAMES_IN_FLIGHT,
        };

        if (c.vkAllocateCommandBuffers(device, &alloc_info, command_buffers.ptr) != c.VK_SUCCESS) {
            return error.VulkanCommandBufferAllocationFailed;
        }

        // 11. Create Sync Objects (single set)
        const semaphore_info = c.VkSemaphoreCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };

        const fence_info = c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        var image_available_semaphore: c.VkSemaphore = undefined;
        var render_finished_semaphore: c.VkSemaphore = undefined;
        var in_flight_fence: c.VkFence = undefined;

        if (c.vkCreateSemaphore(device, &semaphore_info, null, &image_available_semaphore) != c.VK_SUCCESS or
            c.vkCreateSemaphore(device, &semaphore_info, null, &render_finished_semaphore) != c.VK_SUCCESS or
            c.vkCreateFence(device, &fence_info, null, &in_flight_fence) != c.VK_SUCCESS)
        {
            return error.VulkanSyncObjectCreationFailed;
        }

        return WindowContext{
            .allocator = allocator,
            .instance = instance,
            .surface = surface,
            .physical_device = picked_pdev,
            .device = device,
            .queue_family_index = picked_qfi,
            .queue = queue,
            .swapchain = swapchain,
            .swapchain_images = swapchain_images,
            .swapchain_image_views = swapchain_image_views,
            .render_pass = render_pass,
            .framebuffers = framebuffers,
            .command_pool = command_pool,
            .command_buffers = command_buffers,
            .image_available_semaphore = image_available_semaphore,
            .render_finished_semaphore = render_finished_semaphore,
            .in_flight_fence = in_flight_fence,
            .images_in_flight = undefined,
            .h_instance = h_instance,
            .hwnd = hwnd,
            .width = extent.width,
            .height = extent.height,
        };
    }

    pub fn deinit(self: *WindowContext) void {
        if (self.device) |device| {
            _ = c.vkDeviceWaitIdle(device);

            c.vkDestroyFence(device, self.in_flight_fence, null);
            c.vkDestroySemaphore(device, self.render_finished_semaphore, null);
            c.vkDestroySemaphore(device, self.image_available_semaphore, null);

            if (self.command_pool) |pool| c.vkDestroyCommandPool(device, pool, null);
            if (self.command_buffers.len > 0) self.allocator.free(self.command_buffers);

            for (self.framebuffers) |fb| c.vkDestroyFramebuffer(device, fb, null);
            if (self.framebuffers.len > 0) self.allocator.free(self.framebuffers);

            if (self.render_pass) |rp| c.vkDestroyRenderPass(device, rp, null);

            for (self.swapchain_image_views) |view| {
                c.vkDestroyImageView(device, view, null);
            }
            if (self.swapchain_images.len > 0) self.allocator.free(self.swapchain_images);
            if (self.swapchain_image_views.len > 0) self.allocator.free(self.swapchain_image_views);

            if (self.swapchain) |swapchain| {
                c.vkDestroySwapchainKHR(device, swapchain, null);
            }

            c.vkDestroyDevice(device, null);
        }

        if (self.instance) |instance| {
            if (self.surface) |surface| {
                c.vkDestroySurfaceKHR(instance, surface, null);
            }
            c.vkDestroyInstance(instance, null);
        }

        _ = DestroyWindow(self.hwnd);
    }

    pub fn update(self: *WindowContext) bool {
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            if (msg.message == WM_QUIT) {
                return false;
            }

            switch (msg.message) {
                WM_MOUSEMOVE => {
                    const lp = @as(usize, @bitCast(msg.lParam));
                    self.mouse_x = @as(i16, @bitCast(@as(u16, @truncate(lp))));
                    self.mouse_y = @as(i16, @bitCast(@as(u16, @truncate(lp >> 16))));
                },
                WM_LBUTTONDOWN => self.mouse_left = true,
                WM_LBUTTONUP => self.mouse_left = false,
                WM_RBUTTONDOWN => self.mouse_right = true,
                WM_RBUTTONUP => self.mouse_right = false,
                else => {},
            }

            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        return true;
    }

    pub fn beginFrame(self: *WindowContext) !c.VkCommandBuffer {
        // Wait for the fence from previous frame
        _ = c.vkWaitForFences(self.device, 1, &self.in_flight_fence, c.VK_TRUE, std.math.maxInt(u64));
        _ = c.vkResetFences(self.device, 1, &self.in_flight_fence);

        var image_index: u32 = 0;
        const result = c.vkAcquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.image_available_semaphore, null, &image_index);

        if (result == c.VK_ERROR_OUT_OF_DATE_KHR) {
            return error.SwapchainOutOfDate;
        } else if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) {
            return error.VulkanAcquireImageFailed;
        }

        self.current_image_index = image_index;

        const cmdbuf = self.command_buffers[self.current_frame];

        _ = c.vkResetCommandBuffer(cmdbuf, 0);

        const begin_info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };

        if (c.vkBeginCommandBuffer(cmdbuf, &begin_info) != c.VK_SUCCESS) {
            return error.VulkanBeginCommandBufferFailed;
        }

        return cmdbuf;
    }

    pub fn beginRenderPass(self: *WindowContext, cmdbuf: c.VkCommandBuffer) void {
        const clear_color = c.VkClearValue{ .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } } };

        const render_pass_begin_info = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers[self.current_image_index],
            .renderArea = c.VkRect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = self.width, .height = self.height },
            },
            .clearValueCount = 1,
            .pClearValues = &clear_color,
        };

        c.vkCmdBeginRenderPass(cmdbuf, &render_pass_begin_info, c.VK_SUBPASS_CONTENTS_INLINE);

        const viewport = c.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.width),
            .height = @floatFromInt(self.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        c.vkCmdSetViewport(cmdbuf, 0, 1, &viewport);

        const scissor = c.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = self.width, .height = self.height },
        };
        c.vkCmdSetScissor(cmdbuf, 0, 1, &scissor);
    }

    pub fn endRenderPass(self: *WindowContext, cmdbuf: c.VkCommandBuffer) void {
        _ = self;
        c.vkCmdEndRenderPass(cmdbuf);
    }

    pub fn endFrame(self: *WindowContext) !void {
        const cmdbuf = self.command_buffers[self.current_frame];

        if (c.vkEndCommandBuffer(cmdbuf) != c.VK_SUCCESS) {
            return error.VulkanEndCommandBufferFailed;
        }

        const wait_stages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.image_available_semaphore,
            .pWaitDstStageMask = &wait_stages[0],
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffers[self.current_frame],
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &self.render_finished_semaphore,
        };

        const res = c.vkQueueSubmit(self.queue, 1, &submit_info, self.in_flight_fence);
        if (res != c.VK_SUCCESS) {
            return error.VulkanQueueSubmitFailed;
        }

        const present_info = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.render_finished_semaphore,
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &self.current_image_index,
            .pResults = null,
        };

        _ = c.vkQueuePresentKHR(self.queue, &present_info);
        _ = c.vkQueueWaitIdle(self.queue);

        self.current_frame = (self.current_frame + 1) % self.MAX_FRAMES_IN_FLIGHT;
    }

    pub fn createSimpleGraphicsPipeline(self: *WindowContext, vert_code: []const u8, frag_code: []const u8, vert_entry: [*:0]const u8, frag_entry: [*:0]const u8, layouts: []const c.VkDescriptorSetLayout) !SimplePipeline {
        // Create shader modules
        var vert_module: c.VkShaderModule = undefined;
        var frag_module: c.VkShaderModule = undefined;

        const vert_info = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = vert_code.len,
            .pCode = @ptrCast(@alignCast(vert_code.ptr)),
        };
        if (c.vkCreateShaderModule(self.device, &vert_info, null, &vert_module) != c.VK_SUCCESS) return error.VulkanShaderModuleCreationFailed;
        defer c.vkDestroyShaderModule(self.device, vert_module, null);

        const frag_info = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = frag_code.len,
            .pCode = @ptrCast(@alignCast(frag_code.ptr)),
        };
        if (c.vkCreateShaderModule(self.device, &frag_info, null, &frag_module) != c.VK_SUCCESS) return error.VulkanShaderModuleCreationFailed;
        defer c.vkDestroyShaderModule(self.device, frag_module, null);

        // Stages
        const vert_stage = c.VkPipelineShaderStageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vert_module,
            .pName = vert_entry,
            .pSpecializationInfo = null,
        };
        const frag_stage = c.VkPipelineShaderStageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = frag_module,
            .pName = frag_entry,
            .pSpecializationInfo = null,
        };
        const stages = [_]c.VkPipelineShaderStageCreateInfo{ vert_stage, frag_stage };

        // Defaults
        const vertex_input = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };
        const input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = c.VK_FALSE,
        };
        const viewport = c.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.width),
            .height = @floatFromInt(self.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        const scissor = c.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = self.width, .height = self.height },
        };
        const viewport_state = c.VkPipelineViewportStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = &viewport,
            .scissorCount = 1,
            .pScissors = &scissor,
        };
        const rasterizer = c.VkPipelineRasterizationStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = c.VK_FALSE,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .lineWidth = 1.0,
            .cullMode = c.VK_CULL_MODE_BACK_BIT,
            .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = c.VK_FALSE,
            .depthBiasConstantFactor = 0.0,
            .depthBiasClamp = 0.0,
            .depthBiasSlopeFactor = 0.0,
        };
        const multisampling = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .sampleShadingEnable = c.VK_FALSE,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = c.VK_FALSE,
            .alphaToOneEnable = c.VK_FALSE,
        };
        const color_blend_attachment = c.VkPipelineColorBlendAttachmentState{
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
            .blendEnable = c.VK_FALSE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
        };
        const color_blending = c.VkPipelineColorBlendStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic_state = c.VkPipelineDynamicStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = 2,
            .pDynamicStates = &dynamic_states[0],
        };

        const pipeline_layout_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = @intCast(layouts.len),
            .pSetLayouts = if (layouts.len > 0) layouts.ptr else null,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };
        var pipeline_layout: c.VkPipelineLayout = undefined;
        if (c.vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &pipeline_layout) != c.VK_SUCCESS) {
            return error.VulkanPipelineLayoutCreationFailed;
        }
        errdefer c.vkDestroyPipelineLayout(self.device, pipeline_layout, null);

        const pipeline_info = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = 2,
            .pStages = &stages[0],
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = null,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state,
            .layout = pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };
        var pipeline: c.VkPipeline = undefined;
        if (c.vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &pipeline) != c.VK_SUCCESS) {
            return error.VulkanPipelineCreationFailed;
        }

        return SimplePipeline{
            .pipeline = pipeline,
            .layout = pipeline_layout,
        };
    }

    pub fn findMemoryType(self: *WindowContext, typeFilter: u32, properties: c.VkMemoryPropertyFlags) u32 {
        var memProperties: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &memProperties);

        var i: u32 = 0;
        while (i < memProperties.memoryTypeCount) : (i += 1) {
            if ((typeFilter & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0 and (memProperties.memoryTypes[i].propertyFlags & properties) == properties) {
                return i;
            }
        }
        std.debug.panic("Could not find suitable memory type!", .{});
    }

    pub fn createBuffer(self: *WindowContext, size: u64, usage: c.VkBufferUsageFlags, properties: c.VkMemoryPropertyFlags) !Buffer {
        const bufferInfo = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        };

        var handle: c.VkBuffer = undefined;
        if (c.vkCreateBuffer(self.device, &bufferInfo, null, &handle) != c.VK_SUCCESS) return error.BufferCreationFailed;

        var memRequirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, handle, &memRequirements);

        const allocInfo = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = memRequirements.size,
            .memoryTypeIndex = self.findMemoryType(memRequirements.memoryTypeBits, properties),
        };

        var memory: c.VkDeviceMemory = undefined;
        if (c.vkAllocateMemory(self.device, &allocInfo, null, &memory) != c.VK_SUCCESS) return error.MemoryAllocationFailed;

        _ = c.vkBindBufferMemory(self.device, handle, memory, 0);

        return Buffer{
            .handle = handle,
            .memory = memory,
            .size = size,
        };
    }

    pub fn createStorageImage(self: *WindowContext, image_width: u32, image_height: u32, format: c.VkFormat) !StorageImage {
        const imageInfo = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .extent = .{ .width = image_width, .height = image_height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .format = format,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .usage = c.VK_IMAGE_USAGE_STORAGE_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .flags = 0,
        };

        var handle: c.VkImage = undefined;
        if (c.vkCreateImage(self.device, &imageInfo, null, &handle) != c.VK_SUCCESS) return error.ImageCreationFailed;

        var memRequirements: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device, handle, &memRequirements);

        const allocInfo = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = memRequirements.size,
            .memoryTypeIndex = self.findMemoryType(memRequirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        };

        var memory: c.VkDeviceMemory = undefined;
        if (c.vkAllocateMemory(self.device, &allocInfo, null, &memory) != c.VK_SUCCESS) return error.MemoryAllocationFailed;

        _ = c.vkBindImageMemory(self.device, handle, memory, 0);

        const viewInfo = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = handle,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        var view: c.VkImageView = undefined;
        if (c.vkCreateImageView(self.device, &viewInfo, null, &view) != c.VK_SUCCESS) return error.ImageViewCreationFailed;

        return StorageImage{
            .handle = handle,
            .memory = memory,
            .view = view,
            .width = image_width,
            .height = image_height,
            .format = format,
        };
    }

    pub fn createComputePipeline(self: *WindowContext, shader_code: []const u8, layout: c.VkPipelineLayout) !c.VkPipeline {
        var module: c.VkShaderModule = undefined;
        const info = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = shader_code.len,
            .pCode = @ptrCast(@alignCast(shader_code.ptr)),
        };
        if (c.vkCreateShaderModule(self.device, &info, null, &module) != c.VK_SUCCESS) return error.ShaderModuleCreationFailed;
        defer c.vkDestroyShaderModule(self.device, module, null);

        const stageInfo = c.VkPipelineShaderStageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = module,
            .pName = "main",
        };

        const pipelineInfo = c.VkComputePipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .stage = stageInfo,
            .layout = layout,
        };

        var pipeline: c.VkPipeline = undefined;
        if (c.vkCreateComputePipelines(self.device, null, 1, &pipelineInfo, null, &pipeline) != c.VK_SUCCESS) return error.PipelineCreationFailed;
        return pipeline;
    }

    pub fn createDescriptorSetLayout(self: *WindowContext, bindings: []const c.VkDescriptorSetLayoutBinding) !c.VkDescriptorSetLayout {
        const layoutInfo = c.VkDescriptorSetLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = @intCast(bindings.len),
            .pBindings = bindings.ptr,
        };
        var layout: c.VkDescriptorSetLayout = undefined;
        if (c.vkCreateDescriptorSetLayout(self.device, &layoutInfo, null, &layout) != c.VK_SUCCESS) return error.DescriptorSetLayoutCreationFailed;
        return layout;
    }

    pub fn allocateDescriptorSet(self: *WindowContext, pool: c.VkDescriptorPool, layout: c.VkDescriptorSetLayout) !c.VkDescriptorSet {
        const allocInfo = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &layout,
        };
        var set: c.VkDescriptorSet = undefined;
        if (c.vkAllocateDescriptorSets(self.device, &allocInfo, &set) != c.VK_SUCCESS) return error.DescriptorSetAllocationFailed;
        return set;
    }

    pub fn createDescriptorPool(self: *WindowContext, sizes: []const c.VkDescriptorPoolSize, maxSets: u32) !c.VkDescriptorPool {
        const poolInfo = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .poolSizeCount = @intCast(sizes.len),
            .pPoolSizes = sizes.ptr,
            .maxSets = maxSets,
        };
        var pool: c.VkDescriptorPool = undefined;
        if (c.vkCreateDescriptorPool(self.device, &poolInfo, null, &pool) != c.VK_SUCCESS) return error.DescriptorPoolCreationFailed;
        return pool;
    }

    pub fn updateDescriptorSetImage(self: *WindowContext, set: c.VkDescriptorSet, binding: u32, view: c.VkImageView, layout: c.VkImageLayout, descriptorType: c.VkDescriptorType) void {
        const imageInfo = c.VkDescriptorImageInfo{
            .imageLayout = layout,
            .imageView = view,
            .sampler = null,
        };

        const write = c.VkWriteDescriptorSet{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = set,
            .dstBinding = binding,
            .descriptorCount = 1,
            .descriptorType = descriptorType,
            .pImageInfo = &imageInfo,
        };

        c.vkUpdateDescriptorSets(self.device, 1, &write, 0, null);
    }

    pub fn bindDescriptorSet(self: *WindowContext, cmdbuf: c.VkCommandBuffer, bindPoint: c.VkPipelineBindPoint, layout: c.VkPipelineLayout, set: c.VkDescriptorSet) void {
        _ = self;
        c.vkCmdBindDescriptorSets(cmdbuf, bindPoint, layout, 0, 1, &set, 0, null);
    }

    pub fn dispatchCompute(self: *WindowContext, cmdbuf: c.VkCommandBuffer, x: u32, y: u32, z: u32) void {
        _ = self;
        c.vkCmdDispatch(cmdbuf, x, y, z);
    }

    pub fn pushConstants(self: *WindowContext, cmdbuf: c.VkCommandBuffer, layout: c.VkPipelineLayout, stage: c.VkShaderStageFlags, offset: u32, size: u32, ptr: ?*const anyopaque) void {
        _ = self;
        c.vkCmdPushConstants(cmdbuf, layout, stage, offset, size, ptr);
    }

    pub fn transitionImageLayout(self: *WindowContext, cmdbuf: c.VkCommandBuffer, image: c.VkImage, oldLayout: c.VkImageLayout, newLayout: c.VkImageLayout) void {
        _ = self;
        var barrier = c.VkImageMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = oldLayout,
            .newLayout = newLayout,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcAccessMask = 0,
            .dstAccessMask = 0,
        };

        var sourceStage: c.VkPipelineStageFlags = 0;
        var destinationStage: c.VkPipelineStageFlags = 0;

        if (oldLayout == c.VK_IMAGE_LAYOUT_UNDEFINED and newLayout == c.VK_IMAGE_LAYOUT_GENERAL) {
            barrier.srcAccessMask = 0;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT;
            sourceStage = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
            destinationStage = c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
        } else if (oldLayout == c.VK_IMAGE_LAYOUT_GENERAL and newLayout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
            barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            sourceStage = c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
            destinationStage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        } else if (oldLayout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL and newLayout == c.VK_IMAGE_LAYOUT_GENERAL) {
            barrier.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
            sourceStage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
            destinationStage = c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
        } else {
            // Generic fallback
            sourceStage = c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            destinationStage = c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
        }

        c.vkCmdPipelineBarrier(cmdbuf, sourceStage, destinationStage, 0, 0, null, 0, null, 1, &barrier);
    }

    // Resource destruction helpers
    pub fn destroyDescriptorPool(self: *WindowContext, pool: c.VkDescriptorPool) void {
        c.vkDestroyDescriptorPool(self.device, pool, null);
    }

    pub fn destroyDescriptorSetLayout(self: *WindowContext, layout: c.VkDescriptorSetLayout) void {
        c.vkDestroyDescriptorSetLayout(self.device, layout, null);
    }

    pub fn destroyPipelineLayout(self: *WindowContext, layout: c.VkPipelineLayout) void {
        c.vkDestroyPipelineLayout(self.device, layout, null);
    }

    pub fn destroyPipeline(self: *WindowContext, pipeline: c.VkPipeline) void {
        c.vkDestroyPipeline(self.device, pipeline, null);
    }

    // Pipeline layout creation helper
    pub fn createPipelineLayout(self: *WindowContext, dsl: c.VkDescriptorSetLayout, push_constant_size: u32, stage_flags: c.VkShaderStageFlags) !c.VkPipelineLayout {
        const pc_range = c.VkPushConstantRange{
            .stageFlags = stage_flags,
            .offset = 0,
            .size = push_constant_size,
        };

        const has_pc = push_constant_size > 0;
        const layout_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = &dsl,
            .pushConstantRangeCount = if (has_pc) 1 else 0,
            .pPushConstantRanges = if (has_pc) &pc_range else null,
        };

        var layout: c.VkPipelineLayout = undefined;
        if (c.vkCreatePipelineLayout(self.device, &layout_info, null, &layout) != c.VK_SUCCESS) {
            return error.PipelineLayoutCreationFailed;
        }
        return layout;
    }

    // Command recording helpers
    pub fn bindComputePipeline(self: *WindowContext, cmdbuf: c.VkCommandBuffer, pipeline: c.VkPipeline) void {
        _ = self;
        c.vkCmdBindPipeline(cmdbuf, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    }

    pub fn bindGraphicsPipeline(self: *WindowContext, cmdbuf: c.VkCommandBuffer, pipeline: c.VkPipeline) void {
        _ = self;
        c.vkCmdBindPipeline(cmdbuf, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    }

    pub fn draw(self: *WindowContext, cmdbuf: c.VkCommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        _ = self;
        c.vkCmdDraw(cmdbuf, vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn clearImage(self: *WindowContext, cmdbuf: c.VkCommandBuffer, image: c.VkImage, layout: c.VkImageLayout, r: f32, g: f32, b: f32, a: f32) void {
        _ = self;
        const clearColor = c.VkClearColorValue{ .float32 = .{ r, g, b, a } };
        const range = c.VkImageSubresourceRange{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        c.vkCmdClearColorImage(cmdbuf, image, layout, &clearColor, 1, &range);
    }

    pub fn memoryBarrier(self: *WindowContext, cmdbuf: c.VkCommandBuffer, src_stage: c.VkPipelineStageFlags, dst_stage: c.VkPipelineStageFlags, src_access: c.VkAccessFlags, dst_access: c.VkAccessFlags) void {
        _ = self;
        var barrier = c.VkMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = src_access,
            .dstAccessMask = dst_access,
        };
        c.vkCmdPipelineBarrier(cmdbuf, src_stage, dst_stage, 0, 1, &barrier, 0, null, 0, null);
    }

    pub fn waitIdle(self: *WindowContext) void {
        _ = c.vkDeviceWaitIdle(self.device);
    }
};

pub const StorageImage = struct {
    handle: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    width: u32,
    height: u32,
    format: c.VkFormat,

    pub fn destroy(self: StorageImage, device: c.VkDevice) void {
        c.vkDestroyImageView(device, self.view, null);
        c.vkDestroyImage(device, self.handle, null);
        c.vkFreeMemory(device, self.memory, null);
    }
};

pub const Buffer = struct {
    handle: c.VkBuffer,
    memory: c.VkDeviceMemory,
    size: u64,

    pub fn destroy(self: Buffer, device: c.VkDevice) void {
        c.vkDestroyBuffer(device, self.handle, null);
        c.vkFreeMemory(device, self.memory, null);
    }
};

pub const SimplePipeline = struct {
    pipeline: c.VkPipeline,
    layout: c.VkPipelineLayout,

    pub fn destroy(self: SimplePipeline, device: c.VkDevice) void {
        c.vkDestroyPipeline(device, self.pipeline, null);
        c.vkDestroyPipelineLayout(device, self.layout, null);
    }
};

// Define Win32 imports we need if not in std
extern "user32" fn DefWindowProcW(hWnd: os.HWND, Msg: os.UINT, wParam: os.WPARAM, lParam: os.LPARAM) callconv(WINAPI) os.LRESULT;
extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(WINAPI) os.ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: os.DWORD,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: os.DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?os.HWND,
    hMenu: ?os.HMENU,
    hInstance: ?os.HINSTANCE,
    lpParam: ?os.LPVOID,
) callconv(WINAPI) ?os.HWND;
extern "user32" fn ShowWindow(hWnd: os.HWND, nCmdShow: i32) callconv(WINAPI) os.BOOL;
extern "user32" fn DestroyWindow(hWnd: os.HWND) callconv(WINAPI) os.BOOL;
extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?os.HWND, wMsgFilterMin: os.UINT, wMsgFilterMax: os.UINT, wRemoveMsg: os.UINT) callconv(WINAPI) os.BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(WINAPI) os.BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(WINAPI) os.LRESULT;
extern "user32" fn LoadCursorW(hInstance: ?os.HINSTANCE, lpCursorName: ?[*:0]const u16) callconv(WINAPI) ?os.HCURSOR;
extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(WINAPI) void;

pub const WNDCLASSEXW = extern struct {
    cbSize: os.UINT,
    style: os.UINT,
    lpfnWndProc: *const fn (os.HWND, os.UINT, os.WPARAM, os.LPARAM) callconv(WINAPI) os.LRESULT,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?os.HINSTANCE,
    hIcon: ?os.HICON,
    hCursor: ?os.HCURSOR,
    hbrBackground: ?os.HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?os.HICON,
};

pub const MSG = extern struct {
    hwnd: ?os.HWND,
    message: os.UINT,
    wParam: os.WPARAM,
    lParam: os.LPARAM,
    time: os.DWORD,
    pt: POINT,
    lPrivate: os.DWORD,
};

pub const POINT = extern struct {
    x: os.LONG,
    y: os.LONG,
};

pub const PM_REMOVE = 0x0001;
pub const WM_QUIT = 0x0012;
pub const WS_OVERLAPPEDWINDOW = 0x00CF0000;
pub const WS_VISIBLE = 0x10000000;
pub const CW_USEDEFAULT = @as(i32, -2147483648); // 0x80000000 interpreted as i32
pub const SW_SHOW = 5;
pub const IDC_ARROW: [*:0]const u16 = @ptrFromInt(32512);

pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;

fn wndProc(hWnd: os.HWND, msg: os.UINT, wParam: os.WPARAM, lParam: os.LPARAM) callconv(WINAPI) os.LRESULT {
    switch (msg) {
        0x0002 => { // WM_DESTROY
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hWnd, msg, wParam, lParam),
    }
}
