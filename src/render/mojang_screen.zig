const gl = @import("gl");

const Atlas = @import("atlas.zig");
const MeshBuilder = @import("mesh_builder.zig");
const gui = @import("gui.zig");

pub const logo_size: f32 = 256;
pub const hold_ms: u64 = 1000;
const texture_size: f32 = 128;
const corner_texel: Atlas.Uv = .{ .u0 = 0.5 / texture_size, .v0 = 0.5 / texture_size, .u1 = 0.5 / texture_size, .v1 = 0.5 / texture_size };
const full_texture: Atlas.Uv = .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 };

pub fn draw(ui: gui.Ui) !void {
    gl.Disable(gl.DEPTH_TEST);

    var mesh: MeshBuilder = .{};
    defer mesh.deinit(ui.gpa);

    try gui.appendRect(&mesh, ui.gpa, 0, 0, ui.res.width, ui.res.height, corner_texel, ui.res);
    const x = @floor((ui.res.width - logo_size) / 2.0);
    const y = @floor((ui.res.height - logo_size) / 2.0);
    try gui.appendRect(&mesh, ui.gpa, x, y, logo_size, logo_size, full_texture, ui.res);
    try gui.drawTexturedMesh(&mesh, ui.shader, ui.textures.mojang);

    gl.Enable(gl.DEPTH_TEST);
}
