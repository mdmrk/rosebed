const std = @import("std");

const Atlas = @import("Atlas.zig");
const overlay = @import("overlay.zig");
const Shader = @import("Shader.zig");

pub fn draw(gpa: std.mem.Allocator, shader: Shader, texture: Atlas) !void {
    try overlay.drawQuad(gpa, shader, texture, .{
        .{ 0, 1 },
        .{ 1, 1 },
        .{ 1, 0 },
        .{ 0, 0 },
    }, .{ 255, 255, 255, 255 }, false);
}
