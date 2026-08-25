#define WLR_USE_UNSTABLE

#include <math.h>
#include <stdio.h>
#include <wlr/types/wlr_scene.h>

static int close_enough(double actual, double expected) {
	return fabs(actual - expected) < 0.000001;
}

int main(void) {
	struct wlr_scene *scene = wlr_scene_create();
	if (scene == NULL) {
		fprintf(stderr, "unable to create scene\n");
		return 1;
	}
	struct wlr_scene_tree *parent = wlr_scene_tree_create(&scene->tree);
	struct wlr_scene_tree *child = parent == NULL ? NULL :
		wlr_scene_tree_create(parent);
	if (child == NULL) {
		fprintf(stderr, "unable to create scene trees\n");
		wlr_scene_node_destroy(&scene->tree.node);
		return 1;
	}

	wlr_scene_node_set_position_f64(&parent->node, 0.8, 1.6);
	wlr_scene_node_set_position_f64(&child->node, 1.6, 2.4);
	double x, y;
	if (!wlr_scene_node_coords_f64(&child->node, &x, &y) ||
			!close_enough(x, 2.4) || !close_enough(y, 4.0)) {
		fprintf(stderr, "precise coordinates were lost: %.8f, %.8f\n", x, y);
		wlr_scene_node_destroy(&scene->tree.node);
		return 1;
	}

	/* The legacy setter must discard a node's precise addon. */
	wlr_scene_node_set_position(&child->node, 2, 3);
	if (!wlr_scene_node_coords_f64(&child->node, &x, &y) ||
			!close_enough(x, 2.8) || !close_enough(y, 4.6)) {
		fprintf(stderr, "integer compatibility reset failed: %.8f, %.8f\n", x, y);
		wlr_scene_node_destroy(&scene->tree.node);
		return 1;
	}

	wlr_scene_node_destroy(&scene->tree.node);
	return 0;
}
