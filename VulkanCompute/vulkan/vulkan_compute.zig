const std = @import("std");

/// The @cImport function allows us to use C headers directly in Zig.
/// Here we are importing the Vulkan header, which contains the API definitions.
pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

/// Context holds the basic Vulkan objects required for compute operations.
pub const Context = struct {
    allocator: std.mem.Allocator,

    /// VkInstance is the connection between your application and the Vulkan runtime.
    /// It stores application-level state and defines which extensions and layers are used.
    instance: c.VkInstance,

    /// VkPhysicalDevice represents a specific GPU in the system.
    /// We use it to query hardware capabilities, properties, and limits.
    physical_device: c.VkPhysicalDevice,

    /// VkDevice is the logical device used to interact with the physical device.
    /// This is where we create most of our Vulkan resources (buffers, pipelines, etc.).
    device: c.VkDevice,

    /// Vulkan queues are grouped into families. Each family supports specific operations
    /// (e.g., Graphics, Compute, Transfer). We store the index of the family we use.
    queue_family_index: u32,

    /// VkQueue is the handle used to submit command buffers to the GPU for execution.
    queue: c.VkQueue,

    /// VkCommandPool manages memory for command buffers.
    command_pool: c.VkCommandPool,

    /// Initializes the Vulkan context for compute-only tasks.
    pub fn init(allocator: std.mem.Allocator, app_name: [*:0]const u8) !Context {
        // 1. Create Instance
        // ApplicationInfo helps the driver optimize for specific engines or versions.
        const appInfo = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = app_name,
            .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0),
            .pEngineName = "No Engine",
            .engineVersion = c.VK_MAKE_VERSION(1, 0, 0),
            .apiVersion = c.VK_API_VERSION_1_2, // We target Vulkan 1.2
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
        // We enumerate all available GPUs and pick the first one for simplicity.
        var deviceCount: u32 = 0;
        _ = c.vkEnumeratePhysicalDevices(instance, &deviceCount, null);
        if (deviceCount == 0) return error.NoVulkanDevices;

        const pDevices = try allocator.alloc(c.VkPhysicalDevice, deviceCount);
        defer allocator.free(pDevices);
        _ = c.vkEnumeratePhysicalDevices(instance, &deviceCount, pDevices.ptr);

        const physical_device = pDevices[0];

        // 3. Find Compute Queue
        // Queues are the entry point for work on the GPU. We need a family that supports Compute.
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
        // We describe which queues we want to use and which features we need.
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
            .pEnabledFeatures = null, // No special features requested
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .pNext = null,
            .flags = 0,
        };

        var device: c.VkDevice = undefined;
        if (c.vkCreateDevice(physical_device, &deviceCreateInfo, null, &device) != c.VK_SUCCESS) {
            return error.DeviceCreationFailed;
        }
        errdefer c.vkDestroyDevice(device, null);

        // Fetch the queue handle after device creation.
        var queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(device, q_family_index, 0, &queue);

        // 5. Create Command Pool
        // Command buffers are allocated from pools to reduce allocation overhead.
        const cmdPoolInfo = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = q_family_index,
            .flags = 0,
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

    /// Creates a VkBuffer and allocates/binds memory for it.
    /// In Vulkan, creating a buffer and allocating memory are separate steps.
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

        // 1. Get memory requirements for the buffer (size and alignment).
        var memReqs: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, vk_buffer, &memReqs);

        // 2. Find a memory type that is both compatible with the buffer
        //    AND supported by the hardware for our specific needs
        //    (e.g., host-visible for CPU mapping).
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

        // 3. Allocate memory on the device.
        var memory: c.VkDeviceMemory = undefined;
        if (c.vkAllocateMemory(self.device, &allocInfo, null, &memory) != c.VK_SUCCESS) {
            return error.MemoryAllocationFailed;
        }
        errdefer c.vkFreeMemory(self.device, memory, null);

        // 4. Bind the allocated memory to the buffer.
        if (c.vkBindBufferMemory(self.device, vk_buffer, memory, 0) != c.VK_SUCCESS) {
            return error.BindBufferMemoryFailed;
        }

        return Buffer{
            .handle = vk_buffer,
            .memory = memory,
            .size = size,
        };
    }

    /// Creates a simple compute pipeline using the provided SPIR-V bytecode.
    pub fn createSimpleComputePipeline(self: Context, spirv_code: []const u8) !SimplePipeline {
        // Shader module represents compiled code.
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

        // DescriptorSetLayout defines the "interface" between the application and the shader.
        // It describes how many buffers/images the shader expects.
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

        // PipelineLayout is a collection of DescriptorSetLayouts and Push Constant ranges.
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

        // ComputePipeline contains the final GPU state to run the shader.
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

        // We can destroy the shader module once the pipeline is created.
        c.vkDestroyShaderModule(self.device, shaderModule, null);

        return SimplePipeline{
            .handle = pipeline,
            .layout = pipelineLayout,
            .descriptor_set_layout = descriptorSetLayout,
        };
    }

    /// Runs a compute pipeline on a buffer and waits for completion.
    pub fn runSimple(self: Context, pipeline: SimplePipeline, buffer: Buffer, x: u32, y: u32, z: u32) !void {
        // Descriptor Pool is required to allocate Descriptor Sets.
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

        // Allocate a Descriptor Set from the pool.
        const allocSetInfo = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = descriptorPool,
            .descriptorSetCount = 1,
            .pSetLayouts = &pipeline.descriptor_set_layout,
            .pNext = null,
        };

        var descriptorSet: c.VkDescriptorSet = undefined;
        if (c.vkAllocateDescriptorSets(self.device, &allocSetInfo, &descriptorSet) != c.VK_SUCCESS) return error.DescriptorSetAllocationFailed;

        // Update Descriptor Set to point to our buffer.
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

        // Allocate a command buffer to record commands.
        const cmdBufAllocInfo = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
            .pNext = null,
        };

        var commandBuffer: c.VkCommandBuffer = undefined;
        if (c.vkAllocateCommandBuffers(self.device, &cmdBufAllocInfo, &commandBuffer) != c.VK_SUCCESS) return error.CommandBufferAllocationFailed;

        // Record the commands.
        const beginInfo = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pNext = null,
            .pInheritanceInfo = null,
        };

        _ = c.vkBeginCommandBuffer(commandBuffer, &beginInfo);
        c.vkCmdBindPipeline(commandBuffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline.handle);
        c.vkCmdBindDescriptorSets(commandBuffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline.layout, 0, 1, &descriptorSet, 0, null);
        c.vkCmdDispatch(commandBuffer, x, y, z); // Launch threads!
        _ = c.vkEndCommandBuffer(commandBuffer);

        // Submit to the queue for execution.
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

        // Wait for work to finish (inefficient but simple).
        _ = c.vkQueueWaitIdle(self.queue);

        c.vkFreeCommandBuffers(self.device, self.command_pool, 1, &commandBuffer);
    }
};

/// Represents a GPU buffer and its backing memory.
pub const Buffer = struct {
    handle: c.VkBuffer,
    memory: c.VkDeviceMemory,
    size: u64,

    pub fn destroy(self: Buffer, ctx: Context) void {
        c.vkDestroyBuffer(ctx.device, self.handle, null);
        c.vkFreeMemory(ctx.device, self.memory, null);
    }

    /// Maps device memory into the application's address space for CPU access.
    pub fn map(self: Buffer, ctx: Context, comptime T: type) ![]T {
        var data: [*]T = undefined;
        if (c.vkMapMemory(ctx.device, self.memory, 0, self.size, 0, @ptrCast(&data)) != c.VK_SUCCESS) {
            return error.MapMemoryFailed;
        }
        return data[0 .. self.size / @sizeOf(T)];
    }

    /// Unmaps the memory - CPU can no longer access it directly.
    pub fn unmap(self: Buffer, ctx: Context) void {
        c.vkUnmapMemory(ctx.device, self.memory);
    }
};

/// Represents a compiled compute pipeline.
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

/// Helper to compile HLSL/GLSL shaders to SPIR-V at runtime.
pub const ShaderCompiler = struct {
    pub fn compile(allocator: std.mem.Allocator, source_path: []const u8, entry_point: []const u8, profile: []const u8) ![]u8 {
        const extension = std.fs.path.extension(source_path);

        const timestamp = std.time.nanoTimestamp();
        const out_filename = try std.fmt.allocPrint(allocator, "temp_shader_{d}.spv", .{timestamp});
        defer allocator.free(out_filename);

        var argv_buf: [20][]const u8 = undefined;
        var argc: usize = 0;

        if (std.mem.eql(u8, extension, ".hlsl")) {
            // Use DXC for HLSL to SPIR-V
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
            // Use glslc for GLSL to SPIR-V
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
