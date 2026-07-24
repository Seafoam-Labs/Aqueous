#version 450

layout(push_constant, row_major) uniform PushConstants {
    mat4 projection;
    vec2 uv_offset;
    vec2 uv_size;
} push_data;

layout(location = 0) out vec2 uv;
layout(location = 1) out vec2 local_position;

void main() {
    vec2 position = vec2(
        float((gl_VertexIndex + 1) & 2) * 0.5,
        float(gl_VertexIndex & 2) * 0.5
    );
    uv = push_data.uv_offset + position * push_data.uv_size;
    local_position = position;
    gl_Position = push_data.projection * vec4(position, 0.0, 1.0);
}
