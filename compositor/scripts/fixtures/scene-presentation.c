// Presentation moves pixels, visibility, damage and output membership. Picking
// remains at the logical layout origin. Exercise the real scene implementation.
#define WLR_PRIVATE
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <wayland-server-core.h>
#include <wlr/backend/headless.h>
#include <wlr/types/wlr_scene.h>

static bool contains(pixman_region32_t *region, int x, int y) {
    return pixman_region32_contains_point(region, x, y, NULL);
}

static unsigned enumerated;
static void count_buffer(struct wlr_scene_buffer *buffer, int x, int y, void *data) {
    assert(x == 330 && y == 30);
    enumerated++;
}

int main(void) {
    struct wl_display *display = wl_display_create();
    struct wlr_backend *backend = wlr_headless_backend_create(wl_display_get_event_loop(display));
    assert(backend);
    struct wlr_output *left = wlr_headless_add_output(backend, 300, 200);
    struct wlr_output *right = wlr_headless_add_output(backend, 300, 200);
    assert(left && right && wlr_backend_start(backend));
    struct wlr_output_state state;
    wlr_output_state_init(&state);
    wlr_output_state_set_enabled(&state, true);
    assert(wlr_output_commit_state(left, &state));
    assert(wlr_output_commit_state(right, &state));
    wlr_output_state_finish(&state);
    struct wlr_scene *scene = wlr_scene_create();
    struct wlr_scene_output *a = wlr_scene_output_create(scene, left);
    struct wlr_scene_output *b = wlr_scene_output_create(scene, right);
    assert(a && b);
    wlr_scene_output_set_position(b, 300, 0);
    struct wlr_scene_rect *background = wlr_scene_rect_create(&scene->tree, 600, 200,
        (float[]){0, 0, 0, 1});
    struct wlr_scene_tree *window = wlr_scene_tree_create(&scene->tree);
    struct wlr_scene_tree *child = wlr_scene_tree_create(window);
    struct wlr_scene_rect *rect = wlr_scene_rect_create(child, 100, 80,
        (float[]){1, 0, 0, 1});
    assert(background && window && child && rect);
    wlr_scene_node_set_position(&window->node, 20, 20);
    wlr_scene_node_set_position(&child->node, 10, 10);
    double x, y, sx, sy;
    assert(wlr_scene_node_at(&scene->tree.node, 35, 35, &sx, &sy) == &rect->node);
    assert(sx == 5 && sy == 5);
    assert(!contains(&background->node.visible, 35, 35));
    pixman_region32_clear(&a->damage_ring.current);
    pixman_region32_clear(&b->damage_ring.current);
    assert(wlr_scene_node_set_presentation(&window->node, 300, 0, NULL, true, NULL));
    assert(wlr_scene_node_presentation_coords(&rect->node, &x, &y) && x == 330 && y == 30);
    assert(wlr_scene_node_coords_f64(&rect->node, &x, &y) && x == 30 && y == 30);
    assert(contains(&background->node.visible, 35, 35));
    assert(!contains(&background->node.visible, 335, 35));
    assert(contains(&a->damage_ring.current, 35, 35));
    assert(contains(&b->damage_ring.current, 35, 35));
    assert(wlr_scene_node_at(&scene->tree.node, 35, 35, &sx, &sy) == &rect->node);
    assert(wlr_scene_node_at(&scene->tree.node, 335, 35, NULL, NULL) == &background->node);

    // A fixed visual clip does not change logical hit-testing or child origins.
    struct wlr_box clip = {350, 40, 20, 20};
    assert(wlr_scene_node_set_presentation(&window->node, 300, 0, &clip, true, NULL));
    assert(!contains(&rect->node.visible, 335, 35));
    assert(contains(&rect->node.visible, 355, 45));
    assert(contains(&background->node.visible, 335, 35));
    assert(wlr_scene_node_at(&scene->tree.node, 35, 35, NULL, NULL) == &rect->node);
    struct wlr_box input_clip = {40, 40, 20, 20};
    assert(wlr_scene_node_set_presentation(&window->node, 300, 0, &clip, true, &input_clip));
    assert(wlr_scene_node_at(&scene->tree.node, 35, 35, NULL, NULL) == &background->node);
    assert(wlr_scene_node_at(&child->node, 35, 35, NULL, NULL) == NULL);
    assert(wlr_scene_node_at(&child->node, 45, 45, NULL, NULL) == &rect->node);
    assert(wlr_scene_node_set_presentation(&window->node, 300, 0, &clip, false, NULL));
    assert(wlr_scene_node_at(&child->node, 45, 45, NULL, NULL) == NULL);
    assert(contains(&rect->node.visible, 355, 45));

    // Empty clips and moves entirely outside the old aperture clear visibility.
    struct wlr_box empty = {0};
    assert(wlr_scene_node_set_presentation(&window->node, 700, 0, &empty, true, NULL));
    assert(pixman_region32_empty(&rect->node.visible));
    assert(contains(&background->node.visible, 355, 45));
    assert(wlr_scene_node_set_presentation(&window->node, 300, 0, NULL, true, NULL));
    wlr_scene_node_set_enabled(&window->node, false);
    assert(pixman_region32_empty(&rect->node.visible));
    assert(wlr_scene_node_at(&child->node, 35, 35, NULL, NULL) == NULL);
    wlr_scene_node_set_enabled(&window->node, true);
    assert(contains(&rect->node.visible, 335, 35));

    // Output enumeration and membership must use presentation, even with no
    // buffer attached yet. A real surface follows this same scene buffer path.
    struct wlr_scene_buffer *buffer = wlr_scene_buffer_create(child, NULL);
    assert(buffer);
    wlr_scene_buffer_set_dest_size(buffer, 50, 50);
    assert(buffer->primary_output == b);
    wlr_scene_output_for_each_buffer(a, count_buffer, NULL);
    assert(enumerated == 0);
    wlr_scene_output_for_each_buffer(b, count_buffer, NULL);
    assert(enumerated == 1);
    assert(wlr_scene_node_set_presentation(&window->node, 300, 0, &empty, true, NULL));
    assert(buffer->primary_output == NULL && buffer->active_outputs == 0);
    wlr_scene_output_for_each_buffer(b, count_buffer, NULL);
    assert(enumerated == 1);

    // Nested precise transforms compose; reparenting and destruction own state.
    assert(wlr_scene_node_set_presentation(&window->node, 300.25, -0.5, NULL, true, NULL));
    assert(wlr_scene_node_set_presentation(&child->node, 0.5, 0.25, NULL, true, NULL));
    assert(wlr_scene_node_presentation_coords(&rect->node, &x, &y));
    assert(x == 330.75 && y == 29.75);
    struct wlr_scene_tree *disabled = wlr_scene_tree_create(&scene->tree);
    wlr_scene_node_set_enabled(&disabled->node, false);
    wlr_scene_node_reparent(&window->node, disabled);
    assert(buffer->primary_output == NULL && pixman_region32_empty(&rect->node.visible));
    wlr_scene_node_reparent(&window->node, &scene->tree);
    assert(buffer->primary_output == b);
    wlr_scene_node_destroy(&window->node);
    assert(contains(&background->node.visible, 335, 35));
    wlr_scene_node_destroy(&scene->tree.node);
    wlr_backend_destroy(backend);
    wl_display_destroy(display);
    puts("PASS: logical input, visual clipping/occlusion, old/new damage, output membership, nested transforms and lifetime");
}
