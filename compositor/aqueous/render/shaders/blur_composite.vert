#version 450

layout(push_constant) uniform PushConstants {
    vec4 box;
    vec4 radii;
    vec4 output_data;
    vec4 appearance_data;
    vec4 sample_bounds;
    vec4 texture_region;
} push_data;

layout(location = 0) out vec2 uv;
layout(location = 1) out vec2 local_position;

void main() {
    vec2 corner = vec2(
        float((gl_VertexIndex + 1) & 2) * 0.5,
        float(gl_VertexIndex & 2) * 0.5
    );
    vec2 position = push_data.box.xy + corner * push_data.box.zw;
    vec2 output_uv = position / push_data.output_data.xy;
    vec2 half_size = ceil(push_data.output_data.xy * 0.5);
    uv = (output_uv * half_size - push_data.texture_region.xy) / push_data.texture_region.zw;
    local_position = corner * push_data.box.zw;
    gl_Position = vec4(output_uv * 2.0 - 1.0, 0.0, 1.0);
}
