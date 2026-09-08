const std = @import("std");

const Atlas = @import("Atlas.zig");
const overlay = @import("overlay.zig");
const Shader = @import("Shader.zig");
const TextureFx = @import("TextureFx.zig");

pub fn draw(gpa: std.mem.Allocator, shader: Shader, terrain: Atlas, progress: f32) !void {
    var strength = progress;
    if (strength < 1.0) {
        strength *= strength;
        strength *= strength;
        strength = strength * 0.8 + 0.2;
    }

    const uv = Atlas.tileUv(TextureFx.portal_tile);
    try overlay.drawQuad(gpa, shader, terrain, .{
        .{ uv.u0, uv.v1 },
        .{ uv.u1, uv.v1 },
        .{ uv.u1, uv.v0 },
        .{ uv.u0, uv.v0 },
    }, .{ 255, 255, 255, @intFromFloat(std.math.clamp(strength, 0.0, 1.0) * 255.0) }, false);
}
