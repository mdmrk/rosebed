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
pub const icon_size: f32 = 16;
const crosshair_size: f32 = 16;
const gui_texture_size: f32 = 256;

pub fn toNdc(x: f32, y: f32, scaled_width: f32, scaled_height: f32) [2]f32 {
    return .{
        (x / scaled_width) * 2.0 - 1.0,
        1.0 - (y / scaled_height) * 2.0,
    };
}

pub fn appendRectColor(mesh: *MeshBuilder, gpa: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, uv: Atlas.Uv, color: [4]u8, scaled_width: f32, scaled_height: f32) !void {
    const tl = toNdc(x, y, scaled_width, scaled_height);
    const tr = toNdc(x + w, y, scaled_width, scaled_height);
    const br = toNdc(x + w, y + h, scaled_width, scaled_height);
    const bl = toNdc(x, y + h, scaled_width, scaled_height);
    try mesh.quad(gpa, .{
        .{ tl[0], tl[1], 0 }, .{ tr[0], tr[1], 0 }, .{ br[0], br[1], 0 }, .{ bl[0], bl[1], 0 },
    }, .{ .{ uv.u0, uv.v0 }, .{ uv.u1, uv.v0 }, .{ uv.u1, uv.v1 }, .{ uv.u0, uv.v1 } }, color);
}

pub fn appendRect(mesh: *MeshBuilder, gpa: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, uv: Atlas.Uv, scaled_width: f32, scaled_height: f32) !void {
    try appendRectColor(mesh, gpa, x, y, w, h, uv, .{ 255, 255, 255, 255 }, scaled_width, scaled_height);
}

pub fn pixelUv(x: f32, y: f32, w: f32, h: f32, tex_w: f32, tex_h: f32) Atlas.Uv {
    return .{ .u0 = x / tex_w, .v0 = y / tex_h, .u1 = (x + w) / tex_w, .v1 = (y + h) / tex_h };
}

pub fn appendTextColor(mesh: *MeshBuilder, gpa: std.mem.Allocator, font: Font, text: []const u8, x: f32, y: f32, color: [4]u8, scaled_width: f32, scaled_height: f32) !void {
    var cursor = x;
    for (text) |c| {
        try appendRectColor(mesh, gpa, cursor, y, Font.glyph_size, Font.glyph_size, Font.glyphUv(c), color, scaled_width, scaled_height);
        cursor += @floatFromInt(font.char_width[c]);
    }
}

pub fn appendText(mesh: *MeshBuilder, gpa: std.mem.Allocator, font: Font, text: []const u8, x: f32, y: f32, scaled_width: f32, scaled_height: f32) !void {
    try appendTextColor(mesh, gpa, font, text, x, y, .{ 255, 255, 255, 255 }, scaled_width, scaled_height);
}

pub fn drawTexturedMesh(mesh: *MeshBuilder, shader: Shader, texture: anytype) !void {
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

const iso_light_ambient: f32 = 0.4;
const iso_light_diffuse: f32 = 0.6;

fn normalize3(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

fn isoFaceBrightness(normal: [3]f32) f32 {
    const light0 = normalize3(.{ 0.2, 1.0, -0.7 });
    const light1 = normalize3(.{ -0.2, 1.0, 0.7 });
    const d0 = @max(0.0, normal[0] * light0[0] + normal[1] * light0[1] + normal[2] * light0[2]);
    const d1 = @max(0.0, normal[0] * light1[0] + normal[1] * light1[1] + normal[2] * light1[2]);
    return @min(1.0, iso_light_ambient + iso_light_diffuse * d0 + iso_light_diffuse * d1);
}

const iso_brightness_up = isoFaceBrightness(.{ 0, 1, 0 });
const iso_brightness_south = isoFaceBrightness(.{ 0, 0, 1 });
const iso_brightness_east = isoFaceBrightness(.{ 1, 0, 0 });

const iso_s2: f32 = @sqrt(2.0) / 2.0;
const iso_s3: f32 = @sqrt(3.0) / 2.0;
const iso_scale: f32 = 10.0;

fn isoOffset(vx: f32, vy: f32, vz: f32) [2]f32 {
    return .{
        iso_scale * iso_s2 * (vx - vz),
        iso_scale * (0.5 * iso_s2 * (vx + vz) - iso_s3 * vy),
    };
}

const iso_up_corners = [4][3]f32{ .{ 0, 1, 1 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 } };
const iso_south_corners = [4][3]f32{ .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 0, 1 } };
const iso_east_corners = [4][3]f32{ .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 }, .{ 1, 0, 0 } };

fn appendIsoFace(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    corners: [4][3]f32,
    tile: u8,
    brightness: f32,
    x: f32,
    y: f32,
    scaled_width: f32,
    scaled_height: f32,
) !void {
    const uv = Atlas.tileUv(tile);
    const uvs = [4][2]f32{ .{ uv.u0, uv.v1 }, .{ uv.u0, uv.v0 }, .{ uv.u1, uv.v0 }, .{ uv.u1, uv.v1 } };
    var positions: [4][3]f32 = undefined;
    for (corners, 0..) |c, i| {
        const offset = isoOffset(c[0] - 0.5, c[1] - 0.5, c[2] - 0.5);
        const ndc = toNdc(x + 8.0 + offset[0], y + 8.0 + offset[1], scaled_width, scaled_height);
        positions[i] = .{ ndc[0], ndc[1], 0 };
    }
    const shade: u8 = @intFromFloat(@round(brightness * 255.0));
    try mesh.quad(gpa, positions, uvs, .{ shade, shade, shade, 255 });
}

pub fn appendBlockIcon3d(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    id: u8,
    meta: u4,
    x: f32,
    y: f32,
    scaled_width: f32,
    scaled_height: f32,
) !void {
    var textures = world.block.faceTextures(id);
    if (id == world.block.log) {
        const side_tile = world.block.logSideTile(meta);
        textures[world.block.south] = side_tile;
        textures[world.block.east] = side_tile;
    }
    try appendIsoFace(mesh, gpa, iso_up_corners, textures[world.block.up], iso_brightness_up, x, y, scaled_width, scaled_height);
    try appendIsoFace(mesh, gpa, iso_south_corners, textures[world.block.south], iso_brightness_south, x, y, scaled_width, scaled_height);
    try appendIsoFace(mesh, gpa, iso_east_corners, textures[world.block.east], iso_brightness_east, x, y, scaled_width, scaled_height);
}

pub fn appendStackIcon(
    block_mesh: *MeshBuilder,
    item_mesh: *MeshBuilder,
    text_mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    font: Font,
    stack: game.Inventory.ItemStack,
    x: f32,
    y: f32,
    scaled_width: f32,
    scaled_height: f32,
) !void {
    if (stack.id <= 255) {
        const id: u8 = @intCast(stack.id);
        if (world.block.isCross(id)) {
            const tile = world.block.crossTile(id, stack.meta);
            try appendRect(block_mesh, gpa, x, y, icon_size, icon_size, Atlas.tileUv(tile), scaled_width, scaled_height);
        } else {
            try appendBlockIcon3d(block_mesh, gpa, id, stack.meta, x, y, scaled_width, scaled_height);
        }
    } else if (world.item.iconTile(stack.id)) |tile| {
        try appendRect(item_mesh, gpa, x, y, icon_size, icon_size, Atlas.tileUv(tile), scaled_width, scaled_height);
    }

    if (stack.count > 1) {
        var buf: [3]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{d}", .{stack.count}) catch return;
        const label_width: f32 = @floatFromInt(font.stringWidth(label));
        try appendText(text_mesh, gpa, font, label, x + 17.0 - label_width, y + 9.0, scaled_width, scaled_height);
    }
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
        try appendStackIcon(&block_icons, &item_icons, &text, gpa, font, stack, slot_x, slot_y, scaled_width, scaled_height);
    }

    try drawTexturedMesh(&block_icons, icon_shader, atlas);
    try drawTexturedMesh(&item_icons, icon_shader, items_texture);
    try drawTexturedMesh(&text, icon_shader, font);

    gl.Disable(gl.BLEND);
    gl.Enable(gl.DEPTH_TEST);
}
