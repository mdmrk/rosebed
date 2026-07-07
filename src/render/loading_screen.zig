const gl = @import("gl");

const Atlas = @import("atlas.zig");
const MeshBuilder = @import("mesh_builder.zig");
const gui = @import("gui.zig");

const dirt_tile_scale: f32 = 32;
const dirt_tint: [4]u8 = .{ 64, 64, 64, 255 };
const text_color: [4]u8 = .{ 255, 255, 255, 255 };
const bar_background: [4]u8 = .{ 128, 128, 128, 255 };
const bar_fill: [4]u8 = .{ 128, 255, 128, 255 };

pub const bar_width: f32 = 100;
pub const bar_height: f32 = 2;

pub fn draw(ui: gui.Ui, title: []const u8, subtitle: []const u8, progress: ?i32) !void {
    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var back: MeshBuilder = .{};
    defer back.deinit(ui.gpa);
    const dirt_uv: Atlas.Uv = .{ .u0 = 0, .v0 = 0, .u1 = ui.res.width / dirt_tile_scale, .v1 = ui.res.height / dirt_tile_scale };
    try gui.appendRectColor(&back, ui.gpa, 0, 0, ui.res.width, ui.res.height, dirt_uv, dirt_tint, ui.res);
    try gui.drawTexturedMesh(&back, ui.shader, ui.textures.dirt);

    var backgrounds: MeshBuilder = .{};
    defer backgrounds.deinit(ui.gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(ui.gpa);

    const cx = @floor(ui.res.width / 2.0);
    const cy = @floor(ui.res.height / 2.0);

    if (progress) |filled| {
        const x = cx - bar_width / 2.0;
        const y = cy + 16;
        try gui.appendRectColor(&backgrounds, ui.gpa, x, y, bar_width, bar_height, gui.opaque_texel, bar_background, ui.res);
        try gui.appendRectColor(&backgrounds, ui.gpa, x, y, @floatFromInt(filled), bar_height, gui.opaque_texel, bar_fill, ui.res);
        try gui.drawColorMesh(&backgrounds, ui.shader);
    }

    const title_width: f32 = @floatFromInt(ui.font.stringWidth(title));
    try gui.appendTextColor(&text, ui.gpa, ui.font, title, @floor((ui.res.width - title_width) / 2.0), cy - 4 - 16, text_color, ui.res);

    const subtitle_width: f32 = @floatFromInt(ui.font.stringWidth(subtitle));
    try gui.appendTextColor(&text, ui.gpa, ui.font, subtitle, @floor((ui.res.width - subtitle_width) / 2.0), cy - 4 + 8, text_color, ui.res);

    try gui.drawTexturedMesh(&text, ui.shader, ui.font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}
