#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>

typedef struct VkQueue_T *VkQueue;
typedef struct VkDevice_T *VkDevice;
typedef struct VkSwapchainKHR_T *VkSwapchainKHR;
typedef struct VkSemaphore_T *VkSemaphore;
typedef struct VkFence_T *VkFence;
typedef struct VkPresentInfoKHR VkPresentInfoKHR;
typedef int32_t VkResult;
typedef VkResult (*QueuePresentFn)(VkQueue, const VkPresentInfoKHR *);
typedef VkResult (*AcquireNextImageFn)(
    VkDevice,
    VkSwapchainKHR,
    uint64_t,
    VkSemaphore,
    VkFence,
    uint32_t *
);

enum {
    VK_SUCCESS = 0,
    VK_ERROR_INITIALIZATION_FAILED = -3,
    VK_SUBOPTIMAL_KHR = 1000001003,
};

VkResult vkAcquireNextImageKHR(
    VkDevice device,
    VkSwapchainKHR swapchain,
    uint64_t timeout,
    VkSemaphore semaphore,
    VkFence fence,
    uint32_t *image_index
) {
    static AcquireNextImageFn real_acquire_next_image;
    if (real_acquire_next_image == 0) {
        real_acquire_next_image =
            (AcquireNextImageFn)dlsym(RTLD_NEXT, "vkAcquireNextImageKHR");
    }
    if (real_acquire_next_image == 0) return VK_ERROR_INITIALIZATION_FAILED;

    const VkResult result = real_acquire_next_image(
        device,
        swapchain,
        timeout,
        semaphore,
        fence,
        image_index
    );

    /*
     * VK_SUBOPTIMAL_KHR still returns a valid acquired image. Quark currently
     * resets its frame fence before acquiring, then abandons the frame when it
     * sees SUBOPTIMAL. No submission signals that fence, so the next frame
     * blocks forever in vkWaitForFences. Continuing with the valid image keeps
     * the fence lifecycle intact.
     */
    return result == VK_SUBOPTIMAL_KHR ? VK_SUCCESS : result;
}

VkResult vkQueuePresentKHR(
    VkQueue queue,
    const VkPresentInfoKHR *present_info
) {
    static QueuePresentFn real_queue_present;
    if (real_queue_present == 0) {
        real_queue_present =
            (QueuePresentFn)dlsym(RTLD_NEXT, "vkQueuePresentKHR");
    }
    if (real_queue_present == 0) return VK_ERROR_INITIALIZATION_FAILED;

    const VkResult result = real_queue_present(queue, present_info);
    return result == VK_SUBOPTIMAL_KHR ? VK_SUCCESS : result;
}
