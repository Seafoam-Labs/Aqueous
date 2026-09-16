// SPDX-License-Identifier: GPL-3.0-only
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include "version-source.h"

static uint32_t last_flags, last_error;
static unsigned errors;
static void protocol_log(void *data, enum wl_protocol_logger_type type,
        const struct wl_protocol_logger_message *message) {
    if (type != WL_PROTOCOL_LOGGER_EVENT) return;
    if (!strcmp(message->message->name, "tranche_flags")) last_flags = message->arguments[0].u;
    if (!strcmp(message->message->name, "error")) { last_error = message->arguments[1].u; errors++; }
}

int main(void) {
    struct wl_display *display = wl_display_create(); assert(display);
    struct wl_protocol_logger *logger = wl_display_add_protocol_logger(display, protocol_log, NULL);
    for (int version = 4; version <= 6; version++) {
        int sockets[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
        struct wl_client *client = wl_client_create(display, sockets[0]); assert(client);
        struct wl_resource *feedback = wl_resource_create(client, &zwp_linux_dmabuf_feedback_v1_interface, version, 2);
        struct wlr_linux_dmabuf_feedback_v1_compiled_tranche tranche = {0};
        tranche.flags = ZWP_LINUX_DMABUF_FEEDBACK_V1_TRANCHE_FLAGS_SAMPLING;
        feedback_tranche_send(&tranche, feedback);
        assert(last_flags == (version == 6 ? tranche.flags : 0));
        tranche.flags |= ZWP_LINUX_DMABUF_FEEDBACK_V1_TRANCHE_FLAGS_SCANOUT;
        feedback_tranche_send(&tranche, feedback);
        assert(last_flags == (version == 6 ? tranche.flags : ZWP_LINUX_DMABUF_FEEDBACK_V1_TRANCHE_FLAGS_SCANOUT));
        wl_client_destroy(client); close(sockets[1]);
    }
    struct wlr_linux_dmabuf_feedback_v1_compiled feedback = {.main_device = 123};
    struct wlr_linux_dmabuf_v1 dmabuf = {.default_feedback = &feedback};
    for (unsigned scenario = 0; scenario < 3; scenario++) {
        int sockets[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
        struct wl_client *client = wl_client_create(display, sockets[0]); assert(client);
        struct wlr_linux_buffer_params_v1 params = {.linux_dmabuf = &dmabuf};
        params.resource = wl_resource_create(client, &zwp_linux_buffer_params_v1_interface, 6, 2);
        wl_resource_set_implementation(params.resource, &buffer_params_impl, &params, NULL);
        dev_t device = 123;
        struct wl_array array = {.size = sizeof(device), .data = &device};
        if (scenario == 0) {
            assert(sampling_device_supported(&params));
            params_set_sampling_device(client, params.resource, &array);
            assert(params.has_sampling_device && sampling_device_supported(&params));
            device = 0;
            params_set_sampling_device(client, params.resource, &array);
            assert(params.sampling_device == 0 && !sampling_device_supported(&params));
            assert(errors == 0);
        } else if (scenario == 1) {
            array.size--;
            params_set_sampling_device(client, params.resource, &array);
            assert(errors == 1 && last_error == ZWP_LINUX_BUFFER_PARAMS_V1_ERROR_INVALID_DEV_T_SIZE);
        } else {
            wl_resource_set_user_data(params.resource, NULL);
            params_set_sampling_device(client, params.resource, &array);
            assert(errors == 2 && last_error == ZWP_LINUX_BUFFER_PARAMS_V1_ERROR_ALREADY_USED);
        }
        wl_client_destroy(client); close(sockets[1]);
    }
    wl_protocol_logger_destroy(logger); wl_display_destroy(display);
    puts("PASS DMA-BUF v4/v5/v6: feedback flags, sampling selection, invalid device sizes and used params");
}
