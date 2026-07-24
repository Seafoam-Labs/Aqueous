#version 450

layout(set = 0, binding = 0) uniform sampler2D source_texture;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 output_color;

layout(push_constant) uniform PushConstants {
    vec4 source_data;
} push_data;

void main() {
    vec2 texel = 1.0 / push_data.source_data.xy;
    output_color = (
        texture(source_texture, uv + texel * vec2(-0.5, -0.5)) +
        texture(source_texture, uv + texel * vec2(0.5, -0.5)) +
        texture(source_texture, uv + texel * vec2(-0.5, 0.5)) +
        texture(source_texture, uv + texel * vec2(0.5, 0.5))
    ) * 0.25;
}
