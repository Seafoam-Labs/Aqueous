// Standalone XCB/Vulkan swapchain diagnostic. No compositor or game state is changed.
#define VK_USE_PLATFORM_XCB_KHR
#include <vulkan/vulkan.h>
#include <xcb/xcb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(call) do { \
    printf("CALL %s\n", #call); \
    VkResult result = (call); \
    printf("RETURN %d\n", result); \
    if (result != VK_SUCCESS) return 1; \
} while (0)

static int unsupported(const char *reason) {
    printf("SKIP %s\n", reason);
    return 77;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc != 5) {
        fprintf(stderr, "usage: %s WIDTH HEIGHT fifo|immediate basic|mutable|maintenance\n", argv[0]);
        return 2;
    }
    unsigned width = (unsigned)strtoul(argv[1], NULL, 10);
    unsigned height = (unsigned)strtoul(argv[2], NULL, 10);
    if (!width || width > UINT16_MAX || !height || height > UINT16_MAX) return 2;
    if (strcmp(argv[3], "fifo") && strcmp(argv[3], "immediate")) return 2;
    if (strcmp(argv[4], "basic") && strcmp(argv[4], "mutable") && strcmp(argv[4], "maintenance")) return 2;
    VkPresentModeKHR mode = !strcmp(argv[3], "fifo") ? VK_PRESENT_MODE_FIFO_KHR : VK_PRESENT_MODE_IMMEDIATE_KHR;
    int mutable = strcmp(argv[4], "basic") != 0;
    int maintenance = !strcmp(argv[4], "maintenance");
    printf("CASE %ux%u mode=%s profile=%s\n", width, height, argv[3], argv[4]);
    const char *env_keys[] = {"DISPLAY", "MESA_VK_DEVICE_SELECT", "NODEVICE_SELECT", "__GLX_VENDOR_LIBRARY_NAME", "__NV_PRIME_RENDER_OFFLOAD"};
    for (size_t i = 0; i < sizeof(env_keys) / sizeof(*env_keys); i++)
        printf("ENV %s=%s\n", env_keys[i], getenv(env_keys[i]) ? getenv(env_keys[i]) : "<unset>");

    int screen_number;
    xcb_connection_t *connection = xcb_connect(NULL, &screen_number);
    if (xcb_connection_has_error(connection)) { fprintf(stderr, "Cannot connect to XWayland\n"); return 1; }
    xcb_screen_iterator_t screens = xcb_setup_roots_iterator(xcb_get_setup(connection));
    for (int i = 0; i < screen_number; i++) xcb_screen_next(&screens);
    xcb_screen_t *screen = screens.data;
    printf("X11 root_depth=%u root_visual=%u\n", screen->root_depth, screen->root_visual);
    xcb_window_t window = xcb_generate_id(connection);
    // Override redirect preserves the requested dimensions under a tiling WM.
    // This is a controlled WSI test, not an emulation of Wine window management.
    uint32_t values[] = {screen->black_pixel, 1};
    xcb_generic_error_t *error = xcb_request_check(connection, xcb_create_window_checked(
        connection, XCB_COPY_FROM_PARENT, window, screen->root, 0, 0,
        (uint16_t)width, (uint16_t)height, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen->root_visual, XCB_CW_BACK_PIXEL | XCB_CW_OVERRIDE_REDIRECT, values));
    if (error) { fprintf(stderr, "X11 create error=%u\n", error->error_code); free(error); return 1; }
    const char title[] = "Aqueous Vulkan diagnostic";
    xcb_change_property(connection, XCB_PROP_MODE_REPLACE, window, XCB_ATOM_WM_NAME,
        XCB_ATOM_STRING, 8, sizeof(title) - 1, title);
    xcb_map_window(connection, window);
    xcb_flush(connection);
    free(xcb_get_input_focus_reply(connection, xcb_get_input_focus(connection), NULL));

    const char *instance_extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_XCB_SURFACE_EXTENSION_NAME,
        VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME, VK_KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME};
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "aqueous-xwayland-probe", .apiVersion = VK_API_VERSION_1_2};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app, .enabledExtensionCount = maintenance ? 4 : 2, .ppEnabledExtensionNames = instance_extensions};
    VkInstance instance;
    CHECK(vkCreateInstance(&ici, NULL, &instance));
    uint32_t gpu_count = 0;
    CHECK(vkEnumeratePhysicalDevices(instance, &gpu_count, NULL));
    VkPhysicalDevice *gpus = calloc(gpu_count, sizeof(*gpus));
    if (!gpus) return 1;
    CHECK(vkEnumeratePhysicalDevices(instance, &gpu_count, gpus));
    VkPhysicalDevice gpu = VK_NULL_HANDLE;
    for (uint32_t i = 0; i < gpu_count; i++) {
        VkPhysicalDeviceProperties properties;
        vkGetPhysicalDeviceProperties(gpus[i], &properties);
        printf("GPU %u %s vendor=%x device=%x api=%u driver=%u\n", i,
            properties.deviceName, properties.vendorID, properties.deviceID, properties.apiVersion, properties.driverVersion);
        if (properties.vendorID == 0x10de && !gpu) gpu = gpus[i];
    }
    free(gpus);
    if (!gpu) return unsupported("No NVIDIA GPU; no silent fallback to another vendor");
    VkXcbSurfaceCreateInfoKHR sci = {.sType = VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR,
        .connection = connection, .window = window};
    VkSurfaceKHR surface;
    CHECK(vkCreateXcbSurfaceKHR(instance, &sci, NULL, &surface));
    uint32_t queue_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &queue_count, NULL);
    VkQueueFamilyProperties *queues = calloc(queue_count, sizeof(*queues));
    if (!queues) return 1;
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &queue_count, queues);
    uint32_t queue_index = UINT32_MAX;
    for (uint32_t i = 0; i < queue_count; i++) {
        printf("CALL vkGetPhysicalDeviceXcbPresentationSupportKHR queue=%u\n", i);
        VkBool32 xcb_support = vkGetPhysicalDeviceXcbPresentationSupportKHR(gpu, i, connection, screen->root_visual);
        printf("RETURN xcb_support=%u\n", xcb_support);
        VkBool32 support;
        CHECK(vkGetPhysicalDeviceSurfaceSupportKHR(gpu, i, surface, &support));
        if (xcb_support && support && (queues[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) { queue_index = i; break; }
    }
    free(queues);
    if (queue_index == UINT32_MAX) return unsupported("No graphics/presentation queue");
    VkSurfaceCapabilitiesKHR caps;
    CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gpu, surface, &caps));
    printf("CAPS images=%u..%u extent=%ux%u usage=%x transforms=%x alpha=%x\n",
        caps.minImageCount, caps.maxImageCount, caps.currentExtent.width, caps.currentExtent.height,
        caps.supportedUsageFlags, caps.supportedTransforms, caps.supportedCompositeAlpha);
    uint32_t format_count = 0;
    CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(gpu, surface, &format_count, NULL));
    VkSurfaceFormatKHR *formats = calloc(format_count, sizeof(*formats));
    if (!formats) return 1;
    CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(gpu, surface, &format_count, formats));
    int format_ok = 0;
    for (uint32_t i = 0; i < format_count; i++) {
        printf("FORMAT %d colorspace=%d\n", formats[i].format, formats[i].colorSpace);
        if ((formats[i].format == VK_FORMAT_B8G8R8A8_UNORM || formats[i].format == VK_FORMAT_UNDEFINED)
            && formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) format_ok = 1;
    }
    free(formats);
    if (!format_ok) return unsupported("BGRA8 UNORM / sRGB nonlinear unavailable");
    uint32_t mode_count = 0;
    CHECK(vkGetPhysicalDeviceSurfacePresentModesKHR(gpu, surface, &mode_count, NULL));
    VkPresentModeKHR *modes = calloc(mode_count, sizeof(*modes));
    if (!modes) return 1;
    CHECK(vkGetPhysicalDeviceSurfacePresentModesKHR(gpu, surface, &mode_count, modes));
    int mode_ok = 0;
    for (uint32_t i = 0; i < mode_count; i++) { printf("MODE %d\n", modes[i]); if (modes[i] == mode) mode_ok = 1; }
    free(modes);
    if (!mode_ok) return unsupported("Requested present mode unavailable");
    const VkImageUsageFlags usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (caps.minImageCount > 5 || (caps.maxImageCount && caps.maxImageCount < 5)
        || (caps.supportedUsageFlags & usage) != usage
        || !(caps.supportedTransforms & VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR)
        || !(caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR))
        return unsupported("Logged swapchain settings outside surface capabilities");

    const char *extensions[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME,
        VK_KHR_SWAPCHAIN_MUTABLE_FORMAT_EXTENSION_NAME, VK_KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME};
    uint32_t extension_count = 0;
    CHECK(vkEnumerateDeviceExtensionProperties(gpu, NULL, &extension_count, NULL));
    VkExtensionProperties *available = calloc(extension_count, sizeof(*available));
    if (!available) return 1;
    CHECK(vkEnumerateDeviceExtensionProperties(gpu, NULL, &extension_count, available));
    unsigned needed = maintenance ? 3 : mutable ? 2 : 1;
    for (unsigned i = 0; i < needed; i++) {
        int found = 0;
        for (uint32_t j = 0; j < extension_count; j++) if (!strcmp(extensions[i], available[j].extensionName)) found = 1;
        if (!found) return unsupported(extensions[i]);
    }
    free(available);
    VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR maintenance_features = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_KHR};
    VkPhysicalDeviceFeatures2 features = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = maintenance ? &maintenance_features : NULL};
    printf("CALL vkGetPhysicalDeviceFeatures2\n");
    vkGetPhysicalDeviceFeatures2(gpu, &features);
    printf("RETURN maintenance=%u\n", maintenance_features.swapchainMaintenance1);
    if (maintenance && !maintenance_features.swapchainMaintenance1) return unsupported("maintenance feature unavailable");
    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = queue_index, .queueCount = 1, .pQueuePriorities = &priority};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = maintenance ? &maintenance_features : NULL, .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci, .enabledExtensionCount = needed, .ppEnabledExtensionNames = extensions};
    VkDevice device;
    CHECK(vkCreateDevice(gpu, &dci, NULL, &device));
    VkFormat view_formats[] = {VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_B8G8R8A8_SRGB};
    VkImageFormatListCreateInfo format_list = {.sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO,
        .viewFormatCount = 2, .pViewFormats = view_formats};
    // One allowed mode exercises the maintenance pNext without assuming cross-mode compatibility.
    VkSwapchainPresentModesCreateInfoKHR present_modes = {.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_MODES_CREATE_INFO_KHR,
        .pNext = &format_list, .presentModeCount = 1, .pPresentModes = &mode};
    VkExtent2D extent = caps.currentExtent.width == UINT32_MAX ? (VkExtent2D){width, height} : caps.currentExtent;
    if (extent.width != width || extent.height != height) return unsupported("X11 window did not retain requested extent");
    VkSwapchainCreateInfoKHR swap_info = {.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .pNext = maintenance ? (void *)&present_modes : mutable ? (void *)&format_list : NULL,
        .flags = mutable ? VK_SWAPCHAIN_CREATE_MUTABLE_FORMAT_BIT_KHR : 0,
        .surface = surface, .minImageCount = 5, .imageFormat = VK_FORMAT_B8G8R8A8_UNORM,
        .imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR, .imageExtent = extent,
        .imageArrayLayers = 1, .imageUsage = usage, .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR, .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = mode, .clipped = VK_TRUE};
    VkSwapchainKHR swapchain;
    CHECK(vkCreateSwapchainKHR(device, &swap_info, NULL, &swapchain));
    uint32_t image_count = 0;
    CHECK(vkGetSwapchainImagesKHR(device, swapchain, &image_count, NULL));
    printf("IMAGES %u\n", image_count);
    VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence fence;
    CHECK(vkCreateFence(device, &fci, NULL, &fence));
    uint32_t image_index;
    CHECK(vkAcquireNextImageKHR(device, swapchain, 3000000000ULL, VK_NULL_HANDLE, fence, &image_index));
    CHECK(vkWaitForFences(device, 1, &fence, VK_TRUE, 3000000000ULL));
    printf("ACQUIRED %u\n", image_index);
    vkDestroyFence(device, fence, NULL);
    vkDestroySwapchainKHR(device, swapchain, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroySurfaceKHR(instance, surface, NULL);
    vkDestroyInstance(instance, NULL);
    xcb_destroy_window(connection, window);
    xcb_disconnect(connection);
    puts("PASS swapchain creation and acquisition (no rendering/presentation)");
    return 0;
}
