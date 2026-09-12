#ifndef CAPTURE_PATTERN_H
#define CAPTURE_PATTERN_H
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
// A5 magic + 24-bit frame number, repeated in every row in 4-pixel cells.
// Body tiles change independently; pixel values avoid fragile color matching.
static inline uint32_t pattern_pixel(unsigned frame, int x, int y, int width, bool sparse) {
    unsigned v;
    if (x < 128) {
        uint32_t code = 0xa5000000u | (frame & 0xffffffu);
        v = (code >> (31 - x / 4)) & 1;
    } else {
        int tile = (x - 128) * 8 / (width - 128);
        unsigned generation = sparse ? (frame + 7 - tile) / 8 : frame;
        v = ((unsigned)(x / 8 + y / 8) ^ generation) & 1;
    }
    return v ? 0xffeeeeeeu : 0xff101010u;
}
static inline uint32_t pattern_row(const uint32_t *p) {
    uint32_t code = 0;
    for (int bit = 0; bit < 32; bit++)
        code = (code << 1) | ((p[bit * 4 + 2] & 255) > 127);
    return code;
}
struct pattern_result {
    unsigned frame, bad_rows, bad_pixels, missing_rows;
};
static inline struct pattern_result pattern_check(const uint32_t *p, int width, int height,
                                                  bool sparse) {
    struct pattern_result r = {0};
    if (width < 256 || height < 1) {
        r.missing_rows = 1;
        return r;
    }
    r.frame = pattern_row(p) & 0xffffffu;
    for (int y = 0; y < height; y++) {
        uint32_t code = pattern_row(p + (size_t)y * width);
        if ((code >> 24) != 0xa5) {
            r.missing_rows++;
            continue;
        }
        if ((code & 0xffffffu) != r.frame)
            r.bad_rows++;
        for (int x = 128; x < width; x++) {
            uint32_t expected = pattern_pixel(r.frame, x, y, width, sparse);
            uint32_t actual = p[(size_t)y * width + x];
            // Test luminance class, not exact RGB, to tolerate color conversion.
            if (((actual & 255) > 127) != ((expected & 255) > 127))
                r.bad_pixels++;
        }
    }
    return r;
}
#endif
