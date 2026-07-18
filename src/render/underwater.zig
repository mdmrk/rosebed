const std = @import("std");

const gl = @import("gl");

const Atlas = @import("atlas.zig");
const GpuMesh = @import("gpu_mesh.zig");
const MeshBuilder = @import("mesh_builder.zig");
const Shader = @import("shader.zig");

const identity: [16]f32 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

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

    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    try mesh.quad(gpa, .{
        .{ -1, -1, 0 },
        .{ 1, -1, 0 },
        .{ 1, 1, 0 },
        .{ -1, 1, 0 },
    }, .{
        .{ tiles + u, tiles + v },
        .{ u, tiles + v },
        .{ u, v },
        .{ tiles + u, v },
    }, .{ level, level, level, alpha });

    var gpu = GpuMesh.upload(&mesh);
    defer gpu.deinit();

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    shader.use();
    gl.ActiveTexture(gl.TEXTURE0);
    texture.bind();
    shader.setInt("u_atlas", 0);
    shader.setInt("u_fog_enabled", 0);
    shader.setInt("u_alpha_test", 0);
    shader.setInt("u_textured", 1);
    shader.setVec4("u_tint", .{ 1, 1, 1, 1 });
    shader.setMat4("u_view_proj", identity);
    gpu.draw();

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}
