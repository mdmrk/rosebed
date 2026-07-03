const std = @import("std");
const constants = @import("constants.zig");
const NibbleArray = @import("nibble_array.zig");

const Chunk = @This();

pub const width = constants.chunk_width;
pub const height = constants.chunk_height;
pub const volume = constants.chunk_volume;

x: i32,
z: i32,
blocks: [volume]u8 = [_]u8{0} ** volume,
metadata: NibbleArray = .{},
sky_light: NibbleArray = .{},
block_light: NibbleArray = .{},
height_map: [width * width]u8 = [_]u8{0} ** (width * width),
temperature: [width * width]f32 = [_]f32{0.5} ** (width * width),
humidity: [width * width]f32 = [_]f32{0.5} ** (width * width),

pub fn init(x: i32, z: i32) Chunk {
    return .{ .x = x, .z = z };
}

fn blockIndex(x: u32, y: u32, z: u32) usize {
    return (x << 11) | (z << 7) | y;
}

pub fn getBlockId(self: *const Chunk, x: u32, y: u32, z: u32) u8 {
    return self.blocks[blockIndex(x, y, z)];
}

pub fn setBlockId(self: *Chunk, x: u32, y: u32, z: u32, id: u8) void {
    self.blocks[blockIndex(x, y, z)] = id;
}

pub fn getBlockMetadata(self: *const Chunk, x: u32, y: u32, z: u32) u4 {
    return self.metadata.get(x, y, z);
}

pub fn setBlockMetadata(self: *Chunk, x: u32, y: u32, z: u32, value: u4) void {
    self.metadata.set(x, y, z, value);
}

fn heightMapIndex(x: u32, z: u32) usize {
    return (z << 4) | x;
}

pub fn getHeightValue(self: *const Chunk, x: u32, z: u32) u8 {
    return self.height_map[heightMapIndex(x, z)];
}

pub fn setHeightValue(self: *Chunk, x: u32, z: u32, value: u8) void {
    self.height_map[heightMapIndex(x, z)] = value;
}

pub fn getSkyLight(self: *const Chunk, x: u32, y: u32, z: u32) u4 {
    return self.sky_light.get(x, y, z);
}

pub fn setSkyLight(self: *Chunk, x: u32, y: u32, z: u32, value: u4) void {
    self.sky_light.set(x, y, z, value);
}

pub fn getBlockLight(self: *const Chunk, x: u32, y: u32, z: u32) u4 {
    return self.block_light.get(x, y, z);
}

pub fn setBlockLight(self: *Chunk, x: u32, y: u32, z: u32, value: u4) void {
    self.block_light.set(x, y, z, value);
}

pub fn getTemperature(self: *const Chunk, x: u32, z: u32) f32 {
    return self.temperature[heightMapIndex(x, z)];
}

pub fn getHumidity(self: *const Chunk, x: u32, z: u32) f32 {
    return self.humidity[heightMapIndex(x, z)];
}

pub fn setClimate(self: *Chunk, x: u32, z: u32, temperature: f32, humidity: f32) void {
    self.temperature[heightMapIndex(x, z)] = temperature;
    self.humidity[heightMapIndex(x, z)] = humidity;
}

test "block id round-trips through the packed index" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlockId(1, 64, 15, 42);
    try std.testing.expectEqual(@as(u8, 42), chunk.getBlockId(1, 64, 15));
    try std.testing.expectEqual(@as(u8, 0), chunk.getBlockId(0, 0, 0));
}

test "metadata is independent of the block id" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlockId(2, 3, 4, 5);
    chunk.setBlockMetadata(2, 3, 4, 7);
    try std.testing.expectEqual(@as(u8, 5), chunk.getBlockId(2, 3, 4));
    try std.testing.expectEqual(@as(u4, 7), chunk.getBlockMetadata(2, 3, 4));
}

test "height map is indexed independently of block position" {
    var chunk = Chunk.init(0, 0);
    chunk.setHeightValue(5, 9, 64);
    try std.testing.expectEqual(@as(u8, 64), chunk.getHeightValue(5, 9));
    try std.testing.expectEqual(@as(u8, 0), chunk.getHeightValue(9, 5));
}
