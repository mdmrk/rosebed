const std = @import("std");
const gl = @import("gl");
const world = @import("world");
const game = @import("game");

const Atlas = @import("atlas.zig");
const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const GpuMesh = @import("gpu_mesh.zig");
const Shader = @import("shader.zig");

const identity: [16]f32 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

pub const gui_scale: f32 = 2.0;

const hotbar_width: f32 = 182;
const hotbar_height: f32 = 22;
const highlight_width: f32 = 24;
const highlight_height: f32 = 22;
const slot_pitch: f32 = 20;
const icon_size: f32 = 16;
const crosshair_size: f32 = 16;
const gui_texture_size: f32 = 256;

fn toNdc(x: f32, y: f32, scaled_width: f32, scaled_height: f32) [2]f32 {
    return .{
        (x / scaled_width) * 2.0 - 1.0,
        1.0 - (y / scaled_height) * 2.0,
    };
}

fn appendRect(mesh: *MeshBuilder, gpa: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, uv: Atlas.Uv, scaled_width: f32, scaled_height: f32) !void {
    const tl = toNdc(x, y, scaled_width, scaled_height);
    const tr = toNdc(x + w, y, scaled_width, scaled_height);
    const br = toNdc(x + w, y + h, scaled_width, scaled_height);
    const bl = toNdc(x, y + h, scaled_width, scaled_height);
    try mesh.quad(gpa, .{
        .{ tl[0], tl[1], 0 }, .{ tr[0], tr[1], 0 }, .{ br[0], br[1], 0 }, .{ bl[0], bl[1], 0 },
    }, .{ .{ uv.u0, uv.v0 }, .{ uv.u1, uv.v0 }, .{ uv.u1, uv.v1 }, .{ uv.u0, uv.v1 } }, .{ 255, 255, 255, 255 });
}

fn pixelUv(x: f32, y: f32, w: f32, h: f32, tex_w: f32, tex_h: f32) Atlas.Uv {
    return .{ .u0 = x / tex_w, .v0 = y / tex_h, .u1 = (x + w) / tex_w, .v1 = (y + h) / tex_h };
}

fn appendText(mesh: *MeshBuilder, gpa: std.mem.Allocator, font: Font, text: []const u8, x: f32, y: f32, scaled_width: f32, scaled_height: f32) !void {
    var cursor = x;
    for (text) |c| {
        try appendRect(mesh, gpa, cursor, y, Font.glyph_size, Font.glyph_size, Font.glyphUv(c), scaled_width, scaled_height);
        cursor += @floatFromInt(font.char_width[c]);
    }
}

fn drawTexturedMesh(mesh: *MeshBuilder, shader: Shader, texture: anytype) !void {
    if (mesh.vertices.items.len == 0) return;
    var gpu = GpuMesh.upload(mesh);
    defer gpu.deinit();
    shader.use();
    gl.ActiveTexture(gl.TEXTURE0);
    texture.bind();
    shader.setInt("u_atlas", 0);
    shader.setMat4("u_view_proj", identity);
    gpu.draw();
}

pub fn draw(
    gpa: std.mem.Allocator,
    icon_shader: Shader,
    atlas: Atlas,
    gui_texture: Atlas,
    icons_texture: Atlas,
    items_texture: Atlas,
    font: Font,
    inventory: game.Inventory,
    screen_width: f32,
    screen_height: f32,
) !void {
    const scaled_width = screen_width / gui_scale;
    const scaled_height = screen_height / gui_scale;

    const hotbar_x = scaled_width / 2.0 - hotbar_width / 2.0;
    const hotbar_y = scaled_height - hotbar_height;

    gl.Disable(gl.DEPTH_TEST);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var chrome: MeshBuilder = .{};
    defer chrome.deinit(gpa);
    try appendRect(&chrome, gpa, hotbar_x, hotbar_y, hotbar_width, hotbar_height, pixelUv(0, 0, hotbar_width, hotbar_height, gui_texture_size, gui_texture_size), scaled_width, scaled_height);
    const highlight_x = hotbar_x - 1.0 + @as(f32, @floatFromInt(inventory.selected)) * slot_pitch;
    try appendRect(&chrome, gpa, highlight_x, hotbar_y - 1.0, highlight_width, highlight_height, pixelUv(0, 22, highlight_width, highlight_height, gui_texture_size, gui_texture_size), scaled_width, scaled_height);
    try drawTexturedMesh(&chrome, icon_shader, gui_texture);

    var crosshair: MeshBuilder = .{};
    defer crosshair.deinit(gpa);
    const crosshair_x = scaled_width / 2.0 - 7.0;
    const crosshair_y = scaled_height / 2.0 - 7.0;
    try appendRect(&crosshair, gpa, crosshair_x, crosshair_y, crosshair_size, crosshair_size, pixelUv(0, 0, crosshair_size, crosshair_size, gui_texture_size, gui_texture_size), scaled_width, scaled_height);
    gl.BlendFunc(gl.ONE_MINUS_DST_COLOR, gl.ONE_MINUS_SRC_COLOR);
    try drawTexturedMesh(&crosshair, icon_shader, icons_texture);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var block_icons: MeshBuilder = .{};
    defer block_icons.deinit(gpa);
    var item_icons: MeshBuilder = .{};
    defer item_icons.deinit(gpa);
    var text: MeshBuilder = .{};
    defer text.deinit(gpa);

    for (0..game.Inventory.hotbar_size) |i| {
        const stack = inventory.slots[i] orelse continue;
        const slot_x = hotbar_x + 2.0 + @as(f32, @floatFromInt(i)) * slot_pitch;
        const slot_y = hotbar_y + 3.0;

        if (stack.id <= 255) {
            const tile = world.block.faceTextures(@intCast(stack.id))[world.block.up];
            try appendRect(&block_icons, gpa, slot_x, slot_y, icon_size, icon_size, Atlas.tileUv(tile), scaled_width, scaled_height);
        } else if (world.item.iconTile(stack.id)) |tile| {
            try appendRect(&item_icons, gpa, slot_x, slot_y, icon_size, icon_size, Atlas.tileUv(tile), scaled_width, scaled_height);
        }

        if (stack.count > 1) {
            var buf: [3]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{d}", .{stack.count}) catch continue;
            const width: f32 = @floatFromInt(font.stringWidth(label));
            try appendText(&text, gpa, font, label, slot_x + 17.0 - width, slot_y + 9.0, scaled_width, scaled_height);
        }
    }

    try drawTexturedMesh(&block_icons, icon_shader, atlas);
    try drawTexturedMesh(&item_icons, icon_shader, items_texture);
    try drawTexturedMesh(&text, icon_shader, font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}
