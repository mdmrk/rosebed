const std = @import("std");
const gl = @import("gl");
const sdl3 = @import("sdl3");

const Atlas = @This();

pub const tiles_per_row = 16;

texture: gl.uint,

pub fn load(data: []const u8) !Atlas {
    return loadWrapped(data, gl.CLAMP_TO_EDGE);
}

pub fn loadRepeat(data: []const u8) !Atlas {
    return loadWrapped(data, gl.REPEAT);
}

fn loadWrapped(data: []const u8, wrap: gl.int) !Atlas {
    const surface = try sdl3.surface.Surface.initFromPngIo(try .initFromConstMem(data), true);
    defer surface.deinit();

    const converted = try surface.convertFormat(.array_rgba_32);
    defer converted.deinit();

    const width: gl.sizei = @intCast(converted.getWidth());
    const height: gl.sizei = @intCast(converted.getHeight());
    const pixels = converted.getPixels() orelse return error.SurfaceNotAccessible;

    var texture: gl.uint = 0;
    gl.GenTextures(1, @ptrCast(&texture));
    gl.BindTexture(gl.TEXTURE_2D, texture);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, wrap);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, wrap);
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels.ptr);

    return .{ .texture = texture };
}

pub fn bind(self: Atlas) void {
    gl.BindTexture(gl.TEXTURE_2D, self.texture);
}

pub fn deinit(self: Atlas) void {
    gl.DeleteTextures(1, @ptrCast(&self.texture));
}

pub const Uv = struct { u0: f32, v0: f32, u1: f32, v1: f32 };

pub fn tileUv(index: u8) Uv {
    const tile_size: f32 = 1.0 / @as(f32, tiles_per_row);
    const col: f32 = @floatFromInt(index % tiles_per_row);
    const row: f32 = @floatFromInt(index / tiles_per_row);
    return .{
        .u0 = col * tile_size,
        .v0 = row * tile_size,
        .u1 = (col + 1) * tile_size,
        .v1 = (row + 1) * tile_size,
    };
}

test "tileUv maps index to a 16x16 grid cell" {
    const a = tileUv(0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), a.u0, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), a.v0, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 16.0), a.u1, 1.0e-6);

    const b = tileUv(17);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 16.0), b.u0, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 16.0), b.v0, 1.0e-6);
}
