// SPDX-FileCopyrightText: © 2026 Seafoam Labs
// SPDX-License-Identifier: GPL-3.0-only

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <X11/Xcursor/Xcursor.h>

static const unsigned int sizes[] = {12, 18, 24, 30, 36, 42, 48, 60, 72};
#define IMAGE_COUNT (sizeof(sizes) / sizeof(sizes[0]))

int main(int argc, char **argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: %s OUTPUT\n", argv[0]);
		return EXIT_FAILURE;
	}

	XcursorImages *images = XcursorImagesCreate(IMAGE_COUNT);
	if (images == NULL) {
		fprintf(stderr, "failed to allocate XCursor image set\n");
		return EXIT_FAILURE;
	}

	for (unsigned int i = 0; i < IMAGE_COUNT; i++) {
		const unsigned int size = sizes[i];
		XcursorImage *image = XcursorImageCreate(size, size);
		if (image == NULL) {
			fprintf(stderr, "failed to allocate %ux%u XCursor image\n", size, size);
			XcursorImagesDestroy(images);
			return EXIT_FAILURE;
		}

		image->size = size;
		image->xhot = size / 2;
		image->yhot = size / 2;
		image->delay = 0;
		for (unsigned int pixel = 0; pixel < size * size; pixel++) {
			image->pixels[pixel] = UINT32_C(0xFFFFFFFF);
		}
		images->images[images->nimage++] = image;
	}

	const XcursorBool saved = XcursorFilenameSaveImages(argv[1], images);
	XcursorImagesDestroy(images);
	if (!saved) {
		fprintf(stderr, "failed to write XCursor theme to %s\n", argv[1]);
		return EXIT_FAILURE;
	}

	for (unsigned int i = 0; i < IMAGE_COUNT; i++) {
		XcursorImages *loaded = XcursorFilenameLoadImages(argv[1], sizes[i]);
		if (loaded == NULL || loaded->nimage != 1 ||
				loaded->images[0]->width != sizes[i] ||
				loaded->images[0]->height != sizes[i]) {
			fprintf(stderr,
				"could not reload the %ux%u XCursor image (count=%d, dimensions=%ux%u)\n",
				sizes[i], sizes[i], loaded == NULL ? 0 : loaded->nimage,
				loaded == NULL ? 0 : loaded->images[0]->width,
				loaded == NULL ? 0 : loaded->images[0]->height);
			if (loaded != NULL) {
				XcursorImagesDestroy(loaded);
			}
			return EXIT_FAILURE;
		}
		XcursorImagesDestroy(loaded);
	}
	return EXIT_SUCCESS;
}
