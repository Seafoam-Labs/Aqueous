#version 450

layout(push_constant) uniform PushConstants {
    vec4 rect;
    vec4 color;
    vec4 outer_radii;
    vec4 inner_rect;
    vec4 inner_radii;
    vec4 output_data;
} push_data;

layout(location = 0) in vec2 local_position;
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

float coverage(float signed_distance) {
    float antialias_width = max(fwidth(signed_distance), 0.0001);
    return 1.0 - smoothstep(
        -antialias_width,
        antialias_width,
        signed_distance
    );
}

void main() {
    float outer = coverage(rounded_box_distance(
        local_position,
        push_data.rect.zw,
        push_data.outer_radii
    ));
    float inner = 0.0;
    if (push_data.output_data.z > 0.5) {
        inner = coverage(rounded_box_distance(
            local_position - push_data.inner_rect.xy,
            push_data.inner_rect.zw,
            push_data.inner_radii
        ));
    }
    output_color = push_data.color * (outer * (1.0 - inner));
}
