const Shader = @import("shader.zig");

pub const vertex_source = @embedFile("shaders/hud_solid.vert");
pub const fragment_source = @embedFile("shaders/hud_solid.frag");

pub fn init() !Shader {
    return Shader.init(vertex_source, fragment_source);
}
