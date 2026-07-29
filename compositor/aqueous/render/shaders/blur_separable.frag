#version 450

layout(set = 0, binding = 0) uniform sampler2D source_texture;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 output_color;

layout(push_constant) uniform PushConstants {
    vec4 blur_data;
    vec4 sample_bounds;
} push_data;

// Keep each window's scene-prefix blur isolated without extending one edge
// texel into a kernel-width bar. The triangular fold also handles samples that
// travel farther than a narrow domain in a single pass.
float reflect_coordinate(float coordinate, float lower, float upper) {
    float span = upper - lower;
    if (!(span > 0.0)) {
        return lower;
    }

    float period = 2.0 * span;
    float phase = mod(coordinate - lower, period);
    float reflected = lower + min(phase, period - phase);
    return clamp(reflected, lower, upper);
}

vec2 reflect_sample_position(vec2 position) {
    return vec2(
        reflect_coordinate(
            position.x,
            push_data.sample_bounds.x,
            push_data.sample_bounds.z
        ),
        reflect_coordinate(
            position.y,
            push_data.sample_bounds.y,
            push_data.sample_bounds.w
        )
    );
}

vec4 sample_source(vec2 position) {
    return texture(source_texture, reflect_sample_position(position));
}

void main() {
    vec2 offset = push_data.blur_data.xy * push_data.blur_data.z;
    output_color =
        sample_source(uv) * 0.2270270270 +
        sample_source(uv + offset * 1.3846153846) * 0.3162162162 +
        sample_source(uv - offset * 1.3846153846) * 0.3162162162 +
        sample_source(uv + offset * 3.2307692308) * 0.0702702703 +
        sample_source(uv - offset * 3.2307692308) * 0.0702702703;
}
