#version 450

layout(set = 0, binding = 0) uniform sampler2D source_texture;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 output_color;

layout(push_constant) uniform PushConstants {
    vec4 blur_data;
} push_data;

void main() {
    vec2 offset = push_data.blur_data.xy * push_data.blur_data.z;
    output_color =
        texture(source_texture, uv) * 0.2270270270 +
        texture(source_texture, uv + offset * 1.3846153846) * 0.3162162162 +
        texture(source_texture, uv - offset * 1.3846153846) * 0.3162162162 +
        texture(source_texture, uv + offset * 3.2307692308) * 0.0702702703 +
        texture(source_texture, uv - offset * 3.2307692308) * 0.0702702703;
}
