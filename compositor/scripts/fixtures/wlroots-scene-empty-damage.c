// SPDX-License-Identifier: GPL-3.0-only
// Empty damage must not bypass buffer lifetime, texture, or geometry updates.
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <stdio.h>
#include <wayland-server-core.h>
#include <wlr/backend/headless.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/render/interface.h>
#include <wlr/types/wlr_scene.h>

static unsigned damage_calls, texture_destroys;
static void destroy_buffer(struct wlr_buffer *buffer) { (void)buffer; }
static const struct wlr_buffer_impl buffer_impl = {.destroy = destroy_buffer};
static void destroy_texture(struct wlr_texture *texture) {
    (void)texture;
    texture_destroys++;
}
static const struct wlr_texture_impl texture_impl = {.destroy = destroy_texture};
static void damaged(struct wlr_scene_node *node, const pixman_region32_t *damage, void *data) {
    (void)node; (void)data;
    assert(pixman_region32_not_empty(damage));
    damage_calls++;
}
static void reset_damage(struct wlr_scene_output *output) {
    damage_calls = 0;
    pixman_region32_clear(&output->WLR_PRIVATE.pending_commit_damage);
    pixman_region32_clear(&output->WLR_PRIVATE.pending_effect_damage);
}
int main(void) {
    struct wl_display *display = wl_display_create(); assert(display);
    struct wlr_backend *backend = wlr_headless_backend_create(wl_display_get_event_loop(display)); assert(backend);
    struct wlr_output *output = wlr_headless_add_output(backend, 100, 100); assert(output);
    output->enabled = true;
    struct wlr_scene *scene = wlr_scene_create(); assert(scene);
    struct wlr_scene_output *scene_output = wlr_scene_output_create(scene, output); assert(scene_output);
    wlr_scene_output_set_damage_hook(scene_output, damaged, NULL);
    struct wlr_buffer first, second, larger;
    wlr_buffer_init(&first, &buffer_impl, 64, 64);
    wlr_buffer_init(&second, &buffer_impl, 64, 64);
    wlr_buffer_init(&larger, &buffer_impl, 80, 80);
    struct wlr_scene_buffer *node = wlr_scene_buffer_create(&scene->tree, &first); assert(node);
    pixman_region32_t empty, small;
    pixman_region32_init(&empty);
    pixman_region32_init_rect(&small, 10, 11, 3, 4);
    struct wlr_scene_buffer_set_buffer_options options = {.damage = &empty};

    reset_damage(scene_output);
    // Use a synthetic cached texture to check invalidation without a GPU.
    struct wlr_texture texture = {.impl = &texture_impl};
    node->WLR_PRIVATE.texture = &texture;
    node->WLR_PRIVATE.wait_point = 17;
    wlr_scene_buffer_set_buffer_with_options(node, &second, &options);
    assert(node->buffer == &second && first.n_locks == 0 && second.n_locks == 1);
    assert(node->WLR_PRIVATE.texture == NULL && texture_destroys == 1);
    assert(node->WLR_PRIVATE.wait_point == 0);
    assert(damage_calls == 0 && !pixman_region32_not_empty(&scene_output->WLR_PRIVATE.pending_commit_damage));
    for (unsigned i = 0; i < 1000; i++) wlr_scene_buffer_set_buffer_with_options(node, &second, &options);
    assert(second.n_locks == 1 && damage_calls == 0);

    options.damage = &small;
    wlr_scene_buffer_set_buffer_with_options(node, &second, &options);
    assert(damage_calls > 0);
    assert(pixman_region32_equal(&scene_output->WLR_PRIVATE.pending_commit_damage, &small));
    assert(pixman_region32_equal(&scene_output->WLR_PRIVATE.pending_effect_damage, &small));

    // A missing region means full damage, not empty damage.
    reset_damage(scene_output);
    wlr_scene_buffer_set_buffer(node, &second);
    assert(damage_calls > 0);
    assert(pixman_region32_contains_point(&scene_output->WLR_PRIVATE.pending_commit_damage, 63, 63, NULL));

    reset_damage(scene_output);
    options.damage = &empty;
    wlr_scene_buffer_set_buffer_with_options(node, &larger, &options);
    assert(second.n_locks == 0 && larger.n_locks == 1);
    assert(damage_calls > 0);
    assert(pixman_region32_contains_point(&scene_output->WLR_PRIVATE.pending_commit_damage, 79, 79, NULL));

    reset_damage(scene_output);
    wlr_scene_buffer_set_buffer(node, NULL);
    assert(node->buffer == NULL && larger.n_locks == 0 && damage_calls > 0);
    reset_damage(scene_output);
    wlr_scene_buffer_set_buffer_with_options(node, &first, &options);
    assert(node->buffer == &first && first.n_locks == 1 && damage_calls > 0);

    pixman_region32_fini(&empty);
    pixman_region32_fini(&small);
    wlr_scene_node_destroy(&scene->tree.node);
    assert(first.n_locks == 0);
    wlr_buffer_drop(&first); wlr_buffer_drop(&second); wlr_buffer_drop(&larger);
    wlr_backend_destroy(backend);
    wl_display_destroy(display);
    puts("PASS empty damage: buffer replacement, texture invalidation, wait reset, real/full damage, resize and map/unmap");
}
