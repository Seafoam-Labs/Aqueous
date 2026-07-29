#version 450

layout(set = 0, binding = 0) uniform sampler2D source_texture;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 output_color;

layout(push_constant) uniform PushConstants {
    vec4 source_data;
    vec4 sample_bounds;
} push_data;

vec4 sample_source(vec2 position) {
    return texture(
        source_texture,
        clamp(position, push_data.sample_bounds.xy, push_data.sample_bounds.zw)
    );
}

void main() {
    vec2 texel = 1.0 / push_data.source_data.xy;
    output_color = (
        sample_source(uv + texel * vec2(-0.5, -0.5)) +
        sample_source(uv + texel * vec2(0.5, -0.5)) +
        sample_source(uv + texel * vec2(-0.5, 0.5)) +
        sample_source(uv + texel * vec2(0.5, 0.5))
    ) * 0.25;
}
