#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "pattern.h"
int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--self-test"))
        return 2;
    enum { W = 640, H = 360 };
    uint32_t *p = malloc(W * H * 4);
    if (!p)
        return 1;
    for (int sparse = 0; sparse < 2; sparse++) {
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                p[y * W + x] = pattern_pixel(123, x, y, W, sparse);
        struct pattern_result r = pattern_check(p, W, H, sparse);
        if (r.frame != 123 || r.bad_pixels || r.bad_rows || r.missing_rows)
            return 1;
        for (int x = 0; x < 128; x++)
            p[H / 2 * W + x] = pattern_pixel(122, x, H / 2, W, sparse);
        if (!pattern_check(p, W, H, sparse).bad_rows)
            return 1;
        for (int x = 0; x < 128; x++)
            p[H / 2 * W + x] = pattern_pixel(123, x, H / 2, W, sparse);
        p[W + 200] ^= 0x00ffffff;
        if (!pattern_check(p, W, H, sparse).bad_pixels)
            return 1;
        memset(p, 0, W * H * 4);
        if (!pattern_check(p, W, H, sparse).missing_rows)
            return 1;
    }
    free(p);
    puts("PASS clean, mixed rows, stale pixels, and missing content");
    return 0;
}
