// SPDX-License-Identifier: GPL-3.0-only
// Regression for drag cancellation over a non-accepting XWayland window.
// The source destroy listener must keep drag->source valid while the destroy
// signal is emitted: XWM's drag-focus teardown reads xwm->drag->source to
// reset the DnD action before sending XdndLeave. NULLing it early crashed the
// compositor with SIGSEGV (converted to SIGABRT) on button release.
#include <assert.h>
#include <linux/input-event-codes.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/xwayland.h>
#include <wlr/util/addon.h>
#include "types/wlr_seat.h"
#include "xwayland-dnd-source.h"

// XWM dispatches XDND client messages through these helpers. They are internal
// to libwlroots and need a live X connection, so record the traffic instead.
static unsigned sent_events;
static xcb_atom_t last_event_type;
static xcb_window_t last_event_window;

xcb_void_cookie_t xwm_send_event_with_size(xcb_connection_t *c,
		uint8_t propagate, xcb_window_t destination,
		uint32_t event_mask, const void *event, uint32_t length) {
	(void)c; (void)propagate; (void)event_mask; (void)length;
	const xcb_client_message_event_t *message = event;
	sent_events++;
	last_event_type = message->type;
	last_event_window = destination;
	return (xcb_void_cookie_t){ .sequence = 0 };
}

void xwm_schedule_flush(struct wlr_xwm *xwm) {
	(void)xwm;
}

xcb_atom_t xwm_mime_type_to_atom(struct wlr_xwm *xwm, char *mime_type) {
	(void)xwm; (void)mime_type;
	return XCB_ATOM_NONE;
}

static struct {
	struct wlr_data_source base;
	unsigned destroyed, dnd_actions, finished;
	enum wl_data_device_manager_dnd_action last_action;
} source;

static void source_send(struct wlr_data_source *s, const char *mime, int32_t fd) {
	(void)s; (void)mime; (void)fd;
	assert(false && "no transfer is expected during cancellation");
}

static void source_destroy(struct wlr_data_source *s) {
	assert(s == &source.base);
	source.destroyed++;
}

static void source_dnd_finish(struct wlr_data_source *s) {
	assert(s == &source.base);
	source.finished++;
}

static void source_dnd_action(struct wlr_data_source *s,
		enum wl_data_device_manager_dnd_action action) {
	// XWM resets the action during teardown; the source must still be alive.
	assert(s == &source.base && source.destroyed == 0);
	source.dnd_actions++;
	source.last_action = action;
}

static const struct wlr_data_source_impl source_impl = {
	.send = source_send,
	.destroy = source_destroy,
	.dnd_finish = source_dnd_finish,
	.dnd_action = source_dnd_action,
};

static void init_client(struct wlr_seat_client *client, struct wlr_seat *seat,
		struct wl_client *wl_client) {
	*client = (struct wlr_seat_client){.seat = seat, .client = wl_client};
	wl_list_init(&client->resources); wl_list_init(&client->pointers);
	wl_list_init(&client->keyboards); wl_list_init(&client->touches);
	wl_list_init(&client->data_devices);
	wl_signal_init(&client->events.destroy);
	wl_list_insert(&seat->clients, &client->link);
}

static void finish_client(struct wlr_seat_client *client) {
	wlr_seat_pointer_clear_focus(client->seat);
	wl_signal_emit_mutable(&client->events.destroy, client);
	assert(wl_list_empty(&client->events.destroy.listener_list));
	wl_list_remove(&client->link);
}

int main(void) {
	struct wl_display *display = wl_display_create();
	assert(display);
	struct wlr_seat *seat = wlr_seat_create(display, "test");
	assert(seat);
	wlr_seat_set_capabilities(seat, WL_SEAT_CAPABILITY_POINTER);

	int sockets[2];
	assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
	struct wl_client *wl_client = wl_client_create(display, sockets[0]);
	assert(wl_client);
	struct wlr_seat_client seat_client;
	init_client(&seat_client, seat, wl_client);

	// Stand-in for the XWayland surface under the pointer. It carries no
	// XWayland addon, so wlr_xwayland_surface_try_from_wlr_surface returns
	// NULL and the XWM drag focus is established explicitly below, exactly
	// as it stands after XdndEnter over a real X11 window.
	struct wlr_surface xsurf = {
		.resource = wl_resource_create(wl_client, &wl_surface_interface, 4, 2),
	};
	assert(xsurf.resource);
	wl_signal_init(&xsurf.events.destroy);
	wlr_addon_set_init(&xsurf.addons);
	struct wlr_xwayland_surface xsurface = {.window_id = 42, .surface = &xsurf};
	wl_signal_init(&xsurface.events.destroy);

	struct wlr_xwm xwm = {.seat = seat};
	xwm.atoms[DND_ENTER] = 0x1001;
	xwm.atoms[DND_LEAVE] = 0x1002;
	wl_list_init(&xwm.drag_focus_destroy.link);
	wl_list_init(&xwm.drop_focus_destroy.link);

	wlr_data_source_init(&source.base, &source_impl);
	source.base.actions = WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY |
		WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE;

	// Cancel over an X11 window that never accepted the drag.
	struct wlr_drag *drag = wlr_drag_create(&seat_client, &source.base, NULL);
	assert(drag);
	wlr_seat_start_pointer_drag(seat, drag, 1);
	xwm_seat_handle_start_drag(&xwm, drag);
	wlr_seat_pointer_notify_enter(seat, &xsurf, 5, 5);
	assert(drag->focus == &xsurf && drag->focus_client == &seat_client);
	xwm_set_drag_focus(&xwm, &xsurface);
	assert(xwm.drag_focus == &xsurface);
	assert(sent_events == 1 && last_event_type == xwm.atoms[DND_ENTER] &&
		last_event_window == xsurface.window_id);
	assert(!source.base.accepted);

	wlr_seat_pointer_notify_button(seat, 100, BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
	wlr_seat_pointer_notify_button(seat, 101, BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);

	assert(source.destroyed == 1);
	assert(source.dnd_actions == 1 &&
		source.last_action == WL_DATA_DEVICE_MANAGER_DND_ACTION_NONE);
	assert(sent_events == 2 && last_event_type == xwm.atoms[DND_LEAVE] &&
		last_event_window == xsurface.window_id);
	assert(seat->drag == NULL && seat->drag_source == NULL);
	assert(xwm.drag == NULL && xwm.drag_focus == NULL);

	// The seat must remain usable after the cancelled drag.
	wlr_seat_pointer_enter(seat, &xsurf, 1, 1);
	wlr_seat_pointer_notify_button(seat, 102, BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
	wlr_seat_pointer_notify_button(seat, 103, BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);
	wlr_seat_pointer_clear_focus(seat);

	// Grab cancellation without a source destroy must leave a plain source
	// alive for the client, and a later client destroy must still clean up.
	memset(&source, 0, sizeof(source));
	wlr_data_source_init(&source.base, &source_impl);
	source.base.actions = WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY;
	drag = wlr_drag_create(&seat_client, &source.base, NULL);
	assert(drag);
	wlr_seat_start_pointer_drag(seat, drag, 2);
	xwm_seat_handle_start_drag(&xwm, drag);
	wlr_seat_pointer_notify_enter(seat, &xsurf, 5, 5);
	xwm_set_drag_focus(&xwm, &xsurface);
	wlr_seat_pointer_notify_button(seat, 104, BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
	wlr_seat_pointer_end_grab(seat);
	assert(source.destroyed == 0 && source.finished == 0);
	assert(seat->drag == NULL && seat->drag_source == &source.base);
	assert(xwm.drag == NULL && xwm.drag_focus == NULL);
	wlr_data_source_destroy(&source.base);
	assert(source.destroyed == 1 && seat->drag_source == NULL);

	finish_client(&seat_client);
	wl_client_destroy(wl_client);
	close(sockets[1]);
	wl_display_destroy(display);
	puts("PASS drag cancellation over non-accepting XWayland focus keeps the source alive through teardown");
	return 0;
}