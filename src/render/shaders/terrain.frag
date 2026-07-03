#version 330 core

in vec2 v_uv;
in vec4 v_color;
in float v_eye_distance;

uniform sampler2D u_atlas;
uniform int u_fog_enabled;
uniform vec3 u_fog_color;
uniform float u_fog_start;
uniform float u_fog_end;

out vec4 frag_color;

void main() {
    frag_color = texture(u_atlas, v_uv) * v_color;
    if (frag_color.a < 0.5) discard;

    if (u_fog_enabled != 0) {
        float visibility = clamp((u_fog_end - v_eye_distance) / (u_fog_end - u_fog_start), 0.0, 1.0);
        frag_color.rgb = mix(u_fog_color, frag_color.rgb, visibility);
    }
}
