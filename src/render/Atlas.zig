const std = @import("std");

const gl = @import("gl");
const sdl3 = @import("sdl3");

const anaglyph = @import("anaglyph.zig");

const Atlas = @This();

pub const tiles_per_row = 16;
pub const tile_pixels = 16;
pub const tile_count = tiles_per_row * tiles_per_row;

pub const TileSet = std.bit_set.Static(tile_count);

texture: gl.uint,
free_tiles: TileSet = TileSet.empty,
mip_levels: u8 = 0,

pub const Filtering = struct {
    mipmaps: bool = false,
    anisotropy: f32 = 1,
};

const texture_max_anisotropy = 0x84FE;
const max_texture_max_anisotropy = 0x84FF;

pub fn load(data: []const u8, desaturate: bool) !Atlas {
    return loadWrapped(data, gl.CLAMP_TO_EDGE, gl.NEAREST, desaturate);
}

pub fn loadRepeat(data: []const u8, desaturate: bool) !Atlas {
    return loadWrapped(data, gl.REPEAT, gl.NEAREST, desaturate);
}

pub fn loadBlurred(data: []const u8, desaturate: bool) !Atlas {
    return loadWrapped(data, gl.CLAMP_TO_EDGE, gl.LINEAR, desaturate);
}

pub fn loadMipmapped(gpa: std.mem.Allocator, data: []const u8, desaturate: bool) !Atlas {
    var atlas = try loadWrapped(data, gl.CLAMP_TO_EDGE, gl.NEAREST, desaturate);
    errdefer atlas.deinit();

    const surface = try sdl3.surface.Surface.initFromPngIo(try .initFromConstMem(data), true);
    defer surface.deinit();
    const converted = try surface.convertFormat(.array_rgba_32);
    defer converted.deinit();
    const width = converted.getWidth();
    const height = converted.getHeight();
    const pixels = converted.getPixels() orelse return error.SurfaceNotAccessible;
    anaglyph.pixels(desaturate, pixels);

    atlas.mip_levels = mipLevelsFor(width, height);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAX_LEVEL, atlas.mip_levels);
    for (1..@as(usize, atlas.mip_levels) + 1) |level| {
        const w: gl.sizei = @intCast(width >> @intCast(level));
        const h: gl.sizei = @intCast(height >> @intCast(level));
        gl.TexImage2D(gl.TEXTURE_2D, @intCast(level), gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    }
    const scratch = try gpa.alloc(u8, mipScratchBytes(width, height));
    defer gpa.free(scratch);
    uploadMips(scratch, pixels, width, height, 0, 0, atlas.mip_levels);
    return atlas;
}

pub fn mipLevelsFor(width: usize, height: usize) u8 {
    if (width != height or !std.math.isPowerOfTwo(width) or width < tiles_per_row) return 0;
    return std.math.log2_int(usize, width / tiles_per_row);
}

pub fn downsample(src: []const u8, width: usize, height: usize, dst: []u8) void {
    const half_w = width / 2;
    const half_h = height / 2;
    for (0..half_h) |y| {
        for (0..half_w) |x| {
            var weighted: [3]u32 = .{ 0, 0, 0 };
            var plain: [3]u32 = .{ 0, 0, 0 };
            var alpha: u32 = 0;
            for ([_][2]usize{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |d| {
                const at = ((y * 2 + d[1]) * width + x * 2 + d[0]) * 4;
                const a: u32 = src[at + 3];
                for (0..3) |c| {
                    weighted[c] += @as(u32, src[at + c]) * a;
                    plain[c] += src[at + c];
                }
                alpha += a;
            }
            const out = (y * half_w + x) * 4;
            for (0..3) |c| {
                dst[out + c] = @intCast(if (alpha == 0) (plain[c] + 2) / 4 else (weighted[c] + alpha / 2) / alpha);
            }
            dst[out + 3] = @intCast((alpha + 2) / 4);
        }
    }
}

pub fn mipScratchBytes(width: usize, height: usize) usize {
    return (width / 2) * (height / 2) * 4 * 2;
}

pub fn uploadMips(scratch: []u8, pixels: []const u8, width: usize, height: usize, x: usize, y: usize, levels: u8) void {
    if (levels == 0) return;
    const half = (width / 2) * (height / 2) * 4;
    std.debug.assert(scratch.len >= half * 2);

    var current: []const u8 = pixels;
    var w = width;
    var h = height;
    var level: u8 = 1;
    while (level <= levels and w >= 2 and h >= 2) : (level += 1) {
        const target = scratch[(level % 2) * half ..][0 .. (w / 2) * (h / 2) * 4];
        downsample(current, w, h, target);
        w /= 2;
        h /= 2;
        gl.TexSubImage2D(gl.TEXTURE_2D, level, @intCast(x >> @intCast(level)), @intCast(y >> @intCast(level)), @intCast(w), @intCast(h), gl.RGBA, gl.UNSIGNED_BYTE, target.ptr);
        current = target;
    }
}

var anisotropy_limit: ?f32 = null;

fn maxAnisotropy() f32 {
    if (anisotropy_limit) |limit| return limit;
    var supported = false;
    var count: gl.int = 0;
    gl.GetIntegerv(gl.NUM_EXTENSIONS, @ptrCast(&count));
    for (0..@intCast(@max(count, 0))) |index| {
        const name = gl.GetStringi(gl.EXTENSIONS, @intCast(index)) orelse continue;
        const text = std.mem.span(name);
        if (std.mem.endsWith(u8, text, "texture_filter_anisotropic")) supported = true;
    }
    var limit: f32 = 1;
    if (supported) gl.GetFloatv(max_texture_max_anisotropy, @ptrCast(&limit));
    anisotropy_limit = @max(limit, 1);
    return anisotropy_limit.?;
}

pub fn applyFiltering(self: Atlas, filtering: Filtering) void {
    if (self.mip_levels == 0) return;
    self.bind();
    const mipmaps = filtering.mipmaps;
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, if (mipmaps) gl.NEAREST_MIPMAP_LINEAR else gl.NEAREST);
    const limit = maxAnisotropy();
    if (limit > 1) gl.TexParameterf(gl.TEXTURE_2D, texture_max_anisotropy, if (mipmaps) @min(filtering.anisotropy, limit) else 1);
}

pub fn unusedTiles(pixels: []const u8, width: usize, height: usize) TileSet {
    var free = TileSet.empty;
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

fn loadWrapped(data: []const u8, wrap: gl.int, filter: gl.int, desaturate: bool) !Atlas {
    const surface = try sdl3.surface.Surface.initFromPngIo(try .initFromConstMem(data), true);
    defer surface.deinit();

    const converted = try surface.convertFormat(.array_rgba_32);
    defer converted.deinit();

    const width: gl.sizei = @intCast(converted.getWidth());
    const height: gl.sizei = @intCast(converted.getHeight());
    const pixels = converted.getPixels() orelse return error.SurfaceNotAccessible;
    anaglyph.pixels(desaturate, pixels);

    var texture: gl.uint = 0;
    gl.GenTextures(1, @ptrCast(&texture));
    gl.BindTexture(gl.TEXTURE_2D, texture);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
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

test "a mip level averages colour by coverage so cut-out edges never darken" {
    const src = [_]u8{
        200, 100, 50, 255, 0, 0, 0, 0,
        200, 100, 50, 255, 0, 0, 0, 0,
    };
    var dst: [4]u8 = undefined;
    downsample(&src, 2, 2, &dst);
    try std.testing.expectEqualSlices(u8, &.{ 200, 100, 50, 128 }, &dst);
}

test "the atlas stops shrinking once a tile is a single pixel" {
    try std.testing.expectEqual(@as(u8, 4), mipLevelsFor(256, 256));
    try std.testing.expectEqual(@as(u8, 5), mipLevelsFor(512, 512));
    try std.testing.expectEqual(@as(u8, 0), mipLevelsFor(256, 128));
    try std.testing.expectEqual(@as(u8, 0), mipLevelsFor(300, 300));
}
