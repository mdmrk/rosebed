#version 330 core

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;

uniform mat4 u_view_proj;
uniform vec3 u_camera_pos;

out vec2 v_uv;
out vec4 v_color;
out float v_eye_distance;

void main() {
    gl_Position = u_view_proj * vec4(in_pos, 1.0);
    v_uv = in_uv;
    v_color = in_color;
    v_eye_distance = length(in_pos - u_camera_pos);
}
