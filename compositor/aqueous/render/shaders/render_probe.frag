#version 450

layout(push_constant) uniform PushConstants {
    vec4 rect;
    vec4 color;
    vec4 output_radius;
} push_data;

layout(location = 0) in vec2 local_position;
layout(location = 0) out vec4 output_color;

void main() {
    vec2 half_size = push_data.rect.zw * 0.5;
    float radius = min(push_data.output_radius.z, min(half_size.x, half_size.y));
    vec2 distance_vector = abs(local_position - half_size) - (half_size - vec2(radius));
    float signed_distance =
        length(max(distance_vector, vec2(0.0))) +
        min(max(distance_vector.x, distance_vector.y), 0.0) -
        radius;
    float coverage = 1.0 - smoothstep(-fwidth(signed_distance), fwidth(signed_distance), signed_distance);
    output_color = vec4(push_data.color.rgb * coverage, push_data.color.a * coverage);
}
