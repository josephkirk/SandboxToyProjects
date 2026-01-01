#version 450

// Vertex shader output
layout(location = 0) out vec2 fragUV;

// Fullscreen triangle - no vertex buffer needed
void main() {
    // Generate UVs: (0,0), (2,0), (0,2) -> covers screen with one triangle
    fragUV = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(fragUV * 2.0 - 1.0, 0.0, 1.0);
}
