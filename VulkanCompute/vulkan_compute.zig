const std = @import("std");

pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

pub const Context = struct {
    allocator: std.mem.Allocator,
    instance: c.VkInstance,
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
    queue_family_index: u32,
    queue: c.VkQueue,
    command_pool: c.VkCommandPool,

    pub fn init(allocator: std.mem.Allocator, app_name: [*:0]const u8) !Context {
        // 1. Create Instance
        const appInfo = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = app_name,
            .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0),
            .pEngineName = "No Engine",
            .engineVersion = c.VK_MAKE_VERSION(1, 0, 0),
            .apiVersion = c.VK_API_VERSION_1_2,
            .pNext = null,
        };

        const createInfo = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &appInfo,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
            .pNext = null,
            .flags = 0,
        };

        var instance: c.VkInstance = undefined;
        if (c.vkCreateInstance(&createInfo, null, &instance) != c.VK_SUCCESS) {
            return error.VulkanInstanceCreationFailed;
        }
        errdefer c.vkDestroyInstance(instance, null);

        // 2. Select Physical Device
        var deviceCount: u32 = 0;
        _ = c.vkEnumeratePhysicalDevices(instance, &deviceCount, null);
        if (deviceCount == 0) return error.NoVulkanDevices;

        const pDevices = try allocator.alloc(c.VkPhysicalDevice, deviceCount);
        defer allocator.free(pDevices);
        _ = c.vkEnumeratePhysicalDevices(instance, &deviceCount, pDevices.ptr);

        // Simple selection: pick first
        const physical_device = pDevices[0];

        // 3. Find Compute Queue
        var queueFamilyCount: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queueFamilyCount, null);
        const queueProps = try allocator.alloc(c.VkQueueFamilyProperties, queueFamilyCount);
        defer allocator.free(queueProps);
        c.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queueFamilyCount, queueProps.ptr);

        var computeFamilyIndex: ?u32 = null;
        for (queueProps, 0..) |prop, i| {
            if ((prop.queueFlags & c.VK_QUEUE_COMPUTE_BIT) != 0) {
                computeFamilyIndex = @intCast(i);
                break;
            }
        }
        if (computeFamilyIndex == null) return error.NoComputeQueue;
        const q_family_index = computeFamilyIndex.?;

        // 4. Create Logical Device
        const queuePriority: f32 = 1.0;
        const queueCreateInfo = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = q_family_index,
            .queueCount = 1,
            .pQueuePriorities = &queuePriority,
            .pNext = null,
            .flags = 0,
        };

        const deviceCreateInfo = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pQueueCreateInfos = &queueCreateInfo,
            .queueCreateInfoCount = 1,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .pEnabledFeatures = null,
            .pNext = null,
            .flags = 0,
        };

        var device: c.VkDevice = undefined;
        if (c.vkCreateDevice(physical_device, &deviceCreateInfo, null, &device) != c.VK_SUCCESS) {
            return error.DeviceCreationFailed;
        }
        errdefer c.vkDestroyDevice(device, null);

        var queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(device, q_family_index, 0, &queue);

        // 5. Create Command Pool
        const cmdPoolInfo = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = q_family_index,
            .flags = 0, // We could use VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT if needed
            .pNext = null,
        };

        var command_pool: c.VkCommandPool = undefined;
        if (c.vkCreateCommandPool(device, &cmdPoolInfo, null, &command_pool) != c.VK_SUCCESS) {
            return error.CommandPoolCreationFailed;
        }

        return Context{
            .allocator = allocator,
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .queue_family_index = q_family_index,
            .queue = queue,
            .command_pool = command_pool,
        };
    }

    pub fn deinit(self: Context) void {
        c.vkDestroyCommandPool(self.device, self.command_pool, null);
        c.vkDestroyDevice(self.device, null);
        c.vkDestroyInstance(self.instance, null);
    }

    pub fn createBuffer(self: Context, size: u64, usage: c.VkBufferUsageFlags) !Buffer {
        const bufferCreateInfo = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        var vk_buffer: c.VkBuffer = undefined;
        if (c.vkCreateBuffer(self.device, &bufferCreateInfo, null, &vk_buffer) != c.VK_SUCCESS) {
            return error.BufferCreationFailed;
        }
        errdefer c.vkDestroyBuffer(self.device, vk_buffer, null);

        // Memory
        var memReqs: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, vk_buffer, &memReqs);

        var memProps: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &memProps);

        const requiredProps = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        var memoryTypeIndex: ?u32 = null;
        var i: u32 = 0;
        while (i < memProps.memoryTypeCount) : (i += 1) {
            if ((memReqs.memoryTypeBits & (@as(u32, 1) << @intCast(i))) != 0 and
                (memProps.memoryTypes[i].propertyFlags & requiredProps) == requiredProps)
            {
                memoryTypeIndex = i;
                break;
            }
        }
        if (memoryTypeIndex == null) return error.NoSuitableMemoryFound;

        const allocInfo = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = memReqs.size,
            .memoryTypeIndex = memoryTypeIndex.?,
            .pNext = null,
        };

        var memory: c.VkDeviceMemory = undefined;
        if (c.vkAllocateMemory(self.device, &allocInfo, null, &memory) != c.VK_SUCCESS) {
            return error.MemoryAllocationFailed;
        }
        errdefer c.vkFreeMemory(self.device, memory, null);

        if (c.vkBindBufferMemory(self.device, vk_buffer, memory, 0) != c.VK_SUCCESS) {
            return error.BindBufferMemoryFailed;
        }

        return Buffer{
            .handle = vk_buffer,
            .memory = memory,
            .size = size,
        };
    }

    pub fn createSimpleComputePipeline(self: Context, spirv_code: []const u8) !SimplePipeline {
        const shaderModuleCreateInfo = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = spirv_code.len,
            .pCode = @ptrCast(@alignCast(spirv_code.ptr)),
            .pNext = null,
            .flags = 0,
        };

        var shaderModule: c.VkShaderModule = undefined;
        if (c.vkCreateShaderModule(self.device, &shaderModuleCreateInfo, null, &shaderModule) != c.VK_SUCCESS) {
            return error.ShaderModuleCreationFailed;
        }
        // defer c.vkDestroyShaderModule(self.device, shaderModule, null);
        // We can destroy it after pipeline creation, typically.

        const binding = c.VkDescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .pImmutableSamplers = null,
        };

        const descriptorLayoutInfo = c.VkDescriptorSetLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = 1,
            .pBindings = &binding,
            .pNext = null,
            .flags = 0,
        };

        var descriptorSetLayout: c.VkDescriptorSetLayout = undefined;
        if (c.vkCreateDescriptorSetLayout(self.device, &descriptorLayoutInfo, null, &descriptorSetLayout) != c.VK_SUCCESS) {
            return error.DescriptorSetLayoutCreationFailed;
        }
        errdefer c.vkDestroyDescriptorSetLayout(self.device, descriptorSetLayout, null);

        const pipelineLayoutInfo = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = &descriptorSetLayout,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
            .pNext = null,
            .flags = 0,
        };

        var pipelineLayout: c.VkPipelineLayout = undefined;
        if (c.vkCreatePipelineLayout(self.device, &pipelineLayoutInfo, null, &pipelineLayout) != c.VK_SUCCESS) {
            return error.PipelineLayoutCreationFailed;
        }
        errdefer c.vkDestroyPipelineLayout(self.device, pipelineLayout, null);

        const entryPointName = "main";
        const shaderStageInfo = c.VkPipelineShaderStageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = shaderModule,
            .pName = entryPointName,
            .pSpecializationInfo = null,
            .pNext = null,
            .flags = 0,
        };

        const pipelineInfo = c.VkComputePipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .stage = shaderStageInfo,
            .layout = pipelineLayout,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
            .pNext = null,
            .flags = 0,
        };

        var pipeline: c.VkPipeline = undefined;
        if (c.vkCreateComputePipelines(self.device, null, 1, &pipelineInfo, null, &pipeline) != c.VK_SUCCESS) {
            return error.PipelineCreationFailed;
        }

        c.vkDestroyShaderModule(self.device, shaderModule, null);

        return SimplePipeline{
            .handle = pipeline,
            .layout = pipelineLayout,
            .descriptor_set_layout = descriptorSetLayout,
        };
    }

    pub fn runSimple(self: Context, pipeline: SimplePipeline, buffer: Buffer, x: u32, y: u32, z: u32) !void {
        // Create Descriptor Pool / Set (Ephemeral for simplicity, or could be cached in pipeline)
        const poolSize = c.VkDescriptorPoolSize{
            .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
        };

        const descriptorPoolInfo = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .poolSizeCount = 1,
            .pPoolSizes = &poolSize,
            .maxSets = 1,
            .pNext = null,
            .flags = 0,
        };

        var descriptorPool: c.VkDescriptorPool = undefined;
        if (c.vkCreateDescriptorPool(self.device, &descriptorPoolInfo, null, &descriptorPool) != c.VK_SUCCESS) return error.DescriptorPoolCreationFailed;
        defer c.vkDestroyDescriptorPool(self.device, descriptorPool, null);

        const allocSetInfo = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = descriptorPool,
            .descriptorSetCount = 1,
            .pSetLayouts = &pipeline.descriptor_set_layout,
            .pNext = null,
        };

        var descriptorSet: c.VkDescriptorSet = undefined;
        if (c.vkAllocateDescriptorSets(self.device, &allocSetInfo, &descriptorSet) != c.VK_SUCCESS) return error.DescriptorSetAllocationFailed;

        const bufferInfo = c.VkDescriptorBufferInfo{
            .buffer = buffer.handle,
            .offset = 0,
            .range = buffer.size,
        };

        const writeDescriptorSet = c.VkWriteDescriptorSet{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptorSet,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .pBufferInfo = &bufferInfo,
            .pImageInfo = null,
            .pTexelBufferView = null,
            .pNext = null,
        };

        c.vkUpdateDescriptorSets(self.device, 1, &writeDescriptorSet, 0, null);

        // Command Buffer
        const cmdBufAllocInfo = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
            .pNext = null,
        };

        var commandBuffer: c.VkCommandBuffer = undefined;
        if (c.vkAllocateCommandBuffers(self.device, &cmdBufAllocInfo, &commandBuffer) != c.VK_SUCCESS) return error.CommandBufferAllocationFailed;

        // We should really free this command buffer, or use a cached one.
        // For this simple API, we'll try to just submit and wait.
        // But `vkFreeCommandBuffers` is good practice.

        const beginInfo = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pNext = null,
            .pInheritanceInfo = null,
        };

        _ = c.vkBeginCommandBuffer(commandBuffer, &beginInfo);
        c.vkCmdBindPipeline(commandBuffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline.handle);
        c.vkCmdBindDescriptorSets(commandBuffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline.layout, 0, 1, &descriptorSet, 0, null);
        c.vkCmdDispatch(commandBuffer, x, y, z);
        _ = c.vkEndCommandBuffer(commandBuffer);

        const submitInfo = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &commandBuffer,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
            .pNext = null,
        };

        if (c.vkQueueSubmit(self.queue, 1, &submitInfo, null) != c.VK_SUCCESS) return error.QueueSubmitFailed;
        _ = c.vkQueueWaitIdle(self.queue);

        c.vkFreeCommandBuffers(self.device, self.command_pool, 1, &commandBuffer);
    }
};

pub const Buffer = struct {
    handle: c.VkBuffer,
    memory: c.VkDeviceMemory,
    size: u64,

    pub fn destroy(self: Buffer, ctx: Context) void {
        c.vkDestroyBuffer(ctx.device, self.handle, null);
        c.vkFreeMemory(ctx.device, self.memory, null);
    }

    pub fn map(self: Buffer, ctx: Context, comptime T: type) ![]T {
        var data: [*]T = undefined;
        if (c.vkMapMemory(ctx.device, self.memory, 0, self.size, 0, @ptrCast(&data)) != c.VK_SUCCESS) {
            return error.MapMemoryFailed;
        }
        return data[0 .. self.size / @sizeOf(T)];
    }

    pub fn unmap(self: Buffer, ctx: Context) void {
        c.vkUnmapMemory(ctx.device, self.memory);
    }
};

pub const SimplePipeline = struct {
    handle: c.VkPipeline,
    layout: c.VkPipelineLayout,
    descriptor_set_layout: c.VkDescriptorSetLayout,

    pub fn destroy(self: SimplePipeline, ctx: Context) void {
        c.vkDestroyPipeline(ctx.device, self.handle, null);
        c.vkDestroyPipelineLayout(ctx.device, self.layout, null);
        c.vkDestroyDescriptorSetLayout(ctx.device, self.descriptor_set_layout, null);
    }
};

pub const ShaderCompiler = struct {
    pub fn compile(allocator: std.mem.Allocator, source_path: []const u8, entry_point: []const u8, profile: []const u8) ![]u8 {
        const extension = std.fs.path.extension(source_path);

        // Generate a unique output filename
        const timestamp = std.time.nanoTimestamp();
        const out_filename = try std.fmt.allocPrint(allocator, "temp_shader_{d}.spv", .{timestamp});
        defer allocator.free(out_filename);

        var argv_buf: [20][]const u8 = undefined;
        var argc: usize = 0;

        if (std.mem.eql(u8, extension, ".hlsl")) {
            argv_buf[argc] = "C:\\VulkanSDK\\1.4.335.0\\Bin\\dxc.exe";
            argc += 1;
            argv_buf[argc] = "-T";
            argc += 1;
            argv_buf[argc] = profile;
            argc += 1;
            argv_buf[argc] = "-E";
            argc += 1;
            argv_buf[argc] = entry_point;
            argc += 1;
            argv_buf[argc] = "-spirv";
            argc += 1;
            argv_buf[argc] = source_path;
            argc += 1;
            argv_buf[argc] = "-Fo";
            argc += 1;
            argv_buf[argc] = out_filename;
            argc += 1;
        } else if (std.mem.eql(u8, extension, ".glsl") or std.mem.eql(u8, extension, ".comp")) {
            argv_buf[argc] = "glslc";
            argc += 1;
            argv_buf[argc] = source_path;
            argc += 1;
            argv_buf[argc] = "-o";
            argc += 1;
            argv_buf[argc] = out_filename;
            argc += 1;
        } else {
            return error.UnsupportedShaderFormat;
        }

        const argv = argv_buf[0..argc];

        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        const term = child.spawnAndWait() catch |err| {
            std.debug.print("Failed to spawn compiler: {}\n", .{err});
            // Try fallback if dxc
            if (std.mem.eql(u8, extension, ".hlsl")) {
                std.debug.print("Attempting fallback path for dxc...\n", .{});
                // Re-init with fallback
                // For now, just fail
                return err;
            }
            return err;
        };

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("Shader compiler exited with code: {d}\n", .{code});
                    return error.ShaderCompilationFailed;
                }
            },
            else => return error.ShaderCompilationCrashed,
        }

        // Read output
        const file = try std.fs.cwd().openFile(out_filename, .{});
        defer {
            file.close();
            std.fs.cwd().deleteFile(out_filename) catch {};
        }

        const fileSize = (try file.stat()).size;
        const buffer = try allocator.alloc(u8, fileSize);

        const bytes_read = try file.readAll(buffer);
        if (bytes_read != fileSize) {
            allocator.free(buffer);
            return error.ReadTruncated;
        }

        return buffer;
    }
};
