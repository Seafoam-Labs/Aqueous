#version 450

layout(push_constant) uniform PushConstants {
    vec4 rect;
    vec4 color;
    vec4 output_radius;
} push_data;

layout(location = 0) out vec2 local_position;

const vec2 corners[4] = vec2[](
    vec2(0.0, 0.0),
    vec2(1.0, 0.0),
    vec2(0.0, 1.0),
    vec2(1.0, 1.0)
);

void main() {
    vec2 corner = corners[gl_VertexIndex];
    vec2 position = push_data.rect.xy + corner * push_data.rect.zw;
    vec2 output_size = push_data.output_radius.xy;
    gl_Position = vec4(position / output_size * 2.0 - 1.0, 0.0, 1.0);
    local_position = corner * push_data.rect.zw;
}
