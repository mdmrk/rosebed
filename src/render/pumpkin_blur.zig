const std = @import("std");

const gl = @import("gl");

const Atlas = @import("Atlas.zig");
const GpuMesh = @import("GpuMesh.zig");
const MeshBuilder = @import("MeshBuilder.zig");
const Shader = @import("Shader.zig");

const identity: [16]f32 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

pub fn draw(gpa: std.mem.Allocator, shader: Shader, texture: Atlas) !void {
    var mesh: MeshBuilder = .{};
    defer mesh.deinit(gpa);
    try mesh.quad(gpa, .{
        .{ -1, -1, 0 },
        .{ 1, -1, 0 },
        .{ 1, 1, 0 },
        .{ -1, 1, 0 },
    }, .{
        .{ 0, 1 },
        .{ 1, 1 },
        .{ 1, 0 },
        .{ 0, 0 },
    }, .{ 255, 255, 255, 255 });

    var gpu = GpuMesh.upload(&mesh);
    defer gpu.deinit();

    gl.Disable(gl.DEPTH_TEST);
    gl.DepthMask(gl.FALSE);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    shader.use();
    gl.ActiveTexture(gl.TEXTURE0);
    texture.bind();
    shader.setInt(.u_atlas, 0);
    shader.setInt(.u_fog_enabled, 0);
    shader.setInt(.u_alpha_test, 0);
    shader.setInt(.u_textured, 1);
    shader.setVec4(.u_tint, .{ 1, 1, 1, 1 });
    shader.setMat4(.u_view_proj, identity);
    gpu.draw();

    gl.Disable(gl.BLEND);
    gl.DepthMask(gl.TRUE);
    gl.Enable(gl.DEPTH_TEST);
}
