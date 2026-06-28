const std = @import("std");
const gl = @import("gl");
const sdl3 = @import("sdl3");

const Atlas = @import("atlas.zig");

const Font = @This();

pub const glyph_size: f32 = 8;
pub const texture_size: f32 = 128;
const cols_per_row = 16;

texture: gl.uint,
char_width: [256]u8,

fn scanCharWidth(pixels: []const u8, tex_width: usize, c: usize) u8 {
    const col0 = (c % cols_per_row) * 8;
    const row0 = (c / cols_per_row) * 8;

    var rightmost: i32 = -1;
    var x: i32 = 7;
    while (x >= 0) : (x -= 1) {
        var lit = false;
        for (0..8) |y| {
            const px = col0 + @as(usize, @intCast(x));
            const py = row0 + y;
            const idx = (py * tex_width + px) * 4;
            if (pixels[idx + 3] > 0) {
                lit = true;
                break;
            }
        }
        if (lit) {
            rightmost = x;
            break;
        }
    }
    if (c == ' ') rightmost = 2;
    return @intCast(rightmost + 2);
}

pub fn load(path: [:0]const u8) !Font {
    const surface = try sdl3.surface.Surface.initFromPngFile(path);
    defer surface.deinit();

    const converted = try surface.convertFormat(.array_rgba_32);
    defer converted.deinit();

    const width_usize = converted.getWidth();
    const width: gl.sizei = @intCast(width_usize);
    const height: gl.sizei = @intCast(converted.getHeight());
    const pixels = converted.getPixels() orelse return error.SurfaceNotAccessible;

    var char_width: [256]u8 = undefined;
    for (0..256) |c| char_width[c] = scanCharWidth(pixels, width_usize, c);

    var texture: gl.uint = 0;
    gl.GenTextures(1, @ptrCast(&texture));
    gl.BindTexture(gl.TEXTURE_2D, texture);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels.ptr);

    return .{ .texture = texture, .char_width = char_width };
}

pub fn bind(self: Font) void {
    gl.BindTexture(gl.TEXTURE_2D, self.texture);
}

pub fn deinit(self: Font) void {
    gl.DeleteTextures(1, @ptrCast(&self.texture));
}

pub fn glyphUv(c: u8) Atlas.Uv {
    const col: f32 = @floatFromInt(c % cols_per_row);
    const row: f32 = @floatFromInt(c / cols_per_row);
    return .{
        .u0 = col * glyph_size / texture_size,
        .v0 = row * glyph_size / texture_size,
        .u1 = (col * glyph_size + glyph_size) / texture_size,
        .v1 = (row * glyph_size + glyph_size) / texture_size,
    };
}

pub fn stringWidth(self: Font, text: []const u8) u32 {
    var total: u32 = 0;
    for (text) |c| total += self.char_width[c];
    return total;
}

test "glyphUv maps a char code to an 8px cell in the 128x128 grid" {
    const uv = glyphUv('0');
    try std.testing.expectApproxEqAbs(@as(f32, 0.0 / 128.0), uv.u0, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0 / 128.0), uv.v0, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0 / 128.0), uv.u1, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 32.0 / 128.0), uv.v1, 1.0e-6);
}
