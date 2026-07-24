#version 450

layout(push_constant) uniform PushConstants {
    vec4 rect;
    vec4 color;
    vec4 outer_radii;
    vec4 inner_rect;
    vec4 inner_radii;
    vec4 output_data;
} push_data;

layout(location = 0) out vec2 local_position;

void main() {
    vec2 corner = vec2(
        float((gl_VertexIndex + 1) & 2) * 0.5,
        float(gl_VertexIndex & 2) * 0.5
    );
    vec2 position = push_data.rect.xy + corner * push_data.rect.zw;
    gl_Position = vec4(
        position / push_data.output_data.xy * 2.0 - 1.0,
        0.0,
        1.0
    );
    local_position = corner * push_data.rect.zw;
}
