// SPDX-License-Identifier: GPL-3.0-only
#include <assert.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>
#include "pointer-source.h"

static uint32_t enter_serial, button_serial;
static unsigned enters;
static void protocol_log(void *data, enum wl_protocol_logger_type type,
        const struct wl_protocol_logger_message *message) {
    (void)data;
    if (type != WL_PROTOCOL_LOGGER_EVENT || strcmp(wl_resource_get_class(message->resource), "wl_pointer")) return;
    if (!strcmp(message->message->name,"enter")) { enter_serial=message->arguments[0].u; enters++; }
    if (!strcmp(message->message->name,"button")) button_serial=message->arguments[0].u;
}
static void init_client(struct wlr_seat_client *client, struct wlr_seat *seat, struct wl_client *wl_client) {
    *client=(struct wlr_seat_client){.seat=seat,.client=wl_client};
    wl_list_init(&client->resources); wl_list_init(&client->pointers);
    wl_list_init(&client->keyboards); wl_list_init(&client->touches); wl_list_init(&client->data_devices);
    wl_signal_init(&client->events.destroy);
    wl_list_insert(&seat->clients,&client->link);
}
static void finish_client(struct wlr_seat_client *client) {
    wlr_seat_pointer_clear_focus(client->seat);
    wl_signal_emit_mutable(&client->events.destroy,client);
    assert(wl_list_empty(&client->events.destroy.listener_list));
    wl_list_remove(&client->link);
}
int main(void) {
    struct wl_display *display=wl_display_create(); assert(display);
    struct wl_protocol_logger *logger=wl_display_add_protocol_logger(display,protocol_log,NULL); assert(logger);
    int sockets[2]; assert(socketpair(AF_UNIX,SOCK_STREAM,0,sockets)==0);
    struct wl_client *wl_client=wl_client_create(display,sockets[0]); assert(wl_client);
    struct wlr_seat *seat=wlr_seat_create(display,"test"), *second=wlr_seat_create(display,"second"); assert(seat && second);
    wlr_seat_set_capabilities(seat,WL_SEAT_CAPABILITY_POINTER);
    struct wlr_seat_client client, other;
    init_client(&client,seat,wl_client); init_client(&other,second,wl_client);
    struct wlr_surface a={.resource=wl_resource_create(wl_client,&wl_surface_interface,4,2)};
    struct wlr_surface b={.resource=wl_resource_create(wl_client,&wl_surface_interface,4,3)};
    assert(a.resource && b.resource); wl_signal_init(&a.events.destroy); wl_signal_init(&b.events.destroy);
    wlr_seat_pointer_enter(seat,&a,10,10);
    assert(enters==0); // focus without any live resource must not authorize a serial
    assert(!wlr_seat_client_validate_pointer_enter_serial(&client,wl_display_get_serial(display)));
    seat_client_create_pointer(&client,7,4);
    assert(enters==1 && wlr_seat_client_validate_pointer_enter_serial(&client,enter_serial));
    uint32_t first=enter_serial;
    seat_client_create_pointer(&client,7,5);
    assert(enters==2 && enter_serial!=first);
    assert(wlr_seat_client_validate_pointer_enter_serial(&client,first));
    uint32_t late=enter_serial;
    wlr_seat_pointer_enter(seat,&b,20,20);
    assert(enters==4); // same serial broadcast to both pointers
    assert(wlr_seat_client_validate_pointer_enter_serial(&client,first));
    assert(wlr_seat_client_validate_pointer_enter_serial(&client,late));
    assert(wlr_seat_client_validate_pointer_enter_serial(&client,enter_serial));
    assert(!wlr_seat_client_validate_pointer_enter_serial(&other,enter_serial));
    wlr_seat_pointer_send_button(seat,0,0x110,WL_POINTER_BUTTON_STATE_PRESSED);
    assert(button_serial && !wlr_seat_client_validate_pointer_enter_serial(&client,button_serial));
    assert(!wlr_seat_client_validate_pointer_enter_serial(&client,enter_serial+100));
    seat_client_destroy_pointer(wl_client_get_object(wl_client,4));
    assert(wlr_seat_client_from_pointer_resource(wl_client_get_object(wl_client,4))==NULL);
    wlr_seat_pointer_enter(seat,&a,30,30);
    assert(enters==5); // inert pointer gets neither event nor new ledger entry
    assert(wlr_seat_client_validate_pointer_enter_serial(&client,enter_serial));
    finish_client(&client); finish_client(&other);
    assert(!wlr_seat_client_validate_pointer_enter_serial(&client,enter_serial));
    // Client teardown normally makes remaining pointer resources inert first.
    seat_client_destroy_pointer(wl_client_get_object(wl_client,5));
    wl_client_destroy(wl_client); close(sockets[1]);
    wlr_seat_destroy(seat); wlr_seat_destroy(second);
    wl_protocol_logger_destroy(logger); wl_display_destroy(display);
    puts("PASS actual pointer handlers: focus/late binds, multiple resources, same-client surfaces, seat isolation, non-enter serials, inert resources and cleanup");
}
