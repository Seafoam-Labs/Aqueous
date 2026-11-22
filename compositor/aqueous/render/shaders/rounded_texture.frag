#version 450

layout(set = 0, binding = 0) uniform sampler2D source_texture;

layout(location = 0) in vec2 uv;
layout(location = 1) in vec2 local_position;
layout(location = 0) out vec4 output_color;

layout(push_constant) uniform PushConstants {
    layout(offset = 80) vec4 color_rows[4];
    float alpha;
    float luminance_multiplier;
    float itm_peak;
    float itm_boost;
} push_data;

layout(constant_id = 0) const int TEXTURE_TRANSFORM = 0;

const int TEXTURE_TRANSFORM_IDENTITY = 0;
const int TEXTURE_TRANSFORM_SRGB = 1;
const int TEXTURE_TRANSFORM_ST2084_PQ = 2;
const int TEXTURE_TRANSFORM_GAMMA22 = 3;
const int TEXTURE_TRANSFORM_BT1886 = 4;

float srgb_channel_to_linear(float value) {
    return mix(
        value / 12.92,
        pow((value + 0.055) / 1.055, 2.4),
        value > 0.04045
    );
}

vec3 srgb_color_to_linear(vec3 color) {
    return vec3(
        srgb_channel_to_linear(color.r),
        srgb_channel_to_linear(color.g),
        srgb_channel_to_linear(color.b)
    );
}

vec3 pq_color_to_linear(vec3 color) {
    const float inverse_m1 = 1.0 / 0.1593017578125;
    const float inverse_m2 = 1.0 / 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;
    vec3 powered = pow(color, vec3(inverse_m2));
    vec3 numerator = max(powered - c1, 0.0);
    vec3 denominator = c2 - c3 * powered;
    return pow(numerator / denominator, vec3(inverse_m1));
}

vec3 bt1886_color_to_linear(vec3 color) {
    const float minimum_luminance = 0.01;
    const float maximum_luminance = 100.0;
    float black = pow(minimum_luminance, 1.0 / 2.4);
    float white = pow(maximum_luminance, 1.0 / 2.4);
    float scale = pow(white - black, 2.4);
    float offset = black / (white - black);
    vec3 luminance = scale * pow(color + vec3(offset), vec3(2.4));
    return (luminance - minimum_luminance) /
        (maximum_luminance - minimum_luminance);
}

float rounded_box_distance(vec2 position, vec2 size, vec4 radii) {
    vec2 half_size = size * 0.5;
    bool left = position.x < half_size.x;
    bool top = position.y < half_size.y;
    float radius = top
        ? (left ? radii.x : radii.y)
        : (left ? radii.w : radii.z);
    vec2 distance_vector =
        abs(position - half_size) - (half_size - vec2(radius));
    return length(max(distance_vector, vec2(0.0))) +
        min(max(distance_vector.x, distance_vector.y), 0.0) -
        radius;
}

vec3 transfer_to_linear(vec3 rgb) {
    if (TEXTURE_TRANSFORM != TEXTURE_TRANSFORM_IDENTITY) {
        rgb = max(rgb, vec3(0.0));
    }
    if (TEXTURE_TRANSFORM == TEXTURE_TRANSFORM_SRGB) {
        return srgb_color_to_linear(rgb);
    } else if (TEXTURE_TRANSFORM == TEXTURE_TRANSFORM_ST2084_PQ) {
        return pq_color_to_linear(rgb);
    } else if (TEXTURE_TRANSFORM == TEXTURE_TRANSFORM_GAMMA22) {
        return pow(rgb, vec3(2.2));
    } else if (TEXTURE_TRANSFORM == TEXTURE_TRANSFORM_BT1886) {
        return bt1886_color_to_linear(rgb);
    }
    return rgb;
}

// One source tap un-premultiplied and converted to linear light, then
// re-premultiplied. Averaging these in the area path filters in linear light
// (the same reason Mutter samples YUV in premultiplied-electrical space), so
// downscaled text and edges do not pick up gamma-space halos.
vec4 fetch_linear_premult(vec2 coord) {
    vec4 sampled = textureLod(source_texture, coord, 0.0);
    float a = sampled.a;
    vec3 rgb = a == 0.0 ? vec3(0.0) : sampled.rgb / a;
    rgb = transfer_to_linear(rgb);
    return vec4(rgb * a, a);
}

void main() {
    // color_rows[3].z carries the area-downscale flag (see RoundedPipeline).
    // When set, integrate a box of source texels covering this output pixel's
    // footprint instead of a single bilinear tap. This is the high-quality
    // resampling path for mismatched-scale surfaces (e.g. an integer-buffer
    // GTK3 client on a fractional output); the footprint is derived from the
    // per-pixel UV derivative and the source texture size, so no extra push
    // constants are needed. Tap counts are capped to bound fragment cost.
    vec4 linear_sample;
    if (push_data.color_rows[3].z > 0.5) {
        vec2 tex_size = vec2(textureSize(source_texture, 0));
        vec2 footprint = fwidth(uv) * tex_size;
        vec2 center = uv * tex_size;
        int nx = int(clamp(ceil(footprint.x), 1.0, 4.0));
        int ny = int(clamp(ceil(footprint.y), 1.0, 4.0));
        vec4 acc = vec4(0.0);
        for (int j = 0; j < ny; j++) {
            for (int i = 0; i < nx; i++) {
                vec2 t = (vec2(float(i) + 0.5, float(j) + 0.5) /
                    vec2(float(nx), float(ny))) - 0.5;
                vec2 coord = (center + t * footprint) / tex_size;
                acc += fetch_linear_premult(coord);
            }
        }
        linear_sample = acc / float(nx * ny);
    } else {
        linear_sample = fetch_linear_premult(uv);
    }

    float source_alpha = linear_sample.a;
    vec3 rgb = source_alpha == 0.0
        ? vec3(0.0)
        : linear_sample.rgb / source_alpha;

    rgb *= push_data.luminance_multiplier;
    rgb = vec3(
        dot(push_data.color_rows[0].xyz, rgb),
        dot(push_data.color_rows[1].xyz, rgb),
        dot(push_data.color_rows[2].xyz, rgb)
    );

    // Auto HDR expansion: lift SDR highlights toward the configured HDR
    // peak. The luminance multiplier above already places SDR diffuse white
    // (patched wlroots sdr_white_level), so the curve is expressed relative to
    // it: identity at and below the knee, rising gain near white, and a
    // hard clamp at the peak so content never exceeds the advertised level.
    // Mirrors aqueous/auto_hdr.zig.
    if (push_data.itm_peak > 0.0) {
        float white = max(push_data.luminance_multiplier, 1.0e-4);
        float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
        float x = luma / white;
        float mask = smoothstep(0.8, 1.0, x);
        float peak_rel = max(push_data.itm_peak / white, 1.0);
        float gain = 1.0 + push_data.itm_boost * (peak_rel - 1.0) * mask;
        rgb *= gain;
        float expanded_luma = luma * gain;
        if (expanded_luma > push_data.itm_peak) {
            rgb *= push_data.itm_peak / expanded_luma;
        }
    }

    vec2 size = vec2(
        push_data.color_rows[0].w,
        push_data.color_rows[1].w
    );
    // A negative width means no mask (e.g. an Auto-HDR-only draw). A present
    // zero-radius mask still clips to its rectangle. The mask belongs to the
    // window, not to this texture's extent or buffer transform.
    float coverage = 1.0;
    if (size.x >= 0.0) {
        float signed_distance = rounded_box_distance(
            gl_FragCoord.xy - push_data.color_rows[3].xy,
            size,
            vec4(push_data.color_rows[2].w)
        );
        float antialias_width = max(fwidth(signed_distance), 0.0001);
        coverage = size.x <= 0.0 || size.y <= 0.0 ? 0.0 :
            1.0 - smoothstep(-antialias_width, antialias_width, signed_distance);
    }

    output_color = vec4(rgb * source_alpha, source_alpha);
    output_color *= push_data.alpha * coverage;
}
