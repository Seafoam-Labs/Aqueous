//! Opt-in reproduction instrument, never installed or loaded by the desktop.
//! Observes the device each process actually creates, including GTK's private
//! Vulkan device. A separate enumeration probe cannot establish that identity.
const std = @import("std");
const c = @import("c");

fn next(comptime T: type, name: [:0]const u8) T {
    return @ptrCast(c.dlsym(c.RTLD_NEXT, name));
}

export fn vkCreateDevice(physical: c.VkPhysicalDevice, info: [*c]const c.VkDeviceCreateInfo, allocator: [*c]const c.VkAllocationCallbacks, device: [*c]c.VkDevice) callconv(.c) c.VkResult {
    const create = next(c.PFN_vkCreateDevice, "vkCreateDevice") orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    const result = create(physical, info, allocator, device);
    const properties_fn = next(c.PFN_vkGetPhysicalDeviceProperties, "vkGetPhysicalDeviceProperties") orelse return result;
    var properties: c.VkPhysicalDeviceProperties = undefined;
    properties_fn(physical, &properties);
    var drm = std.mem.zeroes(c.VkPhysicalDeviceDrmPropertiesEXT);
    drm.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT;
    var drm_supported = false;
    if (next(c.PFN_vkEnumerateDeviceExtensionProperties, "vkEnumerateDeviceExtensionProperties")) |extensions_fn| {
        var extensions: [512]c.VkExtensionProperties = undefined;
        var count: u32 = extensions.len;
        const rc = extensions_fn(physical, null, &count, &extensions);
        if (rc == c.VK_SUCCESS or rc == c.VK_INCOMPLETE) {
            for (extensions[0..@min(count, extensions.len)]) |extension| {
                if (std.mem.eql(u8, std.mem.sliceTo(&extension.extensionName, 0), "VK_EXT_physical_device_drm")) drm_supported = true;
            }
        }
    }
    if (drm_supported) {
        if (next(c.PFN_vkGetPhysicalDeviceProperties2, "vkGetPhysicalDeviceProperties2")) |properties2_fn| {
            var properties2 = std.mem.zeroes(c.VkPhysicalDeviceProperties2);
            properties2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
            properties2.pNext = &drm;
            properties2_fn(physical, &properties2);
        }
    }
    var storage: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&storage, "gpu-observer: pid={d} api=vulkan create_result={d} device={s} vendor={x:0>4} device_id={x:0>4} has_render={} render={d}:{d} has_primary={} primary={d}:{d}\n", .{
        c.getpid(),         result,          std.mem.sliceTo(&properties.deviceName, 0), properties.vendorID, properties.deviceID,
        drm.hasRender != 0, drm.renderMajor, drm.renderMinor,                            drm.hasPrimary != 0, drm.primaryMajor,
        drm.primaryMinor,
    }) catch return result;
    _ = c.write(2, line.ptr, line.len);
    return result;
}

export fn vkGetInstanceProcAddr(instance: c.VkInstance, name: [*c]const u8) callconv(.c) c.PFN_vkVoidFunction {
    const get = next(c.PFN_vkGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return null;
    const real = get(instance, name);
    if (real != null and std.mem.eql(u8, std.mem.span(name), "vkCreateDevice")) return @ptrCast(&vkCreateDevice);
    if (real != null and std.mem.eql(u8, std.mem.span(name), "vkEnumeratePhysicalDevices")) return @ptrCast(&vkEnumeratePhysicalDevices);
    return real;
}

export fn vkEnumeratePhysicalDevices(instance: c.VkInstance, count: [*c]u32, devices: [*c]c.VkPhysicalDevice) callconv(.c) c.VkResult {
    const enumerate = next(c.PFN_vkEnumeratePhysicalDevices, "vkEnumeratePhysicalDevices") orelse return c.VK_ERROR_INITIALIZATION_FAILED;
    const result = enumerate(instance, count, devices);
    if (result == c.VK_SUCCESS and count != null) {
        var storage: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&storage, "gpu-observer: pid={d} api=vulkan enumerated={d} selection_verified=false\n", .{ c.getpid(), count.* }) catch return result;
        _ = c.write(2, line.ptr, line.len);
    }
    return result;
}
