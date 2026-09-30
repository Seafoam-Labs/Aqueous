// The pre-lookup encoder and pixel loop, kept only as a regression/benchmark
// oracle. Include after types/screencopy_sdr.h; never link into wlroots.
#ifndef SCREENCOPY_SDR_REFERENCE_H
#define SCREENCOPY_SDR_REFERENCE_H

static uint8_t reference_encode(float value) {
	return (uint8_t)lroundf(powf(fminf(fmaxf(value, 0.0f), 1.0f), 1.0f / 2.2f) * 255.0f);
}

static void reference_convert(const struct screencopy_sdr_conversion *conv,
		uint32_t format, const uint8_t *src, size_t src_stride,
		uint8_t *dst, size_t dst_stride, int width, int height) {
	bool bgr = format == DRM_FORMAT_XBGR2101010 || format == DRM_FORMAT_ABGR2101010;
	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			const uint8_t *s = src + (size_t)y * src_stride + (size_t)x * 4;
			uint8_t *d = dst + (size_t)y * dst_stride + (size_t)x * 4;
			uint32_t pixel = (uint32_t)s[0] | (uint32_t)s[1] << 8 |
				(uint32_t)s[2] << 16 | (uint32_t)s[3] << 24;
			uint32_t r = (pixel >> (bgr ? 0 : 20)) & 1023;
			uint32_t g = (pixel >> 10) & 1023;
			uint32_t b = (pixel >> (bgr ? 20 : 0)) & 1023;
			if (conv->pq) {
				float rgb[3] = {conv->linear[r], conv->linear[g], conv->linear[b]};
				for (size_t c = 0; c < 3; c++) {
					const float *m = &conv->matrix[c * 3];
					d[2 - c] = reference_encode(m[0] * rgb[0] + m[1] * rgb[1] + m[2] * rgb[2]);
				}
			} else {
				d[2] = (r * 255 + 511) / 1023;
				d[1] = (g * 255 + 511) / 1023;
				d[0] = (b * 255 + 511) / 1023;
			}
			d[3] = 255;
		}
	}
}

#endif
