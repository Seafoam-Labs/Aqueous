#version 450

layout(set = 0, binding = 0) uniform sampler2D blurred_texture;

layout(push_constant) uniform PushConstants {
    vec4 box;
    vec4 radii;
    vec4 output_data;
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
    output_color = texture(blurred_texture, uv) * coverage;
}
