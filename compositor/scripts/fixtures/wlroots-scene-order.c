// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <assert.h>
#include <wlr/types/wlr_scene.h>

int main(void) {
	struct wlr_scene *scene = wlr_scene_create();
	assert(scene != NULL);

	const float color[4] = {0};
	struct wlr_scene_rect *backdrop =
		wlr_scene_rect_create(&scene->tree, 1, 1, color);
	struct wlr_scene_rect *marker =
		wlr_scene_rect_create(&scene->tree, 1, 1, color);
	struct wlr_scene_tree *surface_tree =
		wlr_scene_tree_create(&scene->tree);
	struct wlr_scene_rect *surface =
		wlr_scene_rect_create(surface_tree, 1, 1, color);
	assert(backdrop != NULL && marker != NULL && surface_tree != NULL &&
		surface != NULL);

	assert(wlr_scene_node_render_order(
		&backdrop->node, &marker->node) == -1);
	assert(wlr_scene_node_render_order(
		&marker->node, &backdrop->node) == 1);
	assert(wlr_scene_node_render_order(
		&surface->node, &marker->node) == 1);
	assert(wlr_scene_node_render_order(
		&marker->node, &surface->node) == -1);
	assert(wlr_scene_node_render_order(
		&marker->node, &marker->node) == 0);

	wlr_scene_node_destroy(&scene->tree.node);
	return 0;
}
