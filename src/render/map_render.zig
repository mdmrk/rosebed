const std = @import("std");

const gl = @import("gl");
const math = @import("math");
const world = @import("world");

const Font = @import("Font.zig");
const MeshBuilder = @import("MeshBuilder.zig");

const degrees = std.math.pi / 180.0;

pub const face_size: f32 = 128;
pub const background_margin: f32 = 7;
pub const board_scale: f32 = 0.015625;
pub const held_scale: f32 = 0.38;
pub const face_depth: f32 = -0.01;
pub const marker_depth: f32 = -0.02;
pub const label_depth: f32 = -0.04;

const icon_columns: f32 = 4;
const marker_scale: [3]f32 = .{ 4, 4, 3 };
const shade_flat: u32 = 220;
const shade_lit: u32 = 255;
const shade_dark: u32 = 180;
const blank_alpha_step: u8 = 8;
const blank_alpha_base: u8 = 16;

pub const Surface = struct {
    texture: gl.uint = 0,
    pixels: [@as(usize, @intFromFloat(face_size)) * @as(usize, @intFromFloat(face_size)) * 4]u8 = @splat(0),

    pub fn init() Surface {
        var surface: Surface = .{};
        gl.GenTextures(1, @ptrCast(&surface.texture));
        gl.BindTexture(gl.TEXTURE_2D, surface.texture);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.TexImage2D(
            gl.TEXTURE_2D,
            0,
            gl.RGBA8,
            @intFromFloat(face_size),
            @intFromFloat(face_size),
            0,
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            null,
        );
        return surface;
    }

    pub fn deinit(self: Surface) void {
        gl.DeleteTextures(1, @ptrCast(&self.texture));
    }

    pub fn bind(self: Surface) void {
        gl.BindTexture(gl.TEXTURE_2D, self.texture);
    }

    pub fn upload(self: *Surface, colors: []const u8) void {
        paint(&self.pixels, colors);
        self.bind();
        gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1);
        gl.TexSubImage2D(
            gl.TEXTURE_2D,
            0,
            0,
            0,
            @intFromFloat(face_size),
            @intFromFloat(face_size),
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            &self.pixels,
        );
    }
};

pub fn paint(pixels: []u8, colors: []const u8) void {
    const stride: usize = @intFromFloat(face_size);
    for (colors, 0..) |shaded, index| {
        const tone = shaded / 4;
        const out = pixels[index * 4 ..][0..4];
        if (tone == 0) {
            out.* = .{ 0, 0, 0, @intCast((index + index / stride & 1) * blank_alpha_step + blank_alpha_base) };
            continue;
        }

        const rgb = @as(world.block.MapColor, @enumFromInt(tone)).rgb();
        const shade: u32 = switch (shaded & 3) {
            2 => shade_lit,
            0 => shade_dark,
            else => shade_flat,
        };
        out.* = .{
            @intCast((rgb >> 16 & 255) * shade / 255),
            @intCast((rgb >> 8 & 255) * shade / 255),
            @intCast((rgb & 255) * shade / 255),
            255,
        };
    }
}

pub const arm_sides = [2]f32{ -1, 1 };

pub fn baseMatrix(swing: f32, equipped: f32, pitch: f32) math.Mat4 {
    const scale: f32 = 0.8;
    const bob = math.util.sin(@sqrt(swing) * std.math.pi);
    const dip = math.util.sin(swing * std.math.pi);

    var transform = math.Mat4.translation(
        -bob * 0.4,
        math.util.sin(@sqrt(swing) * std.math.pi * 2.0) * 0.2,
        -dip * 0.2,
    );

    const tilt = -math.util.cos(std.math.clamp(1.0 - pitch / 45.0 + 0.1, 0.0, 1.0) * std.math.pi) * 0.5 + 0.5;
    transform = transform.mul(math.Mat4.translation(
        0,
        0.0 * scale - (1.0 - equipped) * 1.2 - tilt * 0.5 + 0.04,
        -0.9 * scale,
    ));
    transform = transform.mul(math.Mat4.rotationY(90.0 * degrees));
    return transform.mul(math.Mat4.rotationZ(tilt * -85.0 * degrees));
}

pub fn armMatrix(side: f32) math.Mat4 {
    var transform = math.Mat4.translation(-0.0, -0.6, 1.1 * side);
    transform = transform.mul(math.Mat4.rotationX(-45.0 * side * degrees));
    transform = transform.mul(math.Mat4.rotationZ(-90.0 * degrees));
    transform = transform.mul(math.Mat4.rotationZ(59.0 * degrees));
    return transform.mul(math.Mat4.rotationY(-65.0 * side * degrees));
}

pub fn boardMatrix(swing: f32) math.Mat4 {
    const bob = math.util.sin(@sqrt(swing) * std.math.pi);
    const twist = math.util.sin(swing * swing * std.math.pi);

    var transform = math.Mat4.rotationY(-twist * 20.0 * degrees);
    transform = transform.mul(math.Mat4.rotationZ(-bob * 20.0 * degrees));
    transform = transform.mul(math.Mat4.rotationX(-bob * 80.0 * degrees));

    transform = transform.mul(math.Mat4.scale(held_scale, held_scale, held_scale));
    transform = transform.mul(math.Mat4.rotationY(90.0 * degrees));
    transform = transform.mul(math.Mat4.rotationZ(180.0 * degrees));
    transform = transform.mul(math.Mat4.translation(-1, -1, 0));
    return transform.mul(math.Mat4.scale(board_scale, board_scale, board_scale));
}

const white: [4]u8 = .{ 255, 255, 255, 255 };

fn quad(
    mesh: *MeshBuilder,
    gpa: std.mem.Allocator,
    corners: [4][2]f32,
    uvs: [4][2]f32,
    z: f32,
    color: [4]u8,
) !void {
    var positions: [4][3]f32 = undefined;
    for (corners, 0..) |corner, index| positions[index] = .{ corner[0], corner[1], z };
    try mesh.quad(gpa, positions, uvs, color);
}

pub fn appendBackground(mesh: *MeshBuilder, gpa: std.mem.Allocator) !void {
    const low = 0 - background_margin;
    const high = face_size + background_margin;
    try quad(mesh, gpa, .{
        .{ low, high }, .{ high, high }, .{ high, low }, .{ low, low },
    }, .{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } }, 0, white);
}

pub fn appendFace(mesh: *MeshBuilder, gpa: std.mem.Allocator) !void {
    try quad(mesh, gpa, .{
        .{ 0, face_size }, .{ face_size, face_size }, .{ face_size, 0 }, .{ 0, 0 },
    }, .{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } }, face_depth, white);
}

pub fn appendMarkers(mesh: *MeshBuilder, gpa: std.mem.Allocator, markers: []const world.map.Marker) !void {
    for (markers) |marker| {
        const centre_x = @as(f32, @floatFromInt(marker.x)) / 2.0 + face_size / 2.0;
        const centre_y = @as(f32, @floatFromInt(marker.z)) / 2.0 + face_size / 2.0;
        const spin = @as(f32, @floatFromInt(marker.rotation)) * 360.0 / 16.0 * degrees;
        const cos = @cos(spin);
        const sin = @sin(spin);

        const icon: f32 = @floatFromInt(marker.icon);
        const left = @mod(icon, icon_columns) / icon_columns;
        const top = @divFloor(icon, icon_columns) / icon_columns;
        const right = (@mod(icon, icon_columns) + 1) / icon_columns;
        const bottom = (@divFloor(icon, icon_columns) + 1) / icon_columns;

        const local = [4][2]f32{ .{ -1, 1 }, .{ 1, 1 }, .{ 1, -1 }, .{ -1, -1 } };
        var corners: [4][2]f32 = undefined;
        for (local, 0..) |point, index| {
            const sx = (point[0] - 2.0 / 16.0) * marker_scale[0];
            const sy = (point[1] + 2.0 / 16.0) * marker_scale[1];
            corners[index] = .{ centre_x + sx * cos - sy * sin, centre_y + sx * sin + sy * cos };
        }

        try quad(mesh, gpa, corners, .{
            .{ left, top }, .{ right, top }, .{ right, bottom }, .{ left, bottom },
        }, marker_depth, white);
    }
}

pub fn appendLabel(mesh: *MeshBuilder, gpa: std.mem.Allocator, font: Font, text: []const u8) !void {
    var cursor: f32 = 0;
    for (text) |c| {
        const uv = Font.glyphUv(c);
        try quad(mesh, gpa, .{
            .{ cursor, 0 },
            .{ cursor + Font.glyph_draw_size, 0 },
            .{ cursor + Font.glyph_draw_size, Font.glyph_draw_size },
            .{ cursor, Font.glyph_draw_size },
        }, .{ .{ uv.u0, uv.v0 }, .{ uv.u1, uv.v0 }, .{ uv.u1, uv.v1 }, .{ uv.u0, uv.v1 } }, label_depth, .{ 0, 0, 0, 255 });
        cursor += @floatFromInt(font.char_width[c]);
    }
}

pub fn labelText(buffer: []u8, id: i16) []const u8 {
    return std.fmt.bufPrint(buffer, "map_{d}", .{id}) catch buffer[0..0];
}

fn placedAt(transform: math.Mat4, point: [4]f32) [4]f32 {
    const cells: [16]f32 = transform.m;
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    for (0..4) |col| {
        for (0..4) |row| out[row] += cells[col * 4 + row] * point[col];
    }
    return out;
}

test "the two arms sit mirrored either side of the board" {
    const left = placedAt(armMatrix(arm_sides[0]), .{ 0, 0, 0, 1 });
    const right = placedAt(armMatrix(arm_sides[1]), .{ 0, 0, 0, 1 });

    try std.testing.expectApproxEqAbs(left[0], right[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(left[1], right[1], 1.0e-5);
    try std.testing.expectApproxEqAbs(left[2], -right[2], 1.0e-5);
    try std.testing.expect(@abs(left[2]) > 0.5);
}

test "the board is centred on the hands, not on its own corner" {
    const centre = placedAt(boardMatrix(0), .{ face_size / 2.0, face_size / 2.0, 0, 1 });
    try std.testing.expect(@abs(centre[0]) < 1.0e-4);
    try std.testing.expect(@abs(centre[1]) < 1.0e-4);

    const corner = placedAt(boardMatrix(0), .{ 0, 0, 0, 1 });
    try std.testing.expect(@abs(corner[0]) > 1.0e-3 or @abs(corner[2]) > 1.0e-3);
}
