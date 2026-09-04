const std = @import("std");

const Atlas = @import("Atlas.zig");
const overlay = @import("overlay.zig");
const Shader = @import("Shader.zig");

const tiles: f32 = 4.0;
const drift: f32 = 64.0;
const alpha: u8 = 128;

pub fn draw(
    gpa: std.mem.Allocator,
    shader: Shader,
    texture: Atlas,
    yaw: f32,
    pitch: f32,
    brightness: f32,
) !void {
    const u = -yaw / drift;
    const v = pitch / drift;
    const level: u8 = @intFromFloat(std.math.clamp(brightness, 0.0, 1.0) * 255.0);

    try overlay.drawQuad(gpa, shader, texture, .{
        .{ tiles + u, tiles + v },
        .{ u, tiles + v },
        .{ u, v },
        .{ tiles + u, v },
    }, .{ level, level, level, alpha }, true);
}
