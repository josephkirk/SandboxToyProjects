const std = @import("std");

// Rely on the system having vulkan headers available.
const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

const APP_NAME = "Zig Vulkan Compute";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Create Vulkan Instance
    const appInfo = c.VkApplicationInfo{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = APP_NAME,
        .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0),
        .pEngineName = "No Engine",
        .engineVersion = c.VK_MAKE_VERSION(1, 0, 0),
        .apiVersion = c.VK_API_VERSION_1_2,
        .pNext = null,
    };

    // Enable validation layers if useful for debugging (commented out for simplicity)
    const enabledLayers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
    _ = enabledLayers;

    const createInfo = c.VkInstanceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &appInfo,
        .enabledLayerCount = 0, // Set to 1 and point to enabledLayers to debug
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = 0,
        .ppEnabledExtensionNames = null,
        .pNext = null,
        .flags = 0,
    };

    var instance: c.VkInstance = undefined;
    if (c.vkCreateInstance(&createInfo, null, &instance) != c.VK_SUCCESS) {
        std.debug.print("Failed to create instance\n", .{});
        return error.VulkanError;
    }
    defer c.vkDestroyInstance(instance, null);
    std.debug.print("Instance created.\n", .{});

    // 2. Select Physical Device
    var deviceCount: u32 = 0;
    _ = c.vkEnumeratePhysicalDevices(instance, &deviceCount, null);
    if (deviceCount == 0) return error.NoVulkanDevices;

    const pDevices = try allocator.alloc(c.VkPhysicalDevice, deviceCount);
    defer allocator.free(pDevices);
    _ = c.vkEnumeratePhysicalDevices(instance, &deviceCount, pDevices.ptr);

    const physicalDevice = pDevices[0]; // Just pick the first one

    // 3. Find Compute Queue Family
    var queueFamilyCount: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueFamilyCount, null);
    const queueProps = try allocator.alloc(c.VkQueueFamilyProperties, queueFamilyCount);
    defer allocator.free(queueProps);
    c.vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueFamilyCount, queueProps.ptr);

    var computeFamilyIndex: ?u32 = null;
    for (queueProps, 0..) |prop, i| {
        if ((prop.queueFlags & c.VK_QUEUE_COMPUTE_BIT) != 0) {
            computeFamilyIndex = @intCast(i);
            break;
        }
    }
    if (computeFamilyIndex == null) return error.NoComputeQueue;

    // 4. Create Logical Device
    const queuePriority: f32 = 1.0;
    const queueCreateInfo = c.VkDeviceQueueCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = computeFamilyIndex.?,
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
    if (c.vkCreateDevice(physicalDevice, &deviceCreateInfo, null, &device) != c.VK_SUCCESS) {
        return error.DeviceCreationFail;
    }
    defer c.vkDestroyDevice(device, null);

    var queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(device, computeFamilyIndex.?, 0, &queue);

    // 5. Create Buffer (Storage Buffer)
    // We will process 32 floats
    const dataSize = 32 * @sizeOf(f32);

    const bufferCreateInfo = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = dataSize,
        .usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };

    var buffer: c.VkBuffer = undefined;
    if (c.vkCreateBuffer(device, &bufferCreateInfo, null, &buffer) != c.VK_SUCCESS) return error.BufferCreateFail;
    defer c.vkDestroyBuffer(device, buffer, null);

    // 6. Allocate and Bind Memory
    var memReqs: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(device, buffer, &memReqs);

    var memProps: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memProps);

    // Find memory type that is Host Visible and Coherent (for easy mapping)
    var memoryTypeIndex: ?u32 = null;
    const requiredProps = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

    var i: u32 = 0;
    while (i < memProps.memoryTypeCount) : (i += 1) {
        if ((memReqs.memoryTypeBits & (@as(u32, 1) << @intCast(i))) != 0 and
            (memProps.memoryTypes[i].propertyFlags & requiredProps) == requiredProps)
        {
            memoryTypeIndex = i;
            break;
        }
    }
    if (memoryTypeIndex == null) return error.NoSuitableMemory;

    const allocInfo = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = memReqs.size,
        .memoryTypeIndex = memoryTypeIndex.?,
        .pNext = null,
    };

    var deviceMemory: c.VkDeviceMemory = undefined;
    if (c.vkAllocateMemory(device, &allocInfo, null, &deviceMemory) != c.VK_SUCCESS) return error.MemAllocFail;
    defer c.vkFreeMemory(device, deviceMemory, null);

    if (c.vkBindBufferMemory(device, buffer, deviceMemory, 0) != c.VK_SUCCESS) return error.BindFail;

    // 7. Fill Buffer with Initial Data
    var data: [*]f32 = undefined;
    if (c.vkMapMemory(device, deviceMemory, 0, dataSize, 0, @ptrCast(&data)) != c.VK_SUCCESS) return error.MapFail;

    // Fill with 0, 1, 2... 31
    var k: usize = 0;
    while (k < 32) : (k += 1) {
        data[k] = @floatFromInt(k);
    }
    c.vkUnmapMemory(device, deviceMemory);

    // 8. Load Shader (comp.spv)
    // NOTE: You must compile compute.hlsl to comp.spv before running this!
    // Command: dxc -T cs_6_0 -E main -Spirv compute.hlsl -Fo comp.spv
    const shaderCode = try std.fs.cwd().readFileAlloc(allocator, "comp.spv", 1024 * 1024);
    defer allocator.free(shaderCode);

    // SpirV expects u32 alignment, readFileAlloc returns u8 slice.
    // In strict Zig, we should ensure alignment, but typically allocating from GPA is aligned enough for u32.
    // We cast the pointer safely.
    const shaderModuleCreateInfo = c.VkShaderModuleCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = shaderCode.len,
        .pCode = @ptrCast(@alignCast(shaderCode.ptr)),
        .pNext = null,
        .flags = 0,
    };

    var shaderModule: c.VkShaderModule = undefined;
    if (c.vkCreateShaderModule(device, &shaderModuleCreateInfo, null, &shaderModule) != c.VK_SUCCESS) return error.ShaderModuleFail;
    defer c.vkDestroyShaderModule(device, shaderModule, null);

    // 9. Descriptor Set Layout
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
    if (c.vkCreateDescriptorSetLayout(device, &descriptorLayoutInfo, null, &descriptorSetLayout) != c.VK_SUCCESS) return error.DescLayoutFail;
    defer c.vkDestroyDescriptorSetLayout(device, descriptorSetLayout, null);

    // 10. Pipeline Layout
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
    if (c.vkCreatePipelineLayout(device, &pipelineLayoutInfo, null, &pipelineLayout) != c.VK_SUCCESS) return error.PipeLayoutFail;
    defer c.vkDestroyPipelineLayout(device, pipelineLayout, null);

    // 11. Compute Pipeline
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
    if (c.vkCreateComputePipelines(device, null, 1, &pipelineInfo, null, &pipeline) != c.VK_SUCCESS) return error.PipelineFail;
    defer c.vkDestroyPipeline(device, pipeline, null);

    // 12. Descriptor Set
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
    if (c.vkCreateDescriptorPool(device, &descriptorPoolInfo, null, &descriptorPool) != c.VK_SUCCESS) return error.PoolFail;
    defer c.vkDestroyDescriptorPool(device, descriptorPool, null);

    const allocSetInfo = c.VkDescriptorSetAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = descriptorPool,
        .descriptorSetCount = 1,
        .pSetLayouts = &descriptorSetLayout,
        .pNext = null,
    };

    var descriptorSet: c.VkDescriptorSet = undefined;
    if (c.vkAllocateDescriptorSets(device, &allocSetInfo, &descriptorSet) != c.VK_SUCCESS) return error.SetAllocFail;

    const bufferInfo = c.VkDescriptorBufferInfo{
        .buffer = buffer,
        .offset = 0,
        .range = dataSize,
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

    c.vkUpdateDescriptorSets(device, 1, &writeDescriptorSet, 0, null);

    // 13. Command Buffer
    const cmdPoolInfo = c.VkCommandPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = computeFamilyIndex.?,
        .flags = 0,
        .pNext = null,
    };

    var commandPool: c.VkCommandPool = undefined;
    if (c.vkCreateCommandPool(device, &cmdPoolInfo, null, &commandPool) != c.VK_SUCCESS) return error.CmdPoolFail;
    defer c.vkDestroyCommandPool(device, commandPool, null);

    const cmdBufAllocInfo = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = commandPool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
        .pNext = null,
    };

    var commandBuffer: c.VkCommandBuffer = undefined;
    if (c.vkAllocateCommandBuffers(device, &cmdBufAllocInfo, &commandBuffer) != c.VK_SUCCESS) return error.CmdAllocFail;

    const beginInfo = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pNext = null,
        .pInheritanceInfo = null,
    };

    // RECORD COMMANDS
    _ = c.vkBeginCommandBuffer(commandBuffer, &beginInfo);
    c.vkCmdBindPipeline(commandBuffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    c.vkCmdBindDescriptorSets(commandBuffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, &descriptorSet, 0, null);

    // Dispatch: We have 32 elements. HLSL numthreads is (32, 1, 1). So we need 1 group.
    c.vkCmdDispatch(commandBuffer, 1, 1, 1);

    _ = c.vkEndCommandBuffer(commandBuffer);

    // 14. Execute
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

    std.debug.print("Submitting compute job...\n", .{});
    if (c.vkQueueSubmit(queue, 1, &submitInfo, null) != c.VK_SUCCESS) return error.SubmitFail;

    // Wait for it to finish
    _ = c.vkQueueWaitIdle(queue);

    // 15. Read Results
    if (c.vkMapMemory(device, deviceMemory, 0, dataSize, 0, @ptrCast(&data)) != c.VK_SUCCESS) return error.MapFail;

    std.debug.print("Results:\n", .{});
    k = 0;
    while (k < 10) : (k += 1) { // Just print first 10
        std.debug.print("Index {d}: {d} (Expected {d})\n", .{ k, data[k], k * k });
    }
    c.vkUnmapMemory(device, deviceMemory);
}
