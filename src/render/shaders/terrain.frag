#version 330 core

in vec2 v_uv;
in vec4 v_color;
in float v_eye_distance;

uniform sampler2D u_atlas;
uniform int u_textured;
uniform vec4 u_tint;
uniform int u_alpha_test;
uniform float u_alpha_cutoff;
uniform int u_fog_enabled;
uniform int u_fog_exponential;
uniform vec3 u_fog_color;
uniform float u_fog_start;
uniform float u_fog_end;
uniform float u_fog_density;

out vec4 frag_color;

void main() {
    frag_color = (u_textured != 0 ? texture(u_atlas, v_uv) * v_color : v_color) * u_tint;
    if (u_alpha_test != 0 && frag_color.a <= u_alpha_cutoff) discard;

    if (u_fog_enabled != 0) {
        float visibility = u_fog_exponential != 0
            ? exp(-u_fog_density * v_eye_distance)
            : (u_fog_end - v_eye_distance) / (u_fog_end - u_fog_start);
        frag_color.rgb = mix(u_fog_color, frag_color.rgb, clamp(visibility, 0.0, 1.0));
    }
}
