const std = @import("std");
const builtin = @import("builtin");

const Shader = @import("shader.zig");

fn retarget(comptime source: []const u8, comptime header: []const u8) [:0]const u8 {
    const body = source[std.mem.indexOfScalar(u8, source, '\n').? + 1 ..];
    return std.fmt.comptimePrint("{s}{s}", .{ header, body });
}

const gles = builtin.os.tag == .emscripten;

pub const vertex_source = retarget(
    @embedFile("shaders/terrain.vert"),
    if (gles) "#version 300 es\n" else "#version 330 core\n",
);
pub const fragment_source = retarget(
    @embedFile("shaders/terrain.frag"),
    if (gles) "#version 300 es\nprecision highp float;\nprecision highp sampler2D;\n" else "#version 330 core\n",
);

pub fn init() !Shader {
    return Shader.init(vertex_source, fragment_source);
}
