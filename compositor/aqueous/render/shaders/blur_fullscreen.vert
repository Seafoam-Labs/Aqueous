#version 450

layout(location = 0) out vec2 uv;

void main() {
    vec2 position = vec2(
        float((gl_VertexIndex + 1) & 2) * 0.5,
        float(gl_VertexIndex & 2) * 0.5
    );
    uv = position;
    gl_Position = vec4(position * 2.0 - 1.0, 0.0, 1.0);
}
