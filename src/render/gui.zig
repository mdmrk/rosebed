const std = @import("std");
const gl = @import("gl");
const world = @import("world");
const game = @import("game");

const Atlas = @import("atlas.zig");
const Font = @import("font.zig");
const MeshBuilder = @import("mesh_builder.zig");
const GpuMesh = @import("gpu_mesh.zig");
const Shader = @import("shader.zig");
const Textures = @import("textures.zig");

pub const Ui = struct {
    gpa: std.mem.Allocator,
    shader: Shader,
    textures: Textures,
    font: Font,
    mouse_x: f32,
    mouse_y: f32,
    res: Scaled,
};

const identity: [16]f32 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

pub const Scaled = struct {
    factor: f32,
    ortho_width: f32,
    ortho_height: f32,
    width: f32,
    height: f32,
};

pub fn scaledResolution(pixel_width: f32, pixel_height: f32, scale_limit: f32) Scaled {
    var factor: f32 = 1;
    while (factor < scale_limit and
        @floor(pixel_width / (factor + 1)) >= 320 and
        @floor(pixel_height / (factor + 1)) >= 240) : (factor += 1)
    {}

    const ortho_width = pixel_width / factor;
    const ortho_height = pixel_height / factor;
    return .{
        .factor = factor,
        .ortho_width = ortho_width,
        .ortho_height = ortho_height,
        .width = @ceil(ortho_width),
        .height = @ceil(ortho_height),
    };
}

pub const icon_size: f32 = 16;
pub const gui_texture_size: f32 = 256;

pub fn toNdc(x: f32, y: f32, res: Scaled) [2]f32 {
    return .{
        (x / res.ortho_width) * 2.0 - 1.0,
        1.0 - (y / res.ortho_height) * 2.0,
    };
}

pub fn appendRectColor(mesh: *MeshBuilder, gpa: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, uv: Atlas.Uv, color: [4]u8, res: Scaled) !void {
    const tl = toNdc(x, y, res);
    const tr = toNdc(x + w, y, res);
    const br = toNdc(x + w, y + h, res);
    const bl = toNdc(x, y + h, res);
    try mesh.quad(gpa, .{
        .{ tl[0], tl[1], 0 }, .{ tr[0], tr[1], 0 }, .{ br[0], br[1], 0 }, .{ bl[0], bl[1], 0 },
    }, .{ .{ uv.u0, uv.v0 }, .{ uv.u1, uv.v0 }, .{ uv.u1, uv.v1 }, .{ uv.u0, uv.v1 } }, color);
}

pub fn appendRect(mesh: *MeshBuilder, gpa: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, uv: Atlas.Uv, res: Scaled) !void {
    try appendRectColor(mesh, gpa, x, y, w, h, uv, .{ 255, 255, 255, 255 }, res);
}

pub fn appendGradientRect(mesh: *MeshBuilder, gpa: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, uv: Atlas.Uv, top: [4]u8, bottom: [4]u8, res: Scaled) !void {
    const tl = toNdc(x, y, res);
    const tr = toNdc(x + w, y, res);
    const br = toNdc(x + w, y + h, res);
    const bl = toNdc(x, y + h, res);
    try mesh.quadShaded(gpa, .{
        .{ tl[0], tl[1], 0 }, .{ tr[0], tr[1], 0 }, .{ br[0], br[1], 0 }, .{ bl[0], bl[1], 0 },
    }, .{ .{ uv.u0, uv.v0 }, .{ uv.u1, uv.v0 }, .{ uv.u1, uv.v1 }, .{ uv.u0, uv.v1 } }, .{ top, top, bottom, bottom });
}

pub const veil_top: [4]u8 = .{ 16, 16, 16, 192 };
pub const veil_bottom: [4]u8 = .{ 16, 16, 16, 208 };
pub const opaque_texel: Atlas.Uv = .{ .u0 = 2.5 / gui_texture_size, .v0 = 2.5 / gui_texture_size, .u1 = 2.5 / gui_texture_size, .v1 = 2.5 / gui_texture_size };

pub fn appendVeil(mesh: *MeshBuilder, gpa: std.mem.Allocator, res: Scaled) !void {
    try appendGradientRect(mesh, gpa, 0, 0, res.width, res.height, opaque_texel, veil_top, veil_bottom, res);
}

pub fn pixelUv(x: f32, y: f32, w: f32, h: f32, tex_w: f32, tex_h: f32) Atlas.Uv {
    return .{ .u0 = x / tex_w, .v0 = y / tex_h, .u1 = (x + w) / tex_w, .v1 = (y + h) / tex_h };
}

pub fn shadowColor(color: [4]u8) [4]u8 {
    return .{ (color[0] & 0xFC) >> 2, (color[1] & 0xFC) >> 2, (color[2] & 0xFC) >> 2, color[3] };
}

test "shadowColor matches renderString's (rgb & 0xFCFCFC) >> 2" {
    const cases = [_]struct { rgb: u32, want: [3]u8 }{
        .{ .rgb = 16776960, .want = .{ 63, 63, 0 } },
        .{ .rgb = 16777215, .want = .{ 63, 63, 63 } },
        .{ .rgb = 14737632, .want = .{ 56, 56, 56 } },
        .{ .rgb = 16777120, .want = .{ 63, 63, 40 } },
        .{ .rgb = 10526880, .want = .{ 40, 40, 40 } },
        .{ .rgb = 5263440, .want = .{ 20, 20, 20 } },
    };
    for (cases) |case| {
        const packed_shadow = (case.rgb & 16579836) >> 2;
        const rgb: [4]u8 = .{
            @truncate(case.rgb >> 16),
            @truncate(case.rgb >> 8),
            @truncate(case.rgb),
            255,
        };
        const got = shadowColor(rgb);
        try std.testing.expectEqual(@as(u8, @truncate(packed_shadow >> 16)), got[0]);
        try std.testing.expectEqual(@as(u8, @truncate(packed_shadow >> 8)), got[1]);
        try std.testing.expectEqual(@as(u8, @truncate(packed_shadow)), got[2]);
        try std.testing.expectEqual(case.want, got[0..3].*);
        try std.testing.expectEqual(@as(u8, 255), got[3]);
    }
}

pub fn appendTextNoShadow(mesh: *MeshBuilder, gpa: std.mem.Allocator, font: Font, text: []const u8, x: f32, y: f32, color: [4]u8, res: Scaled) !void {
    try appendGlyphs(mesh, gpa, font, text, x, y, color, res);
}

fn appendGlyphs(mesh: *MeshBuilder, gpa: std.mem.Allocator, font: Font, text: []const u8, x: f32, y: f32, color: [4]u8, res: Scaled) !void {
    var cursor = x;
    for (text) |c| {
        try appendRectColor(mesh, gpa, cursor, y, Font.glyph_draw_size, Font.glyph_draw_size, Font.glyphUv(c), color, res);
        cursor += @floatFromInt(font.char_width[c]);
    }
}

pub fn appendTextColor(mesh: *MeshBuilder, gpa: std.mem.Allocator, font: Font, text: []const u8, x: f32, y: f32, color: [4]u8, res: Scaled) !void {
    try appendGlyphs(mesh, gpa, font, text, x + 1, y + 1, shadowColor(color), res);
    try appendGlyphs(mesh, gpa, font, text, x, y, color, res);
}

pub fn appendText(mesh: *MeshBuilder, gpa: std.mem.Allocator, font: Font, text: []const u8, x: f32, y: f32, res: Scaled) !void {
    try appendTextColor(mesh, gpa, font, text, x, y, .{ 255, 255, 255, 255 }, res);
}

pub const Transform = struct {
    x: f32,
    y: f32,
    scale: f32,
    rotation: f32,

    fn map(self: Transform, px: f32, py: f32) [2]f32 {
        const cos = @cos(self.rotation);
        const sin = @sin(self.rotation);
        const sx = px * self.scale;
        const sy = py * self.scale;
        return .{ self.x + sx * cos - sy * sin, self.y + sx * sin + sy * cos };
    }
};

fn appendGlyphsTransformed(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    font: Font,
    text: []const u8,
    x: f32,
    y: f32,
    color: [4]u8,
    transform: Transform,
    res: Scaled,
) !void {
    const g = Font.glyph_draw_size;
    var cursor = x;
    for (text) |c| {
        const uv = Font.glyphUv(c);
        const tl = transform.map(cursor, y);
        const tr = transform.map(cursor + g, y);
        const br = transform.map(cursor + g, y + g);
        const bl = transform.map(cursor, y + g);
        const p0 = toNdc(tl[0], tl[1], res);
        const p1 = toNdc(tr[0], tr[1], res);
        const p2 = toNdc(br[0], br[1], res);
        const p3 = toNdc(bl[0], bl[1], res);
        try mesh.quad(gpa, .{
            .{ p0[0], p0[1], 0 }, .{ p1[0], p1[1], 0 }, .{ p2[0], p2[1], 0 }, .{ p3[0], p3[1], 0 },
        }, .{ .{ uv.u0, uv.v0 }, .{ uv.u1, uv.v0 }, .{ uv.u1, uv.v1 }, .{ uv.u0, uv.v1 } }, color);
        cursor += @floatFromInt(font.char_width[c]);
    }
}

pub fn appendTextTransformed(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    font: Font,
    text: []const u8,
    x: f32,
    y: f32,
    color: [4]u8,
    transform: Transform,
    res: Scaled,
) !void {
    try appendGlyphsTransformed(mesh, gpa, font, text, x + 1, y + 1, shadowColor(color), transform, res);
    try appendGlyphsTransformed(mesh, gpa, font, text, x, y, color, transform, res);
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
    res: Scaled,
) !void {
    const uv = Atlas.tileUv(tile);
    const uvs = [4][2]f32{ .{ uv.u0, uv.v1 }, .{ uv.u0, uv.v0 }, .{ uv.u1, uv.v0 }, .{ uv.u1, uv.v1 } };
    var positions: [4][3]f32 = undefined;
    for (corners, 0..) |c, i| {
        const offset = isoOffset(c[0] - 0.5, c[1] - 0.5, c[2] - 0.5);
        const ndc = toNdc(x + 8.0 + offset[0], y + 8.0 + offset[1], res);
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
    res: Scaled,
) !void {
    var textures = world.block.faceTextures(id);
    if (id == world.block.log) {
        const side_tile = world.block.logSideTile(meta);
        textures[world.block.south] = side_tile;
        textures[world.block.east] = side_tile;
    }
    try appendIsoFace(mesh, gpa, iso_up_corners, textures[world.block.up], iso_brightness_up, x, y, res);
    try appendIsoFace(mesh, gpa, iso_south_corners, textures[world.block.south], iso_brightness_south, x, y, res);
    try appendIsoFace(mesh, gpa, iso_east_corners, textures[world.block.east], iso_brightness_east, x, y, res);
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
    res: Scaled,
) !void {
    if (stack.id <= 255) {
        const id: u8 = @intCast(stack.id);
        if (world.block.isCross(id)) {
            const tile = world.block.crossTile(id, stack.meta);
            try appendRect(block_mesh, gpa, x, y, icon_size, icon_size, Atlas.tileUv(tile), res);
        } else {
            try appendBlockIcon3d(block_mesh, gpa, id, stack.meta, x, y, res);
        }
    } else if (world.item.iconTile(stack.id)) |tile| {
        try appendRect(item_mesh, gpa, x, y, icon_size, icon_size, Atlas.tileUv(tile), res);
    }

    if (stack.count > 1) {
        var buf: [3]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{d}", .{stack.count}) catch return;
        const label_width: f32 = @floatFromInt(font.stringWidth(label));
        try appendText(text_mesh, gpa, font, label, x + 17.0 - label_width, y + 9.0, res);
    }
}
