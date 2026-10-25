//! Exercise both Vulkan dispatch paths against a real loader/software ICD.
const std = @import("std");
const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});
pub fn main() !void {
    var instance: c.VkInstance = null;
    var app = std.mem.zeroes(c.VkApplicationInfo);
    app.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.apiVersion = c.VK_API_VERSION_1_1;
    var info = std.mem.zeroes(c.VkInstanceCreateInfo);
    info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    info.pApplicationInfo = &app;
    if (c.vkCreateInstance(&info, null, &instance) != c.VK_SUCCESS) return error.Instance;
    defer c.vkDestroyInstance(instance, null);
    var physical: [32]c.VkPhysicalDevice = undefined;
    var count: u32 = physical.len;
    if (c.vkEnumeratePhysicalDevices(instance, &count, &physical) != c.VK_SUCCESS or count == 0) return error.NoDevice;
    var queues: [64]c.VkQueueFamilyProperties = undefined;
    var queue_count: u32 = queues.len;
    c.vkGetPhysicalDeviceQueueFamilyProperties(physical[0], &queue_count, &queues);
    const queue = for (queues[0..@min(queue_count, queues.len)], 0..) |properties, i| {
        if (properties.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) break i;
    } else return error.NoQueue;
    const priority: f32 = 1;
    var queue_info = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
    queue_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_info.queueFamilyIndex = @intCast(queue);
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = &priority;
    var device_info = std.mem.zeroes(c.VkDeviceCreateInfo);
    device_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    device_info.queueCreateInfoCount = 1;
    device_info.pQueueCreateInfos = &queue_info;
    const indirect: c.PFN_vkCreateDevice = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkCreateDevice"));
    for ([_]c.PFN_vkCreateDevice{ &c.vkCreateDevice, indirect }) |create| {
        var device: c.VkDevice = null;
        if (create.?(physical[0], &device_info, null, &device) != c.VK_SUCCESS) return error.Device;
        c.vkDestroyDevice(device, null);
    }
}
