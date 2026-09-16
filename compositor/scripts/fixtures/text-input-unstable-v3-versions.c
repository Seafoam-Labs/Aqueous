// SPDX-License-Identifier: GPL-3.0-only
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>
#include "version-source.h"

static unsigned actions, hints, languages, errors;
static void protocol_log(void *data, enum wl_protocol_logger_type type,
        const struct wl_protocol_logger_message *message) {
    if (type != WL_PROTOCOL_LOGGER_EVENT) return;
    const char *name = message->message->name;
    if (!strcmp(name, "action")) actions++;
    if (!strcmp(name, "preedit_hint")) hints++;
    if (!strcmp(name, "language")) languages++;
    if (!strcmp(name, "error")) {
        assert(message->arguments[1].u == ZWP_TEXT_INPUT_V3_ERROR_INVALID_ACTION);
        errors++;
    }
}

int main(void) {
    struct wl_display *display = wl_display_create(); assert(display);
    struct wl_protocol_logger *logger = wl_display_add_protocol_logger(display, protocol_log, NULL);
    struct wlr_text_input_manager_v3 *manager = wlr_text_input_manager_v3_create(display);
    assert(manager && wl_global_get_version(manager->global) == 2);
    for (int version = 1; version <= 2; version++) {
        int sockets[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
        struct wl_client *client = wl_client_create(display, sockets[0]); assert(client);
        struct text_input input = {0};
        struct wlr_text_input_v3 *base = &input.base;
        base->resource = wl_resource_create(client, &zwp_text_input_v3_interface, version, 2);
        wl_resource_set_implementation(base->resource, &text_input_impl, base, NULL);
        wl_signal_init(&base->events.enable); wl_signal_init(&base->events.disable);
        wl_signal_init(&base->events.commit); wl_list_init(&base->surface_destroy.link);
        struct wlr_surface surface = {.resource = wl_resource_create(client, &wl_surface_interface, 1, 3)};
        wl_signal_init(&surface.events.destroy);
        wlr_text_input_v3_send_enter(base, &surface);
        text_input_enable(client, base->resource);
        uint32_t submit = ZWP_TEXT_INPUT_V3_ACTION_SUBMIT;
        struct wl_array array = {.size = sizeof(submit), .data = &submit};
        text_input_set_available_actions(client, base->resource, &array);
        assert(wlr_text_input_v3_get_available_actions(base) == 0);
        text_input_commit(client, base->resource);
        assert(wlr_text_input_v3_get_available_actions(base) == (1u << submit));
        text_input_show_panel(client, base->resource);
        assert(wlr_text_input_v3_get_panel_requested(base));
        text_input_hide_panel(client, base->resource);
        assert(!wlr_text_input_v3_get_panel_requested(base));
        unsigned before = actions;
        wlr_text_input_v3_send_action(base, submit, 5);
        assert(actions == before + (version == 2));
        before = languages;
        wlr_text_input_v3_send_language(base, "en-US");
        assert(languages == before + (version == 2));
        base->current.content_type.hint = ZWP_TEXT_INPUT_V3_CONTENT_HINT_PREEDIT_SHOWN;
        before = hints;
        wlr_text_input_v3_send_preedit_string(base, "abc", 0, 3);
        assert(hints == before + (version == 2));
        before = hints;
        wlr_text_input_v3_send_preedit_hint(base, 0, 4, ZWP_TEXT_INPUT_V3_PREEDIT_HINT_WHOLE);
        wlr_text_input_v3_send_done(base);
        wlr_text_input_v3_send_preedit_hint(base, 0, 3, ZWP_TEXT_INPUT_V3_PREEDIT_HINT_WHOLE);
        assert(hints == before);
        text_input_disable(client, base->resource);
        assert(wlr_text_input_v3_get_available_actions(base) != 0);
        text_input_commit(client, base->resource);
        assert(wlr_text_input_v3_get_available_actions(base) == 0);
        before = actions;
        wlr_text_input_v3_send_action(base, submit, 6);
        assert(actions == before);
        wlr_text_input_v3_send_leave(base);
        assert(!input.has_preedit && !input.panel_visible && !input.current_actions);
        wl_resource_set_user_data(base->resource, NULL);
        text_input_set_available_actions(client, base->resource, &array);
        text_input_show_panel(client, base->resource); text_input_hide_panel(client, base->resource);
        wl_client_destroy(client); close(sockets[1]);
    }
    // Each fatal protocol error uses a separate client.
    uint32_t invalid[][2] = {{0}, {1, 1}, {99}, {1}};
    size_t sizes[] = {4, 8, 4, 1};
    for (unsigned i = 0; i < 4; i++) {
        int sockets[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
        struct wl_client *client = wl_client_create(display, sockets[0]); assert(client);
        struct text_input input = {0};
        input.base.resource = wl_resource_create(client, &zwp_text_input_v3_interface, 2, 2);
        wl_resource_set_implementation(input.base.resource, &text_input_impl, &input.base, NULL);
        struct wl_array array = {.size = sizes[i], .data = invalid[i]};
        text_input_set_available_actions(client, input.base.resource, &array);
        assert(errors == i + 1);
        wl_client_destroy(client); close(sockets[1]);
    }
    wl_protocol_logger_destroy(logger); wl_display_destroy(display);
    puts("PASS text-input v1/v2: buffering, events, panel hints, focus, inert requests and invalid actions");
}
