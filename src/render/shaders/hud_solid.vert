#version 330 core

layout(location = 0) in vec3 in_pos;
layout(location = 2) in vec4 in_color;

out vec4 v_color;

void main() {
    gl_Position = vec4(in_pos, 1.0);
    v_color = in_color;
}
