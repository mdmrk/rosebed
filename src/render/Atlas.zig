const std = @import("std");

const gl = @import("gl");
const sdl3 = @import("sdl3");

const Atlas = @This();

pub const tiles_per_row = 16;
pub const tile_pixels = 16;
pub const tile_count = tiles_per_row * tiles_per_row;
pub const tile_bytes = tile_pixels * tile_pixels * 4;

pub const TileSet = std.StaticBitSet(tile_count);

texture: gl.uint,
free_tiles: TileSet = TileSet.initEmpty(),

pub fn load(data: []const u8) !Atlas {
    return loadWrapped(data, gl.CLAMP_TO_EDGE);
}

pub fn loadRepeat(data: []const u8) !Atlas {
    return loadWrapped(data, gl.REPEAT);
}

pub fn unusedTiles(pixels: []const u8, width: usize, height: usize) TileSet {
    var free = TileSet.initEmpty();
    if (width != tiles_per_row * tile_pixels or height != tiles_per_row * tile_pixels) return free;

    for (0..tile_count) |index| {
        const left = (index % tiles_per_row) * tile_pixels;
        const top = (index / tiles_per_row) * tile_pixels;

        var opaque_pixel = false;
        rows: for (0..tile_pixels) |row| {
            const start = ((top + row) * width + left) * 4;
            for (0..tile_pixels) |column| {
                if (pixels[start + column * 4 + 3] != 0) {
                    opaque_pixel = true;
                    break :rows;
                }
            }
        }
        if (!opaque_pixel) free.set(index);
    }
    return free;
}

pub fn claimTile(self: *Atlas) ?u8 {
    const index = self.free_tiles.findFirstSet() orelse return null;
    self.free_tiles.unset(index);
    return @intCast(index);
}

pub fn releaseTile(self: *Atlas, index: u8) void {
    self.free_tiles.set(index);
}

pub fn freeTileCount(self: Atlas) usize {
    return self.free_tiles.count();
}

pub fn writeTile(self: Atlas, index: u8, rgba: []const u8) void {
    std.debug.assert(rgba.len == tile_bytes);
    self.bind();
    gl.TexSubImage2D(
        gl.TEXTURE_2D,
        0,
        @as(gl.int, index % tiles_per_row) * tile_pixels,
        @as(gl.int, index / tiles_per_row) * tile_pixels,
        tile_pixels,
        tile_pixels,
        gl.RGBA,
        gl.UNSIGNED_BYTE,
        rgba.ptr,
    );
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

    return .{
        .texture = texture,
        .free_tiles = unusedTiles(pixels, @intCast(width), @intCast(height)),
    };
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

fn blankAtlasPixels(buffer: []u8) void {
    @memset(buffer, 0);
}

fn paintTile(buffer: []u8, index: usize) void {
    const width = tiles_per_row * tile_pixels;
    const left = (index % tiles_per_row) * tile_pixels;
    const top = (index / tiles_per_row) * tile_pixels;
    for (0..tile_pixels) |row| {
        const start = ((top + row) * width + left) * 4;
        for (0..tile_pixels) |column| buffer[start + column * 4 + 3] = 255;
    }
}

test "a tile with no opaque pixel anywhere counts as free" {
    const gpa = std.testing.allocator;
    const side = tiles_per_row * tile_pixels;
    const pixels = try gpa.alloc(u8, side * side * 4);
    defer gpa.free(pixels);
    blankAtlasPixels(pixels);

    paintTile(pixels, 0);
    paintTile(pixels, 17);
    paintTile(pixels, tile_count - 1);

    const free = unusedTiles(pixels, side, side);
    try std.testing.expectEqual(tile_count - 3, free.count());
    try std.testing.expect(!free.isSet(0));
    try std.testing.expect(!free.isSet(17));
    try std.testing.expect(!free.isSet(tile_count - 1));
    try std.testing.expect(free.isSet(1));
}

test "an atlas that is not the 16x16 tile grid offers no tiles to claim" {
    const gpa = std.testing.allocator;
    const pixels = try gpa.alloc(u8, 64 * 32 * 4);
    defer gpa.free(pixels);
    blankAtlasPixels(pixels);

    try std.testing.expectEqual(@as(usize, 0), unusedTiles(pixels, 64, 32).count());
}

test "claiming hands out each free tile once and releasing gives it back" {
    const gpa = std.testing.allocator;
    const side = tiles_per_row * tile_pixels;
    const pixels = try gpa.alloc(u8, side * side * 4);
    defer gpa.free(pixels);
    blankAtlasPixels(pixels);
    for (0..tile_count - 2) |index| paintTile(pixels, index);

    var atlas: Atlas = .{ .texture = 0, .free_tiles = unusedTiles(pixels, side, side) };
    try std.testing.expectEqual(@as(usize, 2), atlas.freeTileCount());

    const first = atlas.claimTile().?;
    const second = atlas.claimTile().?;
    try std.testing.expect(first != second);
    try std.testing.expect(atlas.claimTile() == null);

    atlas.releaseTile(first);
    try std.testing.expectEqual(first, atlas.claimTile().?);
}
