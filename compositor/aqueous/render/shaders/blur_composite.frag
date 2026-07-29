#version 450

layout(set = 0, binding = 0) uniform sampler2D blurred_texture;

layout(push_constant) uniform PushConstants {
    vec4 box;
    vec4 radii;
    vec4 output_data;
    vec4 appearance_data;
    vec4 sample_bounds;
} push_data;

layout(location = 0) in vec2 uv;
layout(location = 1) in vec2 local_position;
layout(location = 0) out vec4 output_color;

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

vec3 gain(vec3 source, float exponent) {
    vec3 value = clamp(source, vec3(0.0), vec3(1.0));
    vec3 upper_half = step(vec3(0.5), value);
    vec3 mirrored = mix(value, vec3(1.0) - value, upper_half);
    vec3 adjusted = vec3(0.5) * pow(vec3(2.0) * mirrored, vec3(exponent));
    return mix(adjusted, vec3(1.0) - adjusted, upper_half);
}

float stable_noise(vec2 position) {
    vec3 value = fract(vec3(position.xyx) * 0.1031);
    value += dot(value, value.yzx + 33.33);
    return fract((value.x + value.y) * value.z) - 0.5;
}

vec3 apply_vibrancy(vec3 source, float amount, float darkness) {
    const vec3 luminance_weights = vec3(0.299, 0.587, 0.114);
    float luminance = dot(source, luminance_weights);
    float maximum = max(max(source.r, source.g), source.b);
    float minimum = min(min(source.r, source.g), source.b);
    float saturation = maximum > 0.0001
        ? clamp((maximum - minimum) / maximum, 0.0, 1.0)
        : 0.0;
    float dark_weight = mix(
        smoothstep(0.0, 0.5, clamp(luminance, 0.0, 1.0)),
        1.0,
        darkness
    );
    float boost = amount * dark_weight * (1.0 - saturation);
    return mix(vec3(luminance), source, 1.0 + boost);
}

void main() {
    float signed_distance = rounded_box_distance(
        local_position,
        push_data.box.zw,
        push_data.radii
    );
    float antialias_width = max(fwidth(signed_distance), 0.0001);
    float coverage = 1.0 - smoothstep(
        -antialias_width,
        antialias_width,
        signed_distance
    );
    vec4 color = texture(
        blurred_texture,
        clamp(uv, push_data.sample_bounds.xy, push_data.sample_bounds.zw)
    );
    float contrast = push_data.appearance_data.x;
    float brightness = push_data.appearance_data.y;
    float vibrancy = push_data.appearance_data.z;
    float vibrancy_darkness = push_data.appearance_data.w;
    if (contrast != 1.0) {
        color.rgb = gain(color.rgb, contrast);
    }
    if (vibrancy > 0.0) {
        color.rgb = apply_vibrancy(
            color.rgb,
            vibrancy,
            vibrancy_darkness
        );
    }
    if (push_data.output_data.z > 0.0) {
        color.rgb += vec3(stable_noise(uv) * push_data.output_data.z);
    }
    if (brightness != 1.0) {
        color.rgb *= brightness;
    }
    output_color = color * coverage;
}
