const Shader = @import("shader.zig");

pub const vertex_source = @embedFile("shaders/terrain.vert");
pub const fragment_source = @embedFile("shaders/terrain.frag");

pub fn init() !Shader {
    return Shader.init(vertex_source, fragment_source);
}
